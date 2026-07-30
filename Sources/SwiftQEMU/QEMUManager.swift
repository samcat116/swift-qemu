import Foundation
import Logging

/// High-level QEMU VM manager combining process and QMP management
public actor QEMUManager {
    private let logger: Logger
    private let process: QEMUProcess
    private let qmpClient: QMPClient
    private var isConnected = false

    /// Consumes the QMP event stream for as long as a connection lasts, so
    /// `status` reflects what QEMU has already told us instead of going stale
    /// until someone calls `getStatus()`.
    private var eventMonitor: Task<Void, Never>?

    /// Current VM status
    ///
    /// Kept current from QMP events while connected — a guest that powers itself
    /// off, pauses or resumes is reflected here without polling — so reading this
    /// property is not the same as the stale snapshot it used to be. `getStatus()`
    /// still exists for a definitive round-trip to QEMU.
    public private(set) var status: QEMUVMStatus = .stopped

    /// The QMP capabilities negotiated on the current connection, empty when there
    /// is none. `.oob` here means out-of-band commands are available.
    public var negotiatedCapabilities: Set<QMPCapability> {
        qmpClient.negotiatedCapabilities
    }

    public init(
        qemuPath: String = "/usr/bin/qemu-system-x86_64",
        logger: Logger = Logger(label: "SwiftQEMU.QEMUManager")
    ) {
        self.logger = logger
        self.process = QEMUProcess(qemuPath: qemuPath, logger: logger)
        self.qmpClient = QMPClient(logger: logger)
    }
    
    // MARK: - VM Lifecycle
    
    /// Create a VM with the given configuration
    ///
    /// On return the VM exists and QMP is connected. With
    /// `QEMUConfiguration.startPaused` (the default) the guest is not executing
    /// yet, so `status` is `.paused` and `start()` is what runs it; otherwise it
    /// is `.running`. `.creating` only ever describes the window before this
    /// method returns.
    ///
    /// - Parameters:
    ///   - config: The QEMU VM configuration
    ///   - timeout: Timeout in seconds for the entire operation (default: 30)
    public func createVM(config: QEMUConfiguration, timeout: TimeInterval = 30) async throws {
        guard !(await process.isRunning) else {
            throw QMPError.processAlreadyRunning
        }

        logger.info("Creating QEMU VM")
        status = .creating

        do {
            // Wrap entire operation in a timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw QMPError.timeout
                }

                // Main creation task
                group.addTask {
                    // Start QEMU process
                    try await self.process.start(with: config)

                    // Connect to QMP
                    let socketPath = self.process.getQMPSocketPath()
                    try await self.qmpClient.connectUnix(path: socketPath)
                }

                // Wait for first task to complete (either timeout or creation)
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            // Success path
            isConnected = true
            // Subscribed before the first status query, so no transition can slip
            // through the gap between the two.
            startEventMonitor()
            await updateStatus()
            logger.info("QEMU VM created successfully")

        } catch {
            // Cleanup on any failure. Read stderr before stopping the process — on a
            // timeout QEMU is still alive, and its output is usually the only thing
            // that explains why the socket never showed up.
            //
            // These reads and the `start(with:)` above no longer touch the same
            // state from two concurrency domains: `QEMUProcess` is an actor, so the
            // group's cancelled child is serialized against this path rather than
            // relying on `@unchecked Sendable` to hide the overlap.
            let stderr = await process.capturedStderr
            logger.error("Failed to create QEMU VM: \(error)", metadata: [
                "qemuStderr": .string(stderr.isEmpty ? "<empty>" : stderr)
            ])

            // Reset state
            isConnected = false
            stopEventMonitor()
            status = .stopped

            // Clean up process if it was started. `stop()` waits for the child to
            // actually go, so what follows this cannot race a half-dead QEMU — and
            // if it fails to kill it, that is logged rather than thrown, so the
            // original failure is still what the caller sees.
            await process.stop()
            if await process.isRunning {
                let pid = await process.processIdentifier
                logger.error("QEMU process could not be terminated during cleanup", metadata: [
                    "pid": .string(pid.map(String.init) ?? "unknown")
                ])
            }

            throw error
        }
    }
    
    /// Start/resume VM execution
    public func start() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Starting VM")
        
        try await qmpClient.cont()
        status = .running
        
        logger.info("VM started")
    }
    
    /// Pause VM execution
    public func pause() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Pausing VM")
        
        try await qmpClient.stop()
        status = .paused
        
        logger.info("VM paused")
    }
    
    /// Reset the VM
    public func reset() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Resetting VM")
        
        try await qmpClient.systemReset()
        await updateStatus()
        
        logger.info("VM reset")
    }
    
    /// Shutdown the VM gracefully
    /// - Parameter timeout: How long to wait for the guest to power itself off
    ///   before termination is forced (default: 30 seconds)
    public func shutdown(timeout: TimeInterval = 30) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        logger.info("Shutting down VM")

        try await qmpClient.systemPowerdown()
        status = .shuttingDown

        // Wait for shutdown with timeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }

            group.addTask {
                // A process that has already gone is a completed shutdown, not
                // an error worth failing the whole call over.
                try? await self.process.waitUntilExit()
            }

            // Whichever finishes first ends the wait; cancelling the other is
            // now enough to make it return, so leaving this scope cannot block.
            await group.next()
            group.cancelAll()
        }

        if await process.isRunning {
            logger.warning("VM did not shut down gracefully, forcing termination")
            try await destroy()
        } else {
            // The socket is dead either way; drop the connection so the client
            // is not left believing it has one.
            try? await qmpClient.disconnect()
            // The child has gone, but its process record and socket file have not.
            // On an exited process that is all `stop()` does.
            await process.stop()
            status = .stopped
            isConnected = false
            stopEventMonitor()
        }

        logger.info("VM shutdown complete")
    }

    /// Force quit the VM
    /// - Parameter terminationTimeout: How long to wait for the QEMU process to
    ///   honour SIGTERM before it is killed outright (default: 5 seconds). The same
    ///   budget applies to the wait after SIGKILL.
    /// - Throws: `QMPError.processTerminationFailed` if QEMU outlived both signals.
    ///   A force quit that could not force anything must not report success.
    public func destroy(
        terminationTimeout: TimeInterval = QEMUProcess.defaultTerminationTimeout
    ) async throws {
        logger.info("Destroying VM")

        if isConnected {
            do {
                try await qmpClient.quit()
            } catch {
                logger.debug("QMP quit failed, process may already be terminating")
            }

            // Teardown must not be able to skip process termination. QEMU exits
            // in response to `quit`, which closes the channel from its end, and
            // letting that surface as a thrown error meant `process.stop()` below
            // never ran — leaving exactly the orphaned QEMU this method exists to
            // clean up.
            do {
                try await qmpClient.disconnect()
            } catch {
                logger.debug("QMP disconnect reported \(error) while tearing down")
            }
            isConnected = false
            // From here the outcome below is authoritative, so nothing still in the
            // event buffer gets to rewrite it.
            stopEventMonitor()
        }

        // Waits for the child and escalates to SIGKILL, so by the time this returns
        // the VM is either gone or unkillable — never "terminate() has been called
        // and we hope for the best".
        await process.stop(timeout: terminationTimeout)

        if await process.isRunning {
            // Status stays away from `.stopped`: something is still holding the
            // socket path and the VM's resources.
            status = .unknown
            throw QMPError.processTerminationFailed(pid: await process.processIdentifier)
        }

        status = .stopped

        logger.info("VM destroyed")
    }
    
    /// Get current VM status
    public func getStatus() async throws -> QEMUVMStatus {
        guard isConnected else {
            return .stopped
        }
        
        await updateStatus()
        return status
    }
    
    /// Update status from QMP
    private func updateStatus() async {
        do {
            let qmpStatus = try await qmpClient.queryStatus()

            if let mapped = QEMUVMStatus(qmpStatus) {
                status = mapped
            } else {
                logger.warning("Unknown QMP status: \(qmpStatus.status)")
                status = .unknown
            }
        } catch {
            // A VM whose QEMU has exited is stopped, not indeterminate. Without
            // this, a guest that powered itself off — which the SHUTDOWN event
            // reports accurately — was overwritten with `.unknown` by the next
            // query, since the query fails against a socket that has gone.
            if await process.isRunning == false {
                logger.debug("Status query failed and QEMU has exited; reporting stopped")
                status = .stopped
                return
            }
            logger.error("Failed to query VM status: \(error)")
            status = .unknown
        }
    }

    // MARK: - Events

    /// Subscribe to the QMP events QEMU emits on the current connection.
    ///
    /// The manager consumes the same events for its own `status` bookkeeping;
    /// subscribers are independent, so watching them here displaces nothing. See
    /// `QMPClient.events(bufferSize:)` for the buffering and lifetime rules — in
    /// short: bounded, oldest-dropped, and finished when the connection ends.
    ///
    /// - Throws: `QMPError.notConnected` if no VM is connected.
    public func events(
        bufferSize: Int = QMPClient.defaultEventBufferSize
    ) throws -> AsyncStream<QMPEvent> {
        guard isConnected else {
            throw QMPError.notConnected
        }
        return try qmpClient.events(bufferSize: bufferSize)
    }

    /// Start following the event stream for the connection just established.
    ///
    /// The stream finishes when the connection ends, so this task retires on its
    /// own; `stopEventMonitor()` exists for the teardown paths that want it gone
    /// before then.
    private func startEventMonitor() {
        stopEventMonitor()

        guard let events = try? qmpClient.events() else {
            logger.warning("Could not subscribe to QMP events; status will only update on demand")
            return
        }

        eventMonitor = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
    }

    private func stopEventMonitor() {
        eventMonitor?.cancel()
        eventMonitor = nil
    }

    /// Fold one event into `status`.
    private func apply(_ event: QMPEvent) {
        // Teardown has the last word on the status. A `quit` produces SHUTDOWN, and
        // that event landing after `destroy()` has decided the outcome must not
        // relabel a VM it failed to kill as stopped.
        guard isConnected else { return }

        guard let implied = QEMUVMStatus(event: event) else {
            // Trace, not debug: the client already logs every event once, and some
            // guests emit these several times a second.
            logger.trace("QMP event with no bearing on the run state", metadata: [
                "event": .string(event.event)
            ])
            return
        }

        guard implied != status else { return }

        logger.info("VM status changed by QMP event", metadata: [
            "event": .string(event.event),
            "from": .string(status.rawValue),
            "to": .string(implied.rawValue)
        ])
        status = implied
    }

    // MARK: - Disk Hot-Plug Operations

    /// Attach a disk to a running VM
    /// - Parameters:
    ///   - path: Path to the qcow2 disk image
    ///   - deviceName: Name for the device (e.g., "vdb")
    ///   - readOnly: Whether the disk should be read-only
    public func attachDisk(path: String, deviceName: String, readOnly: Bool = false) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let nodeName = "drive-\(deviceName)"

        logger.info("Attaching disk", metadata: [
            "path": .string(path),
            "deviceName": .string(deviceName),
            "readOnly": .stringConvertible(readOnly)
        ])

        // Step 1: Add block device backend
        try await qmpClient.blockdevAdd(nodeName: nodeName, filename: path, readOnly: readOnly)

        // Step 2: Add virtio-blk frontend
        do {
            try await qmpClient.deviceAdd(deviceId: deviceName, driveId: nodeName)
        } catch {
            // Rollback: remove the block device if frontend fails
            try? await qmpClient.blockdevDel(nodeName: nodeName)
            throw error
        }

        logger.info("Disk attached successfully", metadata: ["deviceName": .string(deviceName)])
    }

    /// Detach a disk from a running VM
    /// - Parameter deviceName: The device name to detach (e.g., "vdb")
    public func detachDisk(deviceName: String) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let nodeName = "drive-\(deviceName)"

        logger.info("Detaching disk", metadata: ["deviceName": .string(deviceName)])

        // Step 1: Remove the device frontend (waits for DEVICE_DELETED event)
        try await qmpClient.deviceDel(deviceId: deviceName)

        // Step 2: Remove the block device backend
        try await qmpClient.blockdevDel(nodeName: nodeName)

        logger.info("Disk detached successfully", metadata: ["deviceName": .string(deviceName)])
    }

    /// List attached block devices
    public func listDisks() async throws -> [JSONValue] {
        guard isConnected else {
            throw QMPError.notConnected
        }
        return try await qmpClient.queryBlock()
    }
}

