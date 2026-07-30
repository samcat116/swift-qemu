import Foundation
import Logging

// `stop()` and `deinit` send SIGKILL through `kill(2)` — Foundation offers no
// forced-kill API — so the POSIX layer is imported explicitly rather than relying
// on Foundation to re-export it.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
/// objects handed to them. `deinit` is likewise outside the actor, and reaches
/// stored properties under the rule that a deinitializing actor has no other
/// references left to race against — which is also why the on-disk cleanup it
/// shares with `stop()` lives in `nonisolated static` helpers taking their paths
/// as arguments.
public actor QEMUProcess {
    private let logger: Logger
    private var process: Process?
    private let qmpSocketPath: String
    private var stderrPipe: Pipe?
    private var stderrCapture: StderrCapture?
    private var exitWaiter: ExitWaiter?

    /// Private per-instance directory, created with mode `0700`, that holds the QMP
    /// socket and the debug log. See `createInstanceDirectoryIfNeeded()`.
    private let instanceDirectory: String

    /// Whether the QMP socket lives inside `instanceDirectory`. `false` when the
    /// caller named a path of its own, which this type binds to but does not own.
    private let socketIsManaged: Bool

    /// Set once `instanceDirectory` has actually been created, which is what makes
    /// removing it on teardown safe: nothing else can be at that path.
    private var createdInstanceDirectory = false

    /// Path of the debug log for the current run, when log files are enabled.
    /// Its presence is what keeps `instanceDirectory` alive past teardown.
    private var logFilePath: String?

    /// QEMU binary path
    public let qemuPath: String

    /// How long `stop()` waits for the child to honour SIGTERM before escalating,
    /// and how long it then waits after SIGKILL.
    public static let defaultTerminationTimeout: TimeInterval = 5

    /// The kernel's limit on the length of a unix socket path, taken from
    /// `sockaddr_un.sun_path`: 104 bytes on Darwin, 108 on Linux, including the
    /// terminating NUL.
    ///
    /// Worth checking rather than discovering: an over-long path makes QEMU fail to
    /// bind, which reaches a caller as a socket that simply never appears — the
    /// least informative failure this type has.
    public static let maxSocketPathLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Is the QEMU process running
    public var isRunning: Bool {
        guard let process = process else { return false }
        return process.isRunning
    }

    /// PID of the current QEMU process, or `nil` once it has been reaped and
    /// released by `stop()`.
    ///
    /// Worth reporting when termination fails: it is what a caller needs to go
    /// deal with a survivor by hand.
    public var processIdentifier: Int32? {
        process?.processIdentifier
    }

    /// The tail of QEMU's stderr from the most recent run.
    ///
    /// Survives `stop()` so a failed start can still be diagnosed. Empty if QEMU
    /// wrote nothing or has not been started yet.
    public var capturedStderr: String {
        stderrCapture?.text ?? ""
    }

    /// - Parameters:
    ///   - qemuPath: The QEMU binary to run.
    ///   - qmpSocketPath: An explicit path for the QMP socket. Leave this `nil` —
    ///     the default puts the socket in a private per-instance directory, which
    ///     is the only thing that actually restricts access to it. A caller that
    ///     names a path owns whatever protects it, and takes on the same problem
    ///     this type used to have.
    ///   - runtimeDirectory: Base directory for the private per-instance
    ///     directory. Defaults to `NSTemporaryDirectory()`, which on macOS is
    ///     already per-user. Unix socket paths are limited to about 100 bytes in
    ///     total (`maxSocketPathLength`), so a deeply nested base will not fit.
    public init(
        qemuPath: String = "/usr/bin/qemu-system-x86_64",
        qmpSocketPath: String? = nil,
        runtimeDirectory: String? = nil,
        logger: Logger = Logger(label: "SwiftQEMU.QEMUProcess")
    ) {
        let directory = URL(fileURLWithPath: runtimeDirectory ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qemu-\(Self.pathToken())", isDirectory: true)
            .path

        self.qemuPath = qemuPath
        self.instanceDirectory = directory
        self.socketIsManaged = qmpSocketPath == nil
        // A fixed, short socket name inside a per-instance directory. The old
        // `/tmp/qemu-<uuid>.sock` spent 41 characters of a ~104-byte budget on the
        // name alone, and spent them in a directory shared with the whole host.
        self.qmpSocketPath = qmpSocketPath ?? directory + "/qmp.sock"
        self.logger = logger
    }

    /// An unguessable path component, short enough to leave room in `sun_path`.
    ///
    /// A UUID string is 36 characters and `NSTemporaryDirectory()` on macOS is
    /// around 50 more, which together crowd a limit that is only 104 bytes wide.
    /// This is 64 bits of entropy in at most 13.
    private static func pathToken() -> String {
        String(UInt64.random(in: UInt64.min ... UInt64.max), radix: 36)
    }

    /// Start QEMU process with given configuration
    public func start(with config: QEMUConfiguration) async throws {
        guard process == nil || !isRunning else {
            throw QMPError.processAlreadyRunning
        }

        guard qmpSocketPath.utf8.count < Self.maxSocketPathLength else {
            throw QMPError.socketPathTooLong(path: qmpSocketPath, limit: Self.maxSocketPathLength)
        }

        // ENABLE_QEMU_PROCESS_LOG_FILES controls whether stdout goes to a log file
        // or /dev/null. Read before the directory is prepared, because the log
        // lives in that directory too.
        let enableLogFiles = ProcessInfo.processInfo.environment["ENABLE_QEMU_PROCESS_LOG_FILES"]
        let shouldLogToFile = enableLogFiles?.lowercased() == "true" ||
                              enableLogFiles?.lowercased() == "yes" ||
                              enableLogFiles == "1"

        if socketIsManaged || shouldLogToFile {
            try createInstanceDirectoryIfNeeded()
        }

        // QEMU cannot bind over an existing entry, so a leftover socket has to go
        // first. Under the default layout there is nothing to remove — the
        // directory is ours and fresh.
        Self.removeSocketFile(at: qmpSocketPath, logger: logger)

        let arguments = buildArguments(from: config)

        logger.info("Starting QEMU process", metadata: [
            "path": .string(qemuPath),
            "arguments": .array(arguments.map { .string($0) })
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuPath)
        process.arguments = arguments

        var logHandle: FileHandle?
        if shouldLogToFile, let handle = makeLogFile() {
            // Redirect output to log file for debugging
            logHandle = handle
            process.standardOutput = handle
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

    /// Stop the QEMU process: SIGTERM, wait, then SIGKILL.
    ///
    /// The process reference and the QMP socket file are released only once the
    /// child has actually exited. Clearing them straight after `terminate()` — as
    /// this used to — was wrong in four separate ways at once: `isRunning` reported
    /// `false` while QEMU was still shutting down, the socket file was deleted from
    /// under a live process, the child was never waited on, and the
    /// `processAlreadyRunning` guard in `start()` waved through a restart that then
    /// reused the same socket path as the survivor.
    ///
    /// Safe to call on a process that has already exited, and on one that was never
    /// started: both are just the cleanup half of this method.
    ///
    /// After this returns, `isRunning` is `false` unless even SIGKILL failed to take
    /// the child down, in which case the process reference is deliberately kept so
    /// `isRunning` stays truthful and a restart is refused rather than colliding.
    ///
    /// - Parameter timeout: seconds to wait for the child to honour SIGTERM before
    ///   escalating to SIGKILL. The same budget applies to the wait after SIGKILL.
    public func stop(timeout: TimeInterval = QEMUProcess.defaultTerminationTimeout) async {
        guard let process = process else {
            logger.debug("QEMU process not running, nothing to stop")
            // A start that failed before `run()` still leaves the pipe behind.
            detachStderrReader()
            removeRuntimeFiles()
            return
        }

        if process.isRunning {
            logger.info("Stopping QEMU process", metadata: [
                "pid": .stringConvertible(process.processIdentifier)
            ])

            process.terminate()

            if await waitForExit(timeout: timeout) == false {
                logger.warning("QEMU ignored SIGTERM, escalating to SIGKILL", metadata: [
                    "pid": .stringConvertible(process.processIdentifier),
                    "timeout": .stringConvertible(timeout)
                ])

                // No Foundation API forces a kill, and `destroy()` is documented as
                // a force quit — a wedged or stopped QEMU has to actually die.
                kill(process.processIdentifier, SIGKILL)

                if await waitForExit(timeout: timeout) == false {
                    logger.error("QEMU process survived SIGKILL", metadata: [
                        "pid": .stringConvertible(process.processIdentifier)
                    ])
                    return
                }
            }
        } else {
            logger.debug("QEMU process already exited, cleaning up")
        }

        self.process = nil
        self.exitWaiter = nil

        detachStderrReader()
        removeRuntimeFiles()

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

        await exitWaiter.waitForExit()

        try Task.checkCancellation()
    }

    // MARK: - Deinitialization

    /// Last-ditch cleanup for a `QEMUProcess` that is dropped without `stop()`.
    ///
    /// Without this, releasing a `QEMUProcess` (or the `QEMUManager` holding one)
    /// left QEMU running for the lifetime of the host process — Foundation's
    /// `Process` does not take its child down when it goes away.
    ///
    /// `deinit` cannot await, so there is no graceful shutdown to be had here and
    /// no exit to confirm: SIGKILL is the only honest option. Callers that want the
    /// guest to power itself down must call `QEMUManager.shutdown()` — or `stop()` —
    /// before releasing this.
    ///
    /// An actor's `deinit` is not isolated, and reaches the stored properties below
    /// only under the language's exception for a deinitializing actor — by then no
    /// other reference exists to race against. Keep this to *stored* properties:
    /// `isRunning` or any other computed member or method would not compile here.
    deinit {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process = process, process.isRunning {
            logger.warning("QEMUProcess released while QEMU was still running; killing it", metadata: [
                "pid": .stringConvertible(process.processIdentifier)
            ])
            kill(process.processIdentifier, SIGKILL)
        }

        // Spelled out rather than folded into one `&&`: the short-circuit makes the
        // second operand an autoclosure, which is nonisolated and so cannot reach a
        // stored property here.
        var directoryToRemove: String?
        if createdInstanceDirectory {
            if logFilePath == nil {
                directoryToRemove = instanceDirectory
            }
        }

        Self.removeRuntimeFiles(
            socketPath: qmpSocketPath,
            directory: directoryToRemove,
            logger: logger
        )
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

    /// Wait up to `timeout` for the child to exit. Reports whether it did.
    ///
    /// Deliberately not cancellable, unlike `waitUntilExit()`. Teardown must not be
    /// abandonable half-done: a cancelled wait would hand `stop()` a `false` it had
    /// not earned, so it would escalate to SIGKILL — or give up and clear `process`
    /// and the socket file — without ever having confirmed anything. The wait
    /// therefore runs in a detached task, which the caller's cancellation cannot
    /// reach.
    private func waitForExit(timeout: TimeInterval) async -> Bool {
        guard let process = process else { return true }
        guard let exitWaiter = exitWaiter else { return !process.isRunning }
        guard process.isRunning else { return true }

        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        await Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(nanoseconds: nanoseconds) }
                group.addTask { await exitWaiter.waitForExit() }

                // Whichever lands first ends the wait; the other returns on
                // cancellation, so leaving this scope cannot block.
                await group.next()
                group.cancelAll()
            }
        }.value

        // `hasExited` is the authoritative answer — it is set by the termination
        // handler — and is checked first so a lagging `isRunning` cannot provoke a
        // pointless SIGKILL at a pid that has already been reaped.
        return exitWaiter.hasExited || !process.isRunning
    }

    /// Create the private directory that holds the QMP socket and the debug log.
    ///
    /// The directory's mode is what protects a unix socket: a socket file's own
    /// permission bits are not portably honoured, so `0700` here is the access
    /// control, not decoration. `/tmp` — where the socket used to live directly —
    /// is world-writable and shared with every user on the host, and a QMP socket
    /// is a full control channel for the VM: whoever reaches it can `quit` the
    /// guest, hot-plug devices, or read block device state.
    ///
    /// `withIntermediateDirectories: false` so that anything already sitting at
    /// this path is an error rather than something to be adopted. Nothing should
    /// be: the name carries 64 bits of randomness.
    private func createInstanceDirectoryIfNeeded() throws {
        // Already ours from an earlier `start()` on this instance — see
        // `removeRuntimeFiles()` for the one case that leaves it behind.
        guard !createdInstanceDirectory else { return }

        let fileManager = FileManager.default
        let parent = (instanceDirectory as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)

        try fileManager.createDirectory(
            atPath: instanceDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        // Foundation does not promise the attribute above reaches `mkdir(2)` rather
        // than being applied after the fact, and the mode is the whole point.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: instanceDirectory)

        createdInstanceDirectory = true
        logger.debug("Created private QEMU runtime directory", metadata: [
            "path": .string(instanceDirectory)
        ])
    }

    /// Open this run's debug log inside the private directory, or `nil` if it could
    /// not be created — in which case the caller falls back to `/dev/null` rather
    /// than handing QEMU a nil stdout.
    ///
    /// Named per run, not per instance, so restarting a `QEMUProcess` does not
    /// overwrite the log of the run being diagnosed.
    private func makeLogFile() -> FileHandle? {
        let path = instanceDirectory + "/qemu-\(Self.pathToken()).log"

        guard FileManager.default.createFile(
            atPath: path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let handle = FileHandle(forWritingAtPath: path) else {
            logger.warning("Could not create QEMU log file, falling back to /dev/null", metadata: [
                "path": .string(path)
            ])
            return nil
        }

        logFilePath = path
        logger.info("QEMU output redirected to: \(path)")
        return handle
    }

    /// Remove what this run left on disk: the socket, and the private directory
    /// around it.
    ///
    /// The directory goes only if this instance created it, which is what makes
    /// removing a whole directory tree safe — under the old scheme teardown deleted
    /// whatever happened to be at a caller-supplied path.
    ///
    /// One exception: a directory holding a debug log is left in place. Log files
    /// are opt-in via `ENABLE_QEMU_PROCESS_LOG_FILES`, and a caller who asks for
    /// one wants to read it after the VM is gone.
    private func removeRuntimeFiles() {
        Self.removeRuntimeFiles(
            socketPath: qmpSocketPath,
            directory: (createdInstanceDirectory && logFilePath == nil) ? instanceDirectory : nil,
            logger: logger
        )

        if let logFilePath = logFilePath {
            logger.debug("Keeping QEMU runtime directory for its log", metadata: [
                "log": .string(logFilePath)
            ])
        }
    }

    /// `nonisolated` so `deinit` — which is outside the actor by language rule —
    /// can run the same cleanup.
    private nonisolated static func removeRuntimeFiles(
        socketPath: String,
        directory: String?,
        logger: Logger
    ) {
        removeSocketFile(at: socketPath, logger: logger)
        if let directory = directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// Delete the socket file, and nothing else.
    ///
    /// Deliberately narrow. `qmpSocketPath` can come from a caller, and
    /// `removeItem` on a directory takes everything under it — so a mistyped path
    /// used to mean this type would quietly delete a directory tree it was never
    /// asked to touch.
    private nonisolated static func removeSocketFile(at path: String, logger: Logger) {
        let fileManager = FileManager.default
        // `attributesOfItem` does not follow symlinks, so a link is reported as a
        // link and removing it removes the link rather than its target.
        guard let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return
        }

        switch type {
        case .typeSocket, .typeRegular, .typeSymbolicLink:
            try? fileManager.removeItem(atPath: path)
        default:
            logger.warning("Refusing to remove QMP socket path: it is not a socket", metadata: [
                "path": .string(path),
                "type": .string(type.rawValue)
            ])
        }
    }

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

    /// Internal rather than private so the argument list can be asserted on
    /// directly; the accelerator and CPU model are exactly the kind of thing that
    /// only fails once a real QEMU rejects it.
    ///
    /// `nonisolated` because it derives everything from `config` and the immutable
    /// `qmpSocketPath`, touching none of the actor's mutable state — which keeps the
    /// argument-list assertions synchronous.
    nonisolated func buildArguments(from config: QEMUConfiguration) -> [String] {
        var args: [String] = []

        // Machine type
        args.append("-machine")
        args.append(config.machineType)

        // Accelerator. `-accel` rather than the legacy `-enable-kvm`, which can
        // only ever say "kvm" — and said it on macOS, where kvm does not exist.
        if let accelerator = config.accelerator.qemuName {
            args.append("-accel")
            args.append(accelerator)
        }

        // CPU configuration
        args.append("-cpu")
        args.append(config.resolvedCPUType)

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
        
        // PCIe root ports for hot-plug. Root ports cannot themselves be
        // hot-plugged, so if `attachDisk` is ever to work they have to be here, at
        // launch. `chassis` is mandatory and must be unique — two ports without it
        // take QEMU down at startup with `Can't add chassis slot, error -16` — and
        // no `bus=` is given because the machine's own default PCIe root complex is
        // the right parent on q35 and arm `virt` alike.
        for (index, portID) in config.hotplugPortIDs.enumerated() {
            args.append("-device")
            args.append("pcie-root-port,id=\(portID),chassis=\(index + 1)")
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
/// the exit landing before anyone waits (latched by `exited`), several
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
    private var exited = false

    /// Whether the termination handler has fired. Authoritative, and unlike
    /// `Process.isRunning` it cannot lag behind the exit it reports.
    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    /// Park until the process exits, returning early if the calling task is
    /// cancelled.
    func waitForExit() async {
        let token = nextToken()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(token: token, continuation: continuation)
            }
        } onCancel: {
            // Resumes only this waiter. Latching the whole waiter as finished
            // would make a later wait return immediately for a process that is
            // still very much alive.
            cancel(token: token)
        }
    }

    func nextToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastToken += 1
        return lastToken
    }

    func install(token: UInt64, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if exited || cancelledTokens.remove(token) != nil {
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
        exited = true
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

/// Which accelerator QEMU should use, passed as `-accel <name>`.
///
/// This is a choice, not a switch: the previous `enableKVM: Bool` could only
/// name one accelerator, and named it on a platform that has none — the default
/// configuration died with `invalid accelerator kvm` before QEMU got as far as
/// opening a disk.
///
/// An accelerator is only valid when QEMU was built with it *for the target
/// being emulated*. On an Apple Silicon host, `qemu-system-aarch64` accepts
/// `hvf` while `qemu-system-x86_64` does not — verified against QEMU 11.0.2 —
/// so matching the host OS is not by itself enough to pick one.
public enum QEMUAccelerator: String, Sendable, CaseIterable {
    /// Linux hardware acceleration. Requires a matching-architecture target.
    case kvm
    /// macOS Hypervisor.framework. Requires a matching-architecture target:
    /// available to `qemu-system-aarch64` on Apple Silicon and to
    /// `qemu-system-x86_64` on Intel, but never across the two.
    case hvf
    /// Portable software emulation. Works for any target on any host.
    case tcg
    /// Emit no `-accel` argument and let QEMU apply its own default. For
    /// callers that select the accelerator some other way, such as
    /// `-machine accel=...` through `additionalArgs`.
    ///
    /// Deliberately not spelled `none`: it means "unspecified", not "no
    /// acceleration" — that is `tcg` — and `.none` on a non-optional enum
    /// collides with `Optional.none` at the use site.
    case unspecified

    /// Host-native hardware acceleration, for callers whose QEMU target matches
    /// the host architecture. Not the default — see `QEMUConfiguration.accelerator`.
    public static var hostNative: QEMUAccelerator {
        #if os(macOS)
        return .hvf
        #else
        return .kvm
        #endif
    }

    /// Whether this accelerator is backed by hardware virtualization, which is
    /// what decides whether `-cpu host` means anything.
    public var isHardwareAccelerated: Bool {
        switch self {
        case .kvm, .hvf: return true
        case .tcg, .unspecified: return false
        }
    }

    /// The value for `-accel`, or `nil` when the argument should be omitted.
    var qemuName: String? {
        self == .unspecified ? nil : rawValue
    }

    /// A CPU model this accelerator can actually provide. `host` is only
    /// meaningful under hardware virtualization — under TCG, QEMU rejects it
    /// outright with `unable to find CPU model 'host'`.
    var defaultCPUType: String {
        isHardwareAccelerated ? "host" : "qemu64"
    }
}

/// How many `pcie-root-port` devices the launch arguments pre-create for disk
/// hot-plug.
///
/// This exists because a q35 machine cannot hot-plug anything onto its default
/// bus. `device_add` with no `bus` lands on `pcie.0`, which answers
/// `Bus 'pcie.0' does not support hotplugging` — so `attachDisk` failed outright
/// under the library's own default machine type. A PCIe root complex accepts
/// hot-plug only through a root port, and a root port cannot itself be
/// hot-plugged: it has to be on the command line before QEMU starts. The arm
/// `virt` machine behaves identically; the older `pc` machine's `pci.0` accepts
/// hot-plug directly and needs none of this. All three verified on QEMU 11.0.2.
public enum QEMUHotplugPorts: Sendable, Equatable {
    /// Pre-create `QEMUConfiguration.automaticHotplugPortCount` ports on machine
    /// types that need them, and none on machine types that do not. The default.
    ///
    /// The gate is deliberately an allowlist: a root port is only valid where
    /// there is a PCI bus to put it on, and on `microvm` — which has none — the
    /// argument stops QEMU from starting at all.
    case automatic
    /// Pre-create exactly this many, whatever the machine type. A root port holds
    /// exactly one device (a second `device_add` onto the same port is refused
    /// with `slot 0 function 0 already occupied`), so this is also the number of
    /// disks that can be hot-plugged at once.
    case count(Int)
    /// Pre-create none, leaving `device_add` to land on the machine's default bus.
    /// Right for `pc`, and for a caller building its own topology through
    /// `additionalArgs` — which is also the case that must not collide with the
    /// chassis numbers used here.
    ///
    /// Deliberately not spelled `none`, which collides with `Optional.none` at
    /// the use site.
    case disabled
}

/// QEMU VM configuration
public struct QEMUConfiguration: Sendable {
    public var machineType: String = "q35"

    /// CPU model for `-cpu`. `nil` (the default) picks one that suits the
    /// accelerator — see `resolvedCPUType`.
    public var cpuType: String?

    /// Accelerator for `-accel`.
    ///
    /// Defaults to `tcg` because it is the only value that starts on every
    /// supported host: `hostNative` is wrong whenever the QEMU target does not
    /// match the host architecture, which is the out-of-the-box case on Apple
    /// Silicon with the default `qemu-system-x86_64`. Set `.hostNative` (or
    /// `.hvf`/`.kvm` outright) once the target and host architectures agree.
    public var accelerator: QEMUAccelerator = .tcg

    public var cpuCount: Int = 1
    public var memoryMB: Int = 1024
    public var disks: [QEMUDisk] = []
    public var networks: [QEMUNetwork] = []
    public var kernel: String?
    public var initrd: String?
    public var kernelArgs: String?
    public var noGraphic: Bool = true
    public var startPaused: Bool = true
    public var additionalArgs: [String] = []

    /// PCIe root ports pre-created for `QEMUManager.attachDisk` to plug into.
    /// See `QEMUHotplugPorts` for why hot-plug on the default machine type needs
    /// them at all.
    public var hotplugPorts: QEMUHotplugPorts = .automatic

    /// How many root ports `.automatic` provides, and so how many disks can be
    /// hot-plugged at once without configuring anything.
    public static let automaticHotplugPortCount = 4

    /// Prefix for the generated port ids, namespaced so a caller's own devices in
    /// `additionalArgs` cannot collide with them.
    static let hotplugPortIDPrefix = "swiftqemu-hotplug"

    /// The CPU model actually passed to `-cpu`: `cpuType` when set, otherwise
    /// the accelerator's own default.
    public var resolvedCPUType: String {
        cpuType ?? accelerator.defaultCPUType
    }

    /// How many `pcie-root-port` devices this configuration actually emits.
    public var resolvedHotplugPortCount: Int {
        switch hotplugPorts {
        case .disabled:
            return 0
        case .count(let count):
            return max(0, count)
        case .automatic:
            return requiresHotplugPort ? QEMUConfiguration.automaticHotplugPortCount : 0
        }
    }

    /// The ids of the emitted root ports, in the order `QEMUManager` hands them
    /// out. Both the launch arguments and the manager's pool of free ports are
    /// derived from this one list, so they cannot drift apart.
    public var hotplugPortIDs: [String] {
        (0..<resolvedHotplugPortCount).map { "\(QEMUConfiguration.hotplugPortIDPrefix)\($0)" }
    }

    /// Whether this configuration's machine type refuses hot-plug on its default
    /// bus, and therefore needs a root port for `attachDisk` to target.
    public var requiresHotplugPort: Bool {
        QEMUConfiguration.machineRequiresHotplugPort(machineType)
    }

    /// Whether `machineType`'s default bus refuses hot-plug.
    ///
    /// True for the PCIe-root-complex machines — q35 (including its versioned
    /// `pc-q35-*` names) and arm/riscv `virt` — whose `pcie.0` answers
    /// `Bus 'pcie.0' does not support hotplugging`. False for everything else,
    /// which is the safe direction to be wrong in: a machine wrongly listed here
    /// gets a root port that may stop QEMU from starting, while one wrongly left
    /// out just fails the eventual `attachDisk` with a message naming the cause.
    public static func machineRequiresHotplugPort(_ machineType: String) -> Bool {
        // Machine names carry options after a comma (`q35,accel=tcg`), and
        // versions after a dash (`pc-q35-10.0`, `virt-9.2`).
        let name = machineType.split(separator: ",").first.map(String.init) ?? machineType

        return name == "q35" || name.hasPrefix("pc-q35")
            || name == "virt" || name.hasPrefix("virt-")
    }

    /// Compatibility shim for the previous `Bool`.
    ///
    /// `true` maps to `kvm` and `false` to `tcg`, which is what QEMU fell back
    /// to when `-enable-kvm` was absent. Reading it reports only whether the
    /// accelerator is kvm, so `hvf` reads as `false`.
    @available(*, deprecated, message: "Use `accelerator` instead: `.kvm` for true, `.tcg` for false. `enableKVM` cannot express `hvf`.")
    public var enableKVM: Bool {
        get { accelerator == .kvm }
        set { accelerator = newValue ? .kvm : .tcg }
    }

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