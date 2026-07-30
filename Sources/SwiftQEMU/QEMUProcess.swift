import Foundation
import Logging

/// Manages QEMU process lifecycle.
///
/// An `actor` rather than a `@unchecked Sendable` class, because every field here
/// is mutable and shared across concurrency domains: `start(with:)` writes
/// `process`, `stderrPipe`, `stderrCapture` and `exitWaiter` from whatever task
/// launched the VM, while a caller racing that start against a timeout — which is
/// exactly what `QEMUManager.createVM` does — reads `isRunning` and
/// `capturedStderr` from another. `StderrCapture` and `ExitWaiter` lock their own
/// contents, but the fields *referencing* them were unprotected, and the
/// `@unchecked` annotation was the only reason Swift 6 did not say so.
///
/// The two callbacks Foundation invokes on its own queues (the stderr readability
/// handler and `terminationHandler`) are installed by `nonisolated` helpers, so
/// they are honestly outside the actor and touch nothing but the locked helper
/// objects handed to them.
public actor QEMUProcess {
    private let logger: Logger
    private var process: Process?
    private let qmpSocketPath: String
    private var stderrPipe: Pipe?
    private var stderrCapture: StderrCapture?
    private var exitWaiter: ExitWaiter?

    /// QEMU binary path
    public let qemuPath: String

    /// Is the QEMU process running
    public var isRunning: Bool {
        guard let process = process else { return false }
        return process.isRunning
    }

    /// The tail of QEMU's stderr from the most recent run.
    ///
    /// Survives `stop()` so a failed start can still be diagnosed. Empty if QEMU
    /// wrote nothing or has not been started yet.
    public var capturedStderr: String {
        stderrCapture?.text ?? ""
    }

    public init(
        qemuPath: String = "/usr/bin/qemu-system-x86_64",
        qmpSocketPath: String? = nil,
        logger: Logger = Logger(label: "SwiftQEMU.QEMUProcess")
    ) {
        self.qemuPath = qemuPath
        self.qmpSocketPath = qmpSocketPath ?? "/tmp/qemu-\(UUID().uuidString).sock"
        self.logger = logger
    }
    
    /// Start QEMU process with given configuration
    public func start(with config: QEMUConfiguration) async throws {
        guard process == nil || !isRunning else {
            throw QMPError.processAlreadyRunning
        }
        
        // Clean up any existing socket
        try? FileManager.default.removeItem(atPath: qmpSocketPath)
        
        let arguments = buildArguments(from: config)
        
        logger.info("Starting QEMU process", metadata: [
            "path": .string(qemuPath),
            "arguments": .array(arguments.map { .string($0) })
        ])
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuPath)
        process.arguments = arguments

        // Redirect output based on environment variable
        // ENABLE_QEMU_PROCESS_LOG_FILES controls whether output goes to log files or /dev/null
        let enableLogFiles = ProcessInfo.processInfo.environment["ENABLE_QEMU_PROCESS_LOG_FILES"]
        let shouldLogToFile = enableLogFiles?.lowercased() == "true" ||
                              enableLogFiles?.lowercased() == "yes" ||
                              enableLogFiles == "1"

        var logHandle: FileHandle?
        if shouldLogToFile {
            // Redirect output to log file for debugging
            let logPath = "/tmp/qemu-\(UUID().uuidString).log"
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
            logHandle = FileHandle(forWritingAtPath: logPath)
            process.standardOutput = logHandle
            logger.info("QEMU output redirected to: \(logPath)")
        } else {
            // Redirect to /dev/null to prevent pipe buffer overflow
            // Note: We cannot use Pipe() without actively reading it, as QEMU's output
            // will fill the buffer and cause the process to crash
            let devNull = FileHandle(forWritingAtPath: "/dev/null")
            process.standardOutput = devNull
            logger.debug("QEMU output redirected to /dev/null")
        }

        // stderr goes through a pipe that is drained continuously so a fatal argument
        // error is reportable instead of being lost to /dev/null. See
        // `installStderrDrain` for why the drain is not optional.
        let capture = StderrCapture()
        let pipe = Pipe()
        process.standardError = pipe
        self.stderrPipe = pipe
        self.stderrCapture = capture

        Self.installStderrDrain(on: pipe, capture: capture, tee: logHandle)

        // Redirect stdin to /dev/null to prevent job control issues
        // When running from a terminal, not setting standardInput causes QEMU to
        // inherit the TTY stdin, triggering SIGSTOP/SIGTTOU and T (stopped) state.
        let devNullInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardInput = devNullInput

        // Installed before `run()`, which closes the window where a process that
        // exits immediately terminates before anyone is listening for it.
        let exitWaiter = ExitWaiter()
        self.exitWaiter = exitWaiter
        Self.installExitHandler(on: process, waiter: exitWaiter)

        // Start process
        do {
            try process.run()
        } catch {
            // Nothing will ever write to the pipe, so it would never reach EOF and
            // never release its reader on its own.
            detachStderrReader()
            throw error
        }
        self.process = process

        logger.info("QEMU process started", metadata: ["pid": .stringConvertible(process.processIdentifier)])

        // Wait for QMP socket to be ready with retry
        var retries = 0
        let maxRetries = 20 // 10 seconds total (20 * 0.5s)
        while retries < maxRetries {
            // Check if socket file exists
            if FileManager.default.fileExists(atPath: qmpSocketPath) {
                // Socket exists, wait a bit more for it to be ready to accept connections
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                logger.info("QMP socket ready", metadata: ["path": .string(qmpSocketPath)])
                break
            }

            // QEMU rejects a bad argument by exiting immediately. Without this check the
            // real reason sits in stderr while the caller waits out the full socket
            // timeout and sees only a connection failure.
            if !process.isRunning {
                throw await processExitedError(process)
            }

            // Wait and retry
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            retries += 1
        }

        // After all retries, check if socket was created
        if !FileManager.default.fileExists(atPath: qmpSocketPath) {
            if !process.isRunning {
                throw await processExitedError(process)
            }
            logger.error("QMP socket not created after \(maxRetries) retries", metadata: [
                "path": .string(qmpSocketPath),
                "stderr": .string(capture.text.isEmpty ? "<empty>" : capture.text)
            ])
            throw QMPError.socketCreationFailed
        }
    }

    /// Stop QEMU process
    public func stop() {
        guard let process = process, process.isRunning else {
            logger.debug("QEMU process not running, nothing to stop")
            // A process that already exited still leaves the pipe behind.
            detachStderrReader()
            return
        }

        logger.info("Stopping QEMU process", metadata: ["pid": .stringConvertible(process.processIdentifier)])

        process.terminate()
        self.process = nil

        detachStderrReader()

        // Clean up socket
        try? FileManager.default.removeItem(atPath: qmpSocketPath)

        logger.info("QEMU process stopped")
    }

    /// Get the QMP socket path for this process.
    ///
    /// `nonisolated`: the path is fixed at init, so reading it needs neither the
    /// actor nor an `await` at the call site.
    public nonisolated func getQMPSocketPath() -> String {
        return qmpSocketPath
    }
    
    /// Wait for the process to exit.
    ///
    /// Cancellable, and that matters: this used to park on a bare
    /// `withCheckedContinuation` around `terminationHandler`, which ignores
    /// cancellation. When a caller raced this against a timeout — as
    /// `QEMUManager.shutdown()` does — the timeout leg winning left this task
    /// parked forever, and the task group's implicit drain waited on it. The
    /// result was a shutdown that hung *past its own timeout*, with the forced
    /// termination that should have followed never reached.
    ///
    /// Returns immediately if the process has already exited, and throws
    /// `CancellationError` if the waiting task is cancelled.
    public func waitUntilExit() async throws {
        guard let process = process, let exitWaiter = exitWaiter else {
            throw QMPError.processNotRunning
        }

        guard process.isRunning else { return }

        let token = exitWaiter.nextToken()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exitWaiter.install(token: token, continuation: continuation)
            }
        } onCancel: {
            // Resumes only this waiter. Latching the whole waiter as finished
            // would make a later `waitUntilExit()` return immediately for a
            // process that is still very much alive.
            exitWaiter.cancel(token: token)
        }

        try Task.checkCancellation()
    }


    // MARK: - Off-actor callbacks

    /// Install the pipe drain. Foundation invokes the handler on its own queue, so
    /// it is deliberately formed outside the actor and closes over nothing but the
    /// internally-locked `StderrCapture` and the tee handle.
    ///
    /// The drain is what makes the pipe safe: an unread pipe fills its 64KB buffer
    /// and takes QEMU down with it, and `StderrCapture` retains only the tail.
    private nonisolated static func installStderrDrain(
        on pipe: Pipe,
        capture: StderrCapture,
        tee teeHandle: FileHandle?
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                capture.markEOF()
                return
            }
            capture.append(data)
            if let teeHandle = teeHandle {
                try? teeHandle.write(contentsOf: data)
            }
        }
    }

    /// Install the termination handler. Also called on a Foundation queue, and also
    /// closing over only a self-locking helper.
    private nonisolated static func installExitHandler(on process: Process, waiter: ExitWaiter) {
        process.terminationHandler = { _ in waiter.processDidExit() }
    }

    // MARK: - Private Methods

    /// Release the pipe and its reader. The `StderrCapture` is deliberately kept so
    /// callers can still read stderr after a failed start.
    private func detachStderrReader() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrCapture?.markEOF()
        stderrPipe = nil
    }

    /// Build the error for a QEMU process that died before the QMP socket appeared,
    /// logging the exit status alongside whatever it wrote to stderr.
    private func processExitedError(_ process: Process) async -> QMPError {
        let stderr = await drainedStderr()
        let status = process.terminationStatus
        let killedBySignal = process.terminationReason == .uncaughtSignal

        logger.error("QEMU process exited before the QMP socket was ready", metadata: [
            "exitCode": .stringConvertible(status),
            "terminationReason": .string(killedBySignal ? "uncaughtSignal" : "exit"),
            "stderr": .string(stderr.isEmpty ? "<empty>" : stderr)
        ])

        return .processExited(exitCode: status, killedBySignal: killedBySignal, stderr: stderr)
    }

    /// Wait briefly for the reader to pick up whatever QEMU wrote on its way out —
    /// the process can be reaped before the last chunk reaches the readability handler.
    private func drainedStderr(timeout: TimeInterval = 0.5) async -> String {
        guard let capture = stderrCapture else { return "" }

        let deadline = Date().addingTimeInterval(timeout)
        while !capture.isAtEOF && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000) // 0.025 seconds
        }

        return capture.text
    }

    private func buildArguments(from config: QEMUConfiguration) -> [String] {
        var args: [String] = []
        
        // Machine type
        args.append("-machine")
        args.append(config.machineType)
        
        // Enable KVM if available and requested
        if config.enableKVM {
            args.append("-enable-kvm")
        }
        
        // CPU configuration
        args.append("-cpu")
        args.append(config.cpuType)
        
        args.append("-smp")
        args.append("\(config.cpuCount)")
        
        // Memory
        args.append("-m")
        args.append("\(config.memoryMB)")
        
        // Disks
        for (index, disk) in config.disks.enumerated() {
            args.append("-drive")
            var driveOptions = "file=\(disk.path),format=\(disk.format),if=\(disk.interface)"
            if let id = disk.id {
                driveOptions += ",id=\(id)"
            } else {
                driveOptions += ",id=drive\(index)"
            }
            if disk.readonly {
                driveOptions += ",readonly=on"
            }
            args.append(driveOptions)
        }
        
        // Network devices
        for (index, network) in config.networks.enumerated() {
            // Network device
            args.append("-netdev")
            var netdevOptions = network.backend
            if let id = network.id {
                netdevOptions += ",id=\(id)"
            } else {
                netdevOptions += ",id=net\(index)"
            }
            if let options = network.options {
                netdevOptions += ",\(options)"
            }
            args.append(netdevOptions)
            
            // Device
            args.append("-device")
            var deviceOptions = network.model
            if let id = network.id {
                deviceOptions += ",netdev=\(id)"
            } else {
                deviceOptions += ",netdev=net\(index)"
            }
            if let mac = network.macAddress {
                deviceOptions += ",mac=\(mac)"
            }
            args.append(deviceOptions)
        }
        
        // Kernel and initrd if provided
        if let kernel = config.kernel {
            args.append("-kernel")
            args.append(kernel)
        }
        
        if let initrd = config.initrd {
            args.append("-initrd")
            args.append(initrd)
        }
        
        if let append = config.kernelArgs {
            args.append("-append")
            args.append(append)
        }
        
        // Display
        if config.noGraphic {
            args.append("-nographic")
        }
        
        // QMP socket
        args.append("-qmp")
        args.append("unix:\(qmpSocketPath),server,wait=off")
        
        // Start in paused state if requested
        if config.startPaused {
            args.append("-S")
        }
        
        // Additional raw arguments
        args.append(contentsOf: config.additionalArgs)
        
        return args
    }
}