// MARK: - VM Status

public enum QEMUVMStatus: String, Codable, Sendable {
    /// No QEMU process — never started, or gone.
    case stopped

    /// The VM is still being brought into existence: `createVM` has not returned
    /// yet, or QEMU is receiving an incoming migration.
    ///
    /// Deliberately *not* the state of a VM started with
    /// `QEMUConfiguration.startPaused`. Once `createVM` returns, such a VM is
    /// created and waiting for `start()`, which is `.paused`.
    case creating

    /// The guest is executing.
    case running

    /// The VM is live but not executing, and `start()` will resume it. Covers
    /// both a VM stopped after it was running and one launched with `-S` that
    /// has never run.
    case paused

    /// `shutdown()` has asked the guest to power itself off.
    case shuttingDown

    /// The status could not be determined: `query-status` failed, or QEMU
    /// reported a run state this library does not recognise.
    case unknown
}

extension QEMUVMStatus {
    /// The status corresponding to a QEMU run state, or `nil` if the run state is
    /// not one this library recognises.
    ///
    /// A pure mapping rather than a `switch` buried in `QEMUManager`: it is the
    /// part with the interesting decisions in it, and this way it can be tested
    /// without a QEMU process or a QMP socket.
    public init?(_ response: QMPStatusResponse) {
        switch response.status.lowercased() {
        case "running":
            // The `running` flag is the tiebreak: QEMU can report the state as
            // `running` while execution is actually stopped.
            self = response.running ? .running : .paused

        case "paused", "suspended":
            self = .paused

        case "prelaunch":
            // A VM launched with `-S`: created, live, and waiting for `cont`.
            // Every behaviour a caller can observe matches `.paused` — the same
            // `start()` resumes it — and since `startPaused` defaults to `true`,
            // calling it `.creating` made the out-of-the-box "created, ready to
            // start" VM indistinguishable from one still starting up.
            self = .paused

        case "shutdown", "poweroff":
            self = .stopped

        case "inmigrate":
            // An incoming migration genuinely is a VM still being constructed,
            // so this keeps `.creating`. Nothing here initiates one, so it is
            // reachable only for a VM handed over mid-migration.
            self = .creating

        default:
            return nil
        }
    }

