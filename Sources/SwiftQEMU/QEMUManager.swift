import Foundation
import Logging

/// High-level QEMU VM manager combining process and QMP management
public actor QEMUManager {
    private let logger: Logger
    private let process: QEMUProcess
    private let qmpClient: QMPClient
    private var isConnected = false

    /// The configuration the running VM was started with. Hot-plug needs it after
    /// the fact: which bus `device_add` may target is decided by the machine type
    /// and the root ports that were put on the command line at launch.
    private var configuration: QEMUConfiguration?

    /// The pre-created PCIe root ports, and which device holds each one.
    private var hotplugPorts = HotplugPortPool(portIDs: [])

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
        configuration = config
        hotplugPorts = HotplugPortPool(portIDs: config.hotplugPortIDs)

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
            forgetHotplugState()

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
            forgetHotplugState()
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
        forgetHotplugState()

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

    /// Attach a disk to a running VM.
    ///
    /// On a machine type whose default bus refuses hot-plug — q35, the library's
    /// own default, and arm `virt` — the disk is plugged into one of the
    /// `pcie-root-port` devices `QEMUConfiguration.hotplugPorts` put on the command
    /// line at launch, and each port holds one disk. On `pc`, whose `pci.0` accepts
    /// hot-plug directly, no bus is named and QEMU's default applies.
    ///
    /// - Parameters:
    ///   - path: Path to the qcow2 disk image
    ///   - deviceName: Name for the device (e.g., "vdb")
    ///   - readOnly: Whether the disk should be read-only
    ///   - bus: The bus to plug into, for a caller that built its own PCI topology
    ///     (through `additionalArgs`, say). Overrides the pre-created root ports
    ///     and is passed to `device_add` verbatim; when `nil`, a free root port is
    ///     used if there is one.
    /// - Throws: `QMPError.noHotplugPortAvailable` when the machine type needs a
    ///   root port and none is free — thrown before anything is sent to QEMU, so a
    ///   full pool costs nothing but the error.
    public func attachDisk(
        path: String,
        deviceName: String,
        readOnly: Bool = false,
        bus: String? = nil
    ) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        // Resolved before the backend is added: a rejected attach should not have to
        // be rolled back when the topology already said it could not work.
        let targetBus = try hotplugBus(explicit: bus)
        let nodeName = "drive-\(deviceName)"

        logger.info("Attaching disk", metadata: [
            "path": .string(path),
            "deviceName": .string(deviceName),
            "readOnly": .stringConvertible(readOnly),
            "bus": .string(targetBus ?? "<machine default>")
        ])

        // Step 1: Add block device backend
        try await qmpClient.blockdevAdd(nodeName: nodeName, filename: path, readOnly: readOnly)

        // Step 2: Add virtio-blk frontend
        do {
            try await qmpClient.deviceAdd(deviceId: deviceName, driveId: nodeName, bus: targetBus)
        } catch {
            // Rollback: remove the block device if frontend fails
            try? await qmpClient.blockdevDel(nodeName: nodeName)
            throw hotplugFailure(error, bus: targetBus)
        }

        // Claimed only now: a port burned by a failed attach would be unusable for
        // the life of the VM.
        if let targetBus = targetBus {
            hotplugPorts.claim(targetBus, for: deviceName)
        }

        logger.info("Disk attached successfully", metadata: ["deviceName": .string(deviceName)])
    }

    /// Detach a disk from a running VM.
    ///
    /// PCI hot-*unplug* needs the guest to cooperate: QEMU asks the guest to
    /// release the device and only emits `DEVICE_DELETED` once it has. A VM with no
    /// guest OS — or one whose guest ignores the request — never answers, and this
    /// call times out with no device removed. That is QEMU's behaviour, not a
    /// failure of this library: verified over a raw QMP socket that a guest-less VM
    /// produces no `DEVICE_DELETED` at all.
    ///
    /// - Parameters:
    ///   - deviceName: The device name to detach (e.g., "vdb")
    ///   - timeout: How long to wait for `DEVICE_DELETED` before giving up
    ///     (default: 5 seconds). A guest may take considerably longer than this to
    ///     quiesce a disk that is in use.
    public func detachDisk(deviceName: String, timeout: TimeInterval = 5) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let nodeName = "drive-\(deviceName)"

        logger.info("Detaching disk", metadata: ["deviceName": .string(deviceName)])

        // Step 1: Remove the device frontend (waits for DEVICE_DELETED event)
        try await qmpClient.deviceDel(deviceId: deviceName, timeout: timeout)

        // The root port is only free once the device is really gone, which is what
        // `deviceDel` returning means.
        hotplugPorts.release(deviceName)

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

    /// How many more disks can be hot-plugged before the root ports run out.
    /// `nil` on a machine type that hot-plugs onto its default bus, where there is
    /// no such limit to report.
    public var availableHotplugPorts: Int? {
        guard configuration?.requiresHotplugPort == true else { return nil }
        return hotplugPorts.freeCount
    }

    // MARK: - Hot-Plug Topology

    /// Which bus `device_add` should target, or `nil` for QEMU's default.
    ///
    /// The port is chosen but not claimed — see `attachDisk`.
    private func hotplugBus(explicit: String?) throws -> String? {
        // A caller who has built its own topology knows better than this does.
        if let explicit = explicit { return explicit }

        if let port = hotplugPorts.nextFreePort { return port }

        // No ports, either because none were asked for or because they are all
        // taken. That is only a problem where the default bus refuses hot-plug.
        guard let config = configuration, config.requiresHotplugPort else { return nil }

        throw QMPError.noHotplugPortAvailable(
            machineType: config.machineType,
            portCount: hotplugPorts.capacity,
            inUse: hotplugPorts.inUseCount
        )
    }

    /// Replace QEMU's own "does not support hotplugging" with an error that names
    /// the fix. Anything else passes through untouched.
    private func hotplugFailure(_ error: Error, bus: String?) -> Error {
        guard case QMPError.qmpError(_, let description) = error,
              description.lowercased().contains("does not support hotplug") else {
            return error
        }

        // QEMU names the bus it actually tried, which is the useful one when we
        // named none: `Bus 'pcie.0' does not support hotplugging`.
        let reported = bus ?? QEMUManager.quotedName(in: description) ?? "the default bus"

        return QMPError.hotplugNotSupported(
            bus: reported,
            machineType: configuration?.machineType ?? "unknown"
        )
    }

    private static func quotedName(in description: String) -> String? {
        let parts = description.split(separator: "'", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return String(parts[1])
    }

    /// Drop the topology of a VM that is no longer running, so a later `createVM`
    /// cannot inherit stale port assignments.
    private func forgetHotplugState() {
        configuration = nil
        hotplugPorts = HotplugPortPool(portIDs: [])
    }
}

