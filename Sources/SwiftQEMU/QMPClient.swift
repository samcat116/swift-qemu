import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Logging

/// QMP Client for communicating with QEMU Monitor Protocol
public final class QMPClient: Sendable {
    /// Default time budget for a single QMP round-trip. A live QEMU answers in
    /// milliseconds; the bound exists so a wedged or silent peer surfaces as an
    /// error instead of parking the caller forever.
    public static let defaultRequestTimeout: TimeInterval = 10

    /// Default time budget for the greeting + capability negotiation that
    /// follows a successful connect. A socket that accepts but never speaks
    /// (e.g. a stale socket file outliving its QEMU process) is the case this
    /// bounds.
    public static let defaultConnectTimeout: TimeInterval = 10

    /// Default cap on a single inbound QMP frame, terminating newline included.
    ///
    /// 512 KB is far above any real QMP message — `query-block` on a VM with a
    /// long device list is the largest realistic payload and runs to tens of KB
    /// — while still bounding what an unterminated frame can cost.
    public static let defaultMaximumFrameSize = 512 * 1024
    /// Default depth of a subscriber's event buffer. See ``events(bufferSize:)``
    /// for what happens when a consumer falls this far behind.
    public static let defaultEventBufferSize = 64

    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup
    private let requestTimeout: TimeInterval
    private let connectTimeout: TimeInterval
    private let maximumFrameSize: Int

    /// The capabilities to enable when QEMU offers them.
    ///
    /// Asking for a capability QEMU did not offer fails the negotiation, so this is
    /// intersected with the greeting rather than sent as-is. Pass `[]` to negotiate
    /// nothing.
    public let requestedCapabilities: Set<QMPCapability>

    /// The current connection, if any, the task consuming it, and what negotiation
    /// settled on.
    ///
    /// Boxed rather than held as `var`s: they are written during connect and
    /// teardown from a caller's task and read from wherever a command is issued,
    /// so they are genuinely shared. Holding them behind a lock is what lets this
    /// type be honestly `Sendable` instead of `@unchecked Sendable`.
    private struct State: Sendable {
        var connection: QMPConnection?
        var reader: Task<Void, Never>?
        var greeting: QMPGreeting?
        var negotiatedCapabilities: Set<QMPCapability> = []
    }
    private let state = NIOLockedValueBox(State())

    public init(
        logger: Logger = Logger(label: "SwiftQEMU.QMPClient"),
        requestTimeout: TimeInterval = QMPClient.defaultRequestTimeout,
        connectTimeout: TimeInterval = QMPClient.defaultConnectTimeout,
        maximumFrameSize: Int = QMPClient.defaultMaximumFrameSize,
        requestedCapabilities: Set<QMPCapability> = [.oob]
    ) {
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.connectTimeout = connectTimeout
        // A cap below one byte would reject the frame that is about to arrive
        // whatever it is, so clamp rather than let a caller disable framing.
        self.maximumFrameSize = max(1, maximumFrameSize)
        self.requestedCapabilities = requestedCapabilities
        // The process-wide singleton group, not a private one. A per-client
        // group costs a dedicated OS thread per VM, and tearing it down in
        // `deinit` meant a blocking `syncShutdownGracefully()` on whatever
        // thread released the last reference — including a Swift concurrency
        // cooperative thread, where blocking starves the shared pool.
        self.eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    }

    /// A client dropped without being disconnected would otherwise leave its
    /// reader task — and the connection that task holds — alive for as long as
    /// QEMU keeps the socket open. Closing the channel is what ends the loop.
    /// Nothing can be awaited here, so this is a backstop, not a substitute for
    /// ``disconnect()``.
    deinit {
        let abandoned = state.withLockedValue { $0 }
        abandoned.connection?.closeWithoutWaiting()
    }

    /// Whether the client currently has a usable connection.
    ///
    /// Derived from the channel rather than from a flag something has to remember
    /// to clear: a channel that has gone inactive is not a connection, whether it
    /// was closed here, by QEMU exiting, or by a framing failure.
    public var isConnected: Bool {
        state.withLockedValue { $0.connection?.isActive ?? false }
    }