    /// The status implied by a QMP event, or `nil` if the event says nothing about
    /// the run state.
    ///
    /// The point of the event stream: QEMU announces these transitions, including
    /// the ones initiated from inside the guest, so `status` no longer has to go
    /// stale until something polls `query-status`.
    ///
    /// `nil` is the right answer more often than it looks. `RESET` leaves the run
    /// state exactly as it was (and QEMU emits it twice per `system_reset`, verified
    /// on 11.0.2), and `GUEST_PANICKED` means whatever `-action panic` says it
    /// means. Guessing a status for either would be worse than leaving the last
    /// known one in place.
    public init?(event: QMPEvent) {
        switch event.event {
        case QMPEventName.stop, QMPEventName.suspend:
            self = .paused

        case QMPEventName.resume, QMPEventName.wakeup:
            self = .running

        case QMPEventName.powerdown:
            // The guest has been asked to power off and has not done it yet — QEMU
            // still reports the run state as `running`, and a guest with no OS never
            // moves off it. `.shuttingDown` is the only place that request is
            // visible, and it is what `shutdown()` sets for the same reason.
            self = .shuttingDown

        case QMPEventName.shutdown:
            // The machine is going away: emitted before the reply to `quit`, and on
            // a guest-initiated poweroff just before QEMU exits.
            self = .stopped

        default:
            return nil
        }
    }
}