// MARK: - Exit Waiter

/// Parking spot for the child process's exit, shared by every caller of
/// `waitUntilExit()`.
///
/// Three orderings have to work, and each one used to be a hang:
/// the exit landing before anyone waits (latched by `hasExited`), several
/// callers waiting at once (a list, not a single slot, so nobody's continuation
/// is overwritten and abandoned), and a waiter being cancelled before it has
/// parked (`cancelledTokens`, since `onCancel` can run before the operation
/// body). Continuations are removed under the lock and resumed after unlocking,
/// which is what guarantees exactly one resume each.
final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(token: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelledTokens: Set<UInt64> = []
    private var lastToken: UInt64 = 0
    private var hasExited = false

    func nextToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastToken += 1
        return lastToken
    }

    func install(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasExited || cancelledTokens.remove(token) != nil {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append((token: token, continuation: continuation))
        lock.unlock()
    }

    func cancel(token: UInt64) {
        lock.lock()
        if let waiter = removeLocked(token) {
            lock.unlock()
            waiter.resume()
            return
        }
        // Cancelled before it parked; `install` will resume it on arrival.
        cancelledTokens.insert(token)
        lock.unlock()
    }

    func processDidExit() {
        lock.lock()
        hasExited = true
        let resumed = waiters
        waiters.removeAll()
        cancelledTokens.removeAll()
        lock.unlock()

        for waiter in resumed {
            waiter.continuation.resume()
        }
    }

    /// Caller must hold `lock`.
    private func removeLocked(_ token: UInt64) -> CheckedContinuation<Void, Never>? {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return nil }
        return waiters.remove(at: index).continuation
    }
}