    /// The greeting QEMU sent on the current connection, or `nil` when there is
    /// none. Carries the QEMU version and the capabilities it offered.
    public var greeting: QMPGreeting? {
        state.withLockedValue { $0.greeting }
    }

    /// The capabilities enabled on the current connection: the intersection of
    /// ``requestedCapabilities`` with what the greeting offered, once QEMU has
    /// accepted them.
    public var negotiatedCapabilities: Set<QMPCapability> {
        state.withLockedValue { $0.negotiatedCapabilities }
    }

    // MARK: - Events

    /// Subscribe to the asynchronous events QEMU emits on this connection.
    ///
    /// Every subscriber gets its own stream and sees every event, so an
    /// application can watch the VM without displacing ``QEMUManager``'s own
    /// bookkeeping. `DEVICE_DELETED` is published here too, but `device_del` does
    /// not rely on it: a detach needs a targeted, timed wait rather than a scan of
    /// a shared stream, so it keeps its dedicated ticket path.
    ///
    /// - Buffering: bounded at `bufferSize` events, keeping the newest and
    ///   discarding the oldest. A consumer that stops reading therefore loses
    ///   history but can never stall the loop delivering them, which is also the
    ///   loop delivering command replies and must not block.
    /// - Lifetime: the stream belongs to *this* connection and finishes when the
    ///   connection ends — `disconnect()`, or the peer going away — so a
    ///   `for await` loop terminates instead of parking forever. Reconnecting
    ///   means subscribing again.
    /// - Events emitted before this call are not replayed; subscribe first and
    ///   read the current state afterwards if you need both.
    ///
    /// - Throws: `QMPError.notConnected` if there is no connection to subscribe to.
    public func events(bufferSize: Int = QMPClient.defaultEventBufferSize) throws -> AsyncStream<QMPEvent> {
        try connectedConnection().events.subscribe(bufferSize: bufferSize)
    }

    // MARK: - Connection Management