// MARK: - Hot-Plug Port Pool

/// The pre-created `pcie-root-port` devices of a running VM, and which hot-plugged
/// disk occupies each one.
///
/// A root port takes exactly one device — QEMU refuses a second with
/// `slot 0 function 0 already occupied` — so ports have to be handed out one at a
/// time and handed back on detach. Claiming is deliberately separate from choosing,
/// so an attach that QEMU rejects does not consume a port for the life of the VM.
struct HotplugPortPool: Sendable {
    /// Every port the VM was launched with, in the order they are handed out.
    private let portIDs: [String]
    /// Device name to the port it occupies. The only mutable state, so a released
    /// port returns to its original place in the order rather than to the back of a
    /// queue.
    private var assignments: [String: String] = [:]

    init(portIDs: [String]) {
        self.portIDs = portIDs
    }

    var capacity: Int { portIDs.count }

    var inUseCount: Int { assignments.count }

    var freeCount: Int { capacity - inUseCount }

    /// The lowest-numbered unoccupied port, or `nil` when they are all taken.
    var nextFreePort: String? {
        let occupied = Set(assignments.values)
        return portIDs.first { !occupied.contains($0) }
    }

    /// Record that `device` now occupies `port`. A port this pool does not own —
    /// which is what a caller-supplied `bus` is — is not tracked.
    mutating func claim(_ port: String, for device: String) {
        guard portIDs.contains(port) else { return }
        assignments[device] = port
    }

    /// Give up whatever port `device` held. A device that never held one is a no-op.
    mutating func release(_ device: String) {
        assignments.removeValue(forKey: device)
    }

    /// Which port a device holds, if any. For tests and diagnostics.
    func port(for device: String) -> String? { assignments[device] }
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