// MARK: - Stderr Capture

/// Bounded, thread-safe tail buffer for a child process's stderr.
///
/// Written from the pipe's readability handler and read from the caller, so all
/// access is under a lock. Only the most recent `maxBytes` are retained — QEMU's
/// fatal errors are the last thing it prints, and an unbounded buffer would just
/// move the memory problem instead of solving it.
final class StderrCapture: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var reachedEOF = false

    init(maxBytes: Int = 16 * 1024) {
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        if buffer.count > maxBytes {
            buffer.removeFirst(buffer.count - maxBytes)
        }
    }

    func markEOF() {
        lock.lock()
        defer { lock.unlock() }
        reachedEOF = true
    }

    var isAtEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEOF
    }

    /// Captured stderr as text, trimmed of surrounding whitespace.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Configuration Types

/// QEMU VM configuration
public struct QEMUConfiguration: Sendable {
    public var machineType: String = "q35"
    public var cpuType: String = "host"
    public var cpuCount: Int = 1
    public var memoryMB: Int = 1024
    public var enableKVM: Bool = true
    public var disks: [QEMUDisk] = []
    public var networks: [QEMUNetwork] = []
    public var kernel: String?
    public var initrd: String?
    public var kernelArgs: String?
    public var noGraphic: Bool = true
    public var startPaused: Bool = true
    public var additionalArgs: [String] = []
    
    public init() {}
}

/// QEMU disk configuration
public struct QEMUDisk: Sendable {
    public var path: String
    public var format: String = "qcow2"
    public var interface: String = "virtio"
    public var readonly: Bool = false
    public var id: String?
    
    public init(path: String, format: String = "qcow2", interface: String = "virtio", readonly: Bool = false, id: String? = nil) {
        self.path = path
        self.format = format
        self.interface = interface
        self.readonly = readonly
        self.id = id
    }
}

/// QEMU network configuration
public struct QEMUNetwork: Sendable {
    public var backend: String = "user"  // user, tap, bridge, etc.
    public var model: String = "virtio-net-pci"
    public var macAddress: String?
    public var id: String?
    public var options: String?  // Additional backend-specific options
    
    public init(backend: String = "user", model: String = "virtio-net-pci", macAddress: String? = nil, id: String? = nil, options: String? = nil) {
        self.backend = backend
        self.model = model
        self.macAddress = macAddress
        self.id = id
        self.options = options
    }
}