    /// Connect to QEMU via Unix domain socket
    public func connectUnix(path: String) async throws {
        logger.info("Connecting to QEMU via Unix socket", metadata: ["path": .string(path)])

        // Retry connection with exponential backoff
        var retries = 0
        let maxRetries = 10
        var lastError: Error?

        while retries < maxRetries {
            do {
                try await connectOnce { bootstrap, initializer in
                    try await bootstrap.connect(
                        unixDomainSocketPath: path,
                        channelInitializer: initializer
                    )
                }
                logger.info("Connected to QEMU successfully")
                return
            } catch {
                // Clean up connection state before retry to avoid using stale connections
                await teardownFailedAttempt()

                lastError = error
                retries += 1

                if retries < maxRetries {
                    let delay = UInt64(min(100_000_000 * (1 << retries), 1_000_000_000)) // Exponential backoff, max 1 second
                    logger.debug("QMP connection attempt \(retries) failed, retrying in \(Double(delay) / 1_000_000_000)s: \(error)")
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        logger.error("Failed to connect to QMP after \(maxRetries) retries: \(lastError?.localizedDescription ?? "unknown error")")
        throw lastError ?? QMPError.notConnected
    }

    /// Connect to QEMU via TCP socket
    public func connectTCP(host: String, port: Int) async throws {
        logger.info("Connecting to QEMU via TCP", metadata: [
            "host": .string(host),
            "port": .stringConvertible(port)
        ])

        do {
            try await connectOnce { bootstrap, initializer in
                try await bootstrap.connect(host: host, port: port, channelInitializer: initializer)
            }
        } catch {
            await teardownFailedAttempt()
            throw error
        }

        logger.info("Connected to QEMU successfully")
    }

    /// One connect attempt: connect, start consuming inbound messages, negotiate.
    private func connectOnce(
        _ connect: (
            ClientBootstrap,
            @escaping @Sendable (Channel) -> EventLoopFuture<QMPAsyncChannel>
        ) async throws -> QMPAsyncChannel
    ) async throws {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let asyncChannel = try await connect(bootstrap, channelInitializer())
        let connection = QMPConnection(
            logger: logger,
            asyncChannel: asyncChannel,
            connectTimeout: connectTimeout
        )
        // The reader task captures the connection and not this client, so a client
        // that is dropped mid-connection can still be deinitialised.
        let reader = Task { await connection.run() }
        state.withLockedValue { $0 = State(connection: connection, reader: reader) }

        try await negotiateCapabilities(connection)
    }

    /// Build the pipeline for a fresh connection: frame the byte stream, then hand
    /// the framed messages to Swift concurrency.
    private func channelInitializer() -> @Sendable (Channel) -> EventLoopFuture<QMPAsyncChannel> {
        let maximumFrameSize = self.maximumFrameSize
        return { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    ByteToMessageHandler(QMPFrameDecoder(maximumFrameSize: maximumFrameSize))
                )
                return try QMPAsyncChannel(wrappingChannelSynchronously: channel)
            }
        }
    }

    /// Disconnect from QEMU.
    ///
    /// Idempotent, and never reports a peer that has already gone as a failure:
    /// QEMU exiting in response to `quit` closes the channel from its end, so a
    /// close here routinely races one that has already happened. Letting that
    /// escape meant `QEMUManager.destroy()` threw before terminating the process,
    /// leaving exactly the orphaned QEMU the cleanup path exists to prevent.
    ///
    /// Waits for the reader loop to finish, so anything parked on the connection
    /// has been failed by the time this returns rather than left to time out
    /// against a channel nobody owns any more.
    public func disconnect() async throws {
        let previous = takeState()
        guard let connection = previous.connection else { return }

        logger.info("Disconnecting from QEMU")
        await connection.close()
        await previous.reader?.value
        logger.info("Disconnected from QEMU")
    }

    /// Drop a half-open connection. Called when connect or negotiation fails so
    /// the next retry starts clean and no waiter is left holding a continuation on
    /// the abandoned channel.
    private func teardownFailedAttempt() async {
        let previous = takeState()
        guard let connection = previous.connection else { return }
        await connection.close()
        await previous.reader?.value
    }

    private func takeState() -> State {
        state.withLockedValue { state in
            let previous = state
            state = State()
            return previous
        }
    }

    // MARK: - QMP Commands

    /// Execute a QMP command
    public func execute(_ command: QMPCommand, arguments: [String: JSONValue]? = nil) async throws -> JSONValue? {
        try await send(command, arguments: arguments, outOfBand: false)
    }

    /// Execute a QMP command out-of-band, so it runs as soon as QEMU parses it
    /// rather than queueing behind whatever the monitor is working through.
    ///
    /// QEMU allows this only for commands its schema marks `allow-oob` — on 11.0.2
    /// `migrate-pause`, `migrate-recover`, `query-yank` and `yank`; anything else
    /// comes back as `The command <name> does not support OOB`. `quit` is *not*
    /// among them, so a wedged VM is unblocked with ``yank(instances:outOfBand:)``, not by
    /// forcing a quit through.
    ///
    /// - Throws: `QMPError.capabilityNotNegotiated` if `oob` is not enabled on this
    ///   connection, which is what QEMU's own `QMP input member 'exec-oob' is
    ///   unexpected` would otherwise amount to.
    public func executeOutOfBand(
        _ command: QMPCommand,
        arguments: [String: JSONValue]? = nil
    ) async throws -> JSONValue? {
        guard negotiatedCapabilities.contains(.oob) else {
            throw QMPError.capabilityNotNegotiated(.oob)
        }
        return try await send(command, arguments: arguments, outOfBand: true)
    }

    private func send(
        _ command: QMPCommand,
        arguments: [String: JSONValue]?,
        outOfBand: Bool
    ) async throws -> JSONValue? {
        let connection = try connectedConnection()

        let request = QMPRequest(execute: command.name, arguments: arguments, outOfBand: outOfBand)
        let response = try await connection.sendRequest(request, timeout: requestTimeout)

        if let error = response.error {
            throw QMPError.qmpError(error.class, error.desc)
        }

        return response.return
    }

    /// Query VM status
    ///
    /// Only `status` is load-bearing. Requiring every documented member meant a
    /// single dropped field failed the whole query — and `singlestep` is gone
    /// from modern QEMU, so the query failed always, leaving the manager to
    /// report `.unknown` for a perfectly healthy VM.
    public func queryStatus() async throws -> QMPStatusResponse {
        guard let result = try await execute(.queryStatus),
              let status = result["status"]?.stringValue else {
            throw QMPError.invalidResponse
        }

        return QMPStatusResponse(
            status: status,
            singlestep: result["singlestep"]?.boolValue,
            running: result["running"]?.boolValue ?? (status == "running")
        )
    }

    /// Continue VM execution
    public func cont() async throws {
        _ = try await execute(.cont)
    }

    /// Stop/pause VM execution
    public func stop() async throws {
        _ = try await execute(.stop)
    }

    /// Power down the VM
    public func systemPowerdown() async throws {
        _ = try await execute(.systemPowerdown)
    }

    /// Reset the VM
    public func systemReset() async throws {
        _ = try await execute(.systemReset)
    }

    /// Quit QEMU
    public func quit() async throws {
        _ = try await execute(.quit)
    }

    // MARK: - Block Device Hot-Plug Commands

    /// Add a qcow2 block device backend
    /// - Parameters:
    ///   - nodeName: Unique identifier for the block device (e.g., "drive-vdb")
    ///   - filename: Path to the disk image
    ///   - readOnly: Whether the disk is read-only
    public func blockdevAdd(nodeName: String, filename: String, readOnly: Bool = false) async throws {
        let arguments: [String: JSONValue] = [
            "driver": "qcow2",
            "node-name": .string(nodeName),
            "file": [
                "driver": "file",
                "filename": .string(filename)
            ],
            "read-only": .bool(readOnly)
        ]
        _ = try await execute(.blockdevAdd, arguments: arguments)
    }

    /// Remove a block device backend
    /// - Parameter nodeName: The node name used when adding the device
    public func blockdevDel(nodeName: String) async throws {
        _ = try await execute(.blockdevDel, arguments: ["node-name": .string(nodeName)])
    }

    /// Add a device (e.g., virtio-blk-pci)
    /// - Parameters:
    ///   - driver: Device driver type (default: "virtio-blk-pci")
    ///   - deviceId: Unique device identifier (e.g., "vdb")
    ///   - driveId: The node-name of the backing block device
    ///   - bus: Optional PCI bus to attach to
    public func deviceAdd(
        driver: String = "virtio-blk-pci",
        deviceId: String,
        driveId: String,
        bus: String? = nil
    ) async throws {
        var arguments: [String: JSONValue] = [
            "driver": .string(driver),
            "id": .string(deviceId),
            "drive": .string(driveId)
        ]
        if let bus = bus {
            arguments["bus"] = .string(bus)
        }
        _ = try await execute(.deviceAdd, arguments: arguments)
    }

    /// Remove a device and wait for DEVICE_DELETED event
    /// - Parameters:
    ///   - deviceId: The device ID to remove
    ///   - timeout: Timeout in seconds for waiting on DEVICE_DELETED event
    public func deviceDel(deviceId: String, timeout: TimeInterval = 5) async throws {
        let connection = try connectedConnection()

        // Registered before the command goes out: QEMU can emit DEVICE_DELETED
        // ahead of its reply, and an interest registered afterwards would miss it.
        let ticket = await connection.expectDeviceDeleted(deviceId: deviceId, timeout: timeout)
        do {
            _ = try await execute(.deviceDel, arguments: ["id": .string(deviceId)])
        } catch {
            await connection.cancelExpectation(ticket)
            throw error
        }

        try await connection.waitForDeviceDeleted(ticket)
    }

    /// Query attached block devices
    public func queryBlock() async throws -> [JSONValue] {
        try await execute(.queryBlock)?.arrayValue ?? []
    }

    // MARK: - Yank

    /// The instances that can currently be yanked, as QEMU describes them — each a
    /// `{"type": ..., "id": ...}` object suitable for handing straight back to
    /// ``yank(instances:outOfBand:)``.
    ///
    /// - Parameter outOfBand: Run the query out-of-band. Requires the `oob`
    ///   capability, and is the point of it: the answer arrives even when the
    ///   monitor is blocked.
    public func queryYank(outOfBand: Bool = false) async throws -> [JSONValue] {
        let result = outOfBand
            ? try await executeOutOfBand(.queryYank)
            : try await execute(.queryYank)
        return result?.arrayValue ?? []
    }

    /// Yank the given instances: QEMU tears down the underlying connections
    /// (chardev, block device, migration) without waiting for them to respond.
    ///
    /// The recovery path for a VM stuck on an unresponsive backend — a block device
    /// on a hung NFS mount, for instance — where an in-band command would queue
    /// behind the very operation that is stuck. Pass `outOfBand: true` for that
    /// case; it is what the `oob` capability is negotiated for.
    ///
    /// Yanking a chardev instance can close this monitor's own socket, so treat a
    /// lost connection afterwards as expected rather than as a failure.
    public func yank(instances: [JSONValue], outOfBand: Bool = false) async throws {
        let arguments: [String: JSONValue] = ["instances": .array(instances)]
        if outOfBand {
            _ = try await executeOutOfBand(.yank, arguments: arguments)
        } else {
            _ = try await execute(.yank, arguments: arguments)
        }
    }

    // MARK: - Private Methods

    private func connectedConnection() throws -> QMPConnection {
        guard let connection = state.withLockedValue({ $0.connection }), connection.isActive else {
            throw QMPError.notConnected
        }
        return connection
    }

    /// Wait for the greeting, then enable the capabilities it offers that we asked
    /// for.
    ///
    /// The greeting used to be waited on and discarded, which left `oob`
    /// permanently off however new the QEMU was. Only the offered subset is
    /// requested: `qmp_capabilities` fails outright on a capability QEMU did not
    /// advertise, and a failed negotiation leaves a monitor that refuses every
    /// subsequent command.
    private func negotiateCapabilities(_ connection: QMPConnection) async throws {
        // The greeting comes back from the wait rather than being fetched
        // afterwards, so there is no question of whether the value is visible yet.
        let greeting = try await connection.waitForGreeting()
        let offered = Set(greeting.QMP.capabilities.compactMap(QMPCapability.init(rawValue:)))
        let toEnable = offered.intersection(requestedCapabilities)

        // Omitted entirely when there is nothing to enable, so a QEMU predating
        // the `enable` argument still negotiates.
        let arguments: [String: JSONValue]? = toEnable.isEmpty
            ? nil
            : ["enable": .array(toEnable.map(\.rawValue).sorted().map(JSONValue.string))]

        let request = QMPRequest(execute: QMPCommand.capabilities.name, arguments: arguments)
        let response = try await connection.sendRequest(request, timeout: connectTimeout)

        // A rejected negotiation is fatal for the connection — QEMU answers every
        // later command with "Expecting capabilities negotiation" — so it must not
        // be swallowed the way it was when the reply went unread.
        if let error = response.error {
            throw QMPError.qmpError(error.class, error.desc)
        }

        state.withLockedValue {
            $0.greeting = greeting
            $0.negotiatedCapabilities = toEnable
        }

        logger.debug("QMP capabilities negotiated", metadata: [
            "offered": .string(offered.map(\.rawValue).sorted().joined(separator: ",")),
            "enabled": .string(toEnable.map(\.rawValue).sorted().joined(separator: ","))
        ])
    }
}
