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

    /// Default depth of a subscriber's event buffer. See ``events(bufferSize:)``
    /// for what happens when a consumer falls this far behind.
    public static let defaultEventBufferSize = 64

    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup
    private let requestTimeout: TimeInterval
    private let connectTimeout: TimeInterval

    /// The capabilities to enable when QEMU offers them.
    ///
    /// Asking for a capability QEMU did not offer fails the negotiation, so this is
    /// intersected with the greeting rather than sent as-is. Pass `[]` to negotiate
    /// nothing.
    public let requestedCapabilities: Set<QMPCapability>

    /// Connection state.
    ///
    /// Boxed rather than held as `var`s: the channel and the connected flag are
    /// written during connect/teardown from a caller's task and read from the
    /// event loop when the peer goes away, so they are genuinely shared. Holding
    /// them behind a lock is what lets this type be honestly `Sendable` instead
    /// of `@unchecked Sendable`.
    private struct State: Sendable {
        var channel: Channel?
        var handler: QMPChannelHandler?
        var isConnected = false
        var greeting: QMPGreeting?
        var negotiatedCapabilities: Set<QMPCapability> = []
    }
    private let state = NIOLockedValueBox(State())

    public init(
        logger: Logger = Logger(label: "SwiftQEMU.QMPClient"),
        requestTimeout: TimeInterval = QMPClient.defaultRequestTimeout,
        connectTimeout: TimeInterval = QMPClient.defaultConnectTimeout,
        requestedCapabilities: Set<QMPCapability> = [.oob]
    ) {
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.connectTimeout = connectTimeout
        self.requestedCapabilities = requestedCapabilities
        // The process-wide singleton group, not a private one. A per-client
        // group costs a dedicated OS thread per VM, and tearing it down in
        // `deinit` meant a blocking `syncShutdownGracefully()` on whatever
        // thread released the last reference — including a Swift concurrency
        // cooperative thread, where blocking starves the shared pool.
        self.eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    }

    /// Whether the client currently believes it has a usable connection.
    public var isConnected: Bool {
        state.withLockedValue { $0.isConnected }
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
    ///   history but can never stall the event loop, which is delivering these
    ///   from NIO and must not block.
    /// - Lifetime: the stream belongs to *this* connection and finishes when the
    ///   connection ends — `disconnect()`, or the peer going away — so a
    ///   `for await` loop terminates instead of parking forever. Reconnecting
    ///   means subscribing again.
    /// - Events emitted before this call are not replayed; subscribe first and
    ///   read the current state afterwards if you need both.
    ///
    /// - Throws: `QMPError.notConnected` if there is no connection to subscribe to.
    public func events(bufferSize: Int = QMPClient.defaultEventBufferSize) throws -> AsyncStream<QMPEvent> {
        try connectedHandler().subscribeToEvents(bufferSize: bufferSize)
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
                try await connectOnce { bootstrap in
                    try await bootstrap.connect(unixDomainSocketPath: path).get()
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
            try await connectOnce { bootstrap in
                try await bootstrap.connect(host: host, port: port).get()
            }
        } catch {
            await teardownFailedAttempt()
            throw error
        }

        logger.info("Connected to QEMU successfully")
    }

    /// One connect attempt: fresh handler, connect, negotiate.
    private func connectOnce(
        _ connect: (ClientBootstrap) async throws -> Channel
    ) async throws {
        // A fresh handler per attempt: a handler that saw a failed negotiation
        // has latched its greeting/close state and must not be reused for the
        // next connection.
        let state = self.state
        let handler = QMPChannelHandler(logger: logger) {
            // The peer going away must clear the connected flag, so a later
            // command fails as not-connected rather than being written into a
            // dead channel and waiting out its timeout.
            state.withLockedValue { $0.isConnected = false }
        }

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(handler)
            }

        state.withLockedValue { $0.handler = handler }
        let channel = try await connect(bootstrap)
        state.withLockedValue {
            $0.channel = channel
            $0.isConnected = true
        }

        // Wait for greeting and negotiate capabilities
        try await negotiateCapabilities(handler: handler)
    }

    /// Disconnect from QEMU.
    ///
    /// Idempotent, and never reports a peer that has already gone as a failure:
    /// QEMU exiting in response to `quit` closes the channel from its end, so
    /// the close here fails with `ChannelError.alreadyClosed`. Letting that
    /// escape meant `QEMUManager.destroy()` threw before terminating the
    /// process, leaving an orphaned QEMU behind — the exact outcome the cleanup
    /// path exists to prevent.
    public func disconnect() async throws {
        let previous = state.withLockedValue { state -> State in
            let previous = state
            state = State()
            return previous
        }

        guard previous.isConnected || previous.channel != nil else { return }

        logger.info("Disconnecting from QEMU")

        // Fail anything parked on this connection rather than leaving it to time
        // out against a channel nobody owns any more.
        previous.handler?.failAllWaiters(with: QMPError.connectionLost)

        do {
            try await previous.channel?.close()
        } catch ChannelError.alreadyClosed {
            logger.debug("QMP channel was already closed by the peer")
        }

        logger.info("Disconnected from QEMU")
    }

    /// Drop a half-open connection, failing anything still parked on it. Called
    /// when connect or negotiation fails so the next retry starts clean and no
    /// waiter is left holding a continuation on the abandoned channel.
    private func teardownFailedAttempt() async {
        let previous = state.withLockedValue { state -> State in
            let previous = state
            state = State()
            return previous
        }
        previous.handler?.failAllWaiters(with: QMPError.connectionLost)
        try? await previous.channel?.close()
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
        let handler = try connectedHandler()

        let request = QMPRequest(execute: command.name, arguments: arguments, outOfBand: outOfBand)

        guard let response = try await handler.sendRequest(request, timeout: requestTimeout) else {
            throw QMPError.invalidResponse
        }

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
        let handler = try connectedHandler()

        // Registered before the command goes out: QEMU can emit DEVICE_DELETED
        // ahead of its reply, and an interest registered afterwards would miss it.
        let ticket = handler.expectDeviceDeleted(deviceId: deviceId)
        do {
            _ = try await execute(.deviceDel, arguments: ["id": .string(deviceId)])
        } catch {
            handler.cancelExpectation(ticket)
            throw error
        }

        try await handler.waitForDeviceDeleted(ticket, timeout: timeout)
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

    private func connectedHandler() throws -> QMPChannelHandler {
        let state = self.state.withLockedValue { $0 }
        guard state.isConnected, let handler = state.handler else {
            throw QMPError.notConnected
        }
        return handler
    }

    /// Wait for the greeting, then enable the capabilities it offers that we asked
    /// for.
    ///
    /// The greeting used to be waited on and discarded, which left `oob`
    /// permanently off however new the QEMU was. Only the offered subset is
    /// requested: `qmp_capabilities` fails outright on a capability QEMU did not
    /// advertise, and a failed negotiation leaves a monitor that refuses every
    /// subsequent command.
    private func negotiateCapabilities(handler: QMPChannelHandler) async throws {
        try await handler.waitForGreeting(timeout: connectTimeout)

        let greeting = handler.receivedGreeting
        let offered = Set((greeting?.QMP.capabilities ?? []).compactMap(QMPCapability.init(rawValue:)))
        let toEnable = offered.intersection(requestedCapabilities)

        // Omitted entirely when there is nothing to enable, so a QEMU predating
        // the `enable` argument still negotiates.
        let arguments: [String: JSONValue]? = toEnable.isEmpty
            ? nil
            : ["enable": .array(toEnable.map(\.rawValue).sorted().map(JSONValue.string))]

        let request = QMPRequest(execute: QMPCommand.capabilities.name, arguments: arguments)
        let response = try await handler.sendRequest(request, timeout: connectTimeout)

        // A rejected negotiation is fatal for the connection — QEMU answers every
        // later command with "Expecting capabilities negotiation" — so it must not
        // be swallowed the way it was when the reply went unread.
        if let error = response?.error {
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

// MARK: - QMP Channel Handler

private final class QMPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let logger: Logger
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// Invoked once the connection is no longer usable, so the owning client can
    /// stop reporting itself as connected.
    private let onConnectionLost: @Sendable () -> Void

    /// Guards every field below. Waiters are installed from arbitrary Swift
    /// concurrency threads while the event loop resumes them, so all of this
    /// state is genuinely shared. Continuations are always *removed* under the
    /// lock and resumed after unlocking, which gives each one exactly one
    /// resume without ever calling out while holding the lock.
    private let lock = NIOLock()

    /// A one-shot signal that may be satisfied before anyone waits on it.
    private enum Latch {
        case pending
        case satisfied
        case failed(Error)
    }

    private var greeting: Latch = .pending
    private var greetingContinuation: CheckedContinuation<Void, Error>?
    /// The greeting itself, kept rather than discarded: its `capabilities` list is
    /// what capability negotiation has to be driven from.
    private var greetingMessage: QMPGreeting?
    /// One continuation per live `events()` subscription. Several consumers can
    /// watch the same connection, so this is a map rather than a single slot; each
    /// is yielded to independently and none can block the others.
    private var eventSubscribers: [UInt64: AsyncStream<QMPEvent>.Continuation] = [:]
    /// Outstanding requests in submission order, keyed for out-of-order and
    /// timed-out removal. QMP echoes our `id` back, so a response is matched to
    /// its request rather than to whatever happens to be at the head.
    private var pendingRequests: [(id: String, continuation: CheckedContinuation<QMPResponse?, Error>)] = []
    /// One entry per outstanding `device_del`, keyed by ticket token rather than
    /// by device id. A single slot per device meant two concurrent waits on the
    /// same device overwrote each other, abandoning the first continuation with
    /// nothing to resume it and no deadline to fail it.
    private var deviceDeletions: [UInt64: PendingDeletion] = [:]

    private struct PendingDeletion {
        let deviceId: String
        /// The event arrived before the caller got around to waiting.
        var seen = false
        var continuation: CheckedContinuation<Void, Error>?
    }
    /// Set once the channel goes inactive, so waiters that arrive afterwards
    /// fail immediately instead of parking on a dead connection.
    private var closeError: Error?
    private var nextRequestID: UInt64 = 0
    private var nextWaiterToken: UInt64 = 0
    private weak var channel: Channel?

    /// Event-loop-confined: only touched from `channelRead`.
    private var buffer = ByteBuffer()

    init(logger: Logger, onConnectionLost: @escaping @Sendable () -> Void = {}) {
        self.logger = logger
        self.onConnectionLost = onConnectionLost
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = self.unwrapInboundIn(data)
        buffer.writeBuffer(&input)

        // Process complete JSON messages
        while let message = extractJSONMessage() {
            processMessage(message)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("QMP channel became inactive")
        failAllWaiters(with: QMPError.connectionLost)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("QMP channel error: \(error)")
        context.close(promise: nil)
    }

    /// Fail everything parked on this connection and latch the failure so later
    /// waiters fail fast too.
    func failAllWaiters(with error: Error) {
        lock.lock()
        let requests = pendingRequests
        pendingRequests.removeAll()
        let deviceWaiters = deviceDeletions.values.compactMap(\.continuation)
        deviceDeletions.removeAll()
        let greetingWaiter = greetingContinuation
        greetingContinuation = nil
        if case .pending = greeting {
            greeting = .failed(error)
        }
        // Event streams end with the connection they belong to, so a `for await`
        // over one completes rather than parking on a channel nobody owns.
        let subscribers = Array(eventSubscribers.values)
        eventSubscribers.removeAll()
        let isFirstClose = closeError == nil
        if isFirstClose {
            closeError = error
        }
        lock.unlock()

        for request in requests {
            request.continuation.resume(throwing: error)
        }
        for waiter in deviceWaiters {
            waiter.resume(throwing: error)
        }
        // Finished outside the lock: `finish()` invokes the termination handler,
        // which takes the same non-recursive lock.
        for subscriber in subscribers {
            subscriber.finish()
        }
        greetingWaiter?.resume(throwing: error)

        if isFirstClose {
            onConnectionLost()
        }
    }

    /// The greeting received on this connection, if it has arrived.
    var receivedGreeting: QMPGreeting? {
        lock.lock()
        defer { lock.unlock() }
        return greetingMessage
    }

    /// A new independent event stream over this connection.
    ///
    /// The subscriber is registered synchronously, inside `AsyncStream`'s build
    /// closure, so events cannot slip through between the call and the first
    /// iteration of the caller's loop.
    func subscribeToEvents(bufferSize: Int) -> AsyncStream<QMPEvent> {
        AsyncStream(QMPEvent.self, bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            lock.lock()
            if closeError != nil {
                // Already dead: hand back a stream that is simply over, rather than
                // one that will never produce anything and never end.
                lock.unlock()
                continuation.finish()
                return
            }
            nextWaiterToken += 1
            let token = nextWaiterToken
            eventSubscribers[token] = continuation
            lock.unlock()

            // Drops the registration when the consumer stops iterating (or its task
            // is cancelled), so an abandoned stream is not yielded to forever.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.eventSubscribers.removeValue(forKey: token)
                self.lock.unlock()
            }
        }
    }

    /// Deliver one event to every live subscriber.
    ///
    /// Called from the event loop, so it must not block: `bufferingNewest` makes
    /// `yield` non-blocking, discarding a slow subscriber's oldest event instead of
    /// applying backpressure to QEMU's socket.
    private func broadcast(_ event: QMPEvent) {
        lock.lock()
        let subscribers = Array(eventSubscribers.values)
        lock.unlock()

        for subscriber in subscribers {
            subscriber.yield(event)
        }
    }

    func waitForGreeting(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            switch greeting {
            case .satisfied:
                // The greeting landed before we got here. Latching it is
                // what keeps this from parking forever.
                lock.unlock()
                continuation.resume()
                return
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
                return
            case .pending:
                guard greetingContinuation == nil else {
                    // Overwriting the slot would abandon the first waiter with
                    // no resume and no deadline. Only negotiation waits here, so
                    // a second waiter is a programming error, not a race.
                    lock.unlock()
                    continuation.resume(throwing: QMPError.invalidResponse)
                    return
                }
                greetingContinuation = continuation
                lock.unlock()
            }
            armDeadline(timeout) { [weak self] in self?.timeOutGreeting() }
        }
    }

    private func timeOutGreeting() {
        lock.lock()
        let waiter = greetingContinuation
        greetingContinuation = nil
        lock.unlock()
        waiter?.resume(throwing: QMPError.timeout)
    }

    /// A registered interest in the `DEVICE_DELETED` for one `device_del`.
    struct DeletionTicket {
        let token: UInt64
    }

    /// Register interest *before* `device_del` is sent.
    ///
    /// QEMU may emit `DEVICE_DELETED` before its reply to the command reaches us,
    /// and a waiter installed only afterwards misses the event and waits out the
    /// full timeout. Registering first makes the ordering irrelevant. Scoping the
    /// record to this specific command matters too: a free-floating "this device
    /// was deleted" latch would still be sitting there if the guest ejected a
    /// device nobody was waiting on, and would then falsely satisfy a later
    /// detach of a device re-added under the same name.
    func expectDeviceDeleted(deviceId: String) -> DeletionTicket {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterToken += 1
        deviceDeletions[nextWaiterToken] = PendingDeletion(deviceId: deviceId)
        return DeletionTicket(token: nextWaiterToken)
    }

    /// Drop a registration whose command never made it out.
    func cancelExpectation(_ ticket: DeletionTicket) {
        lock.lock()
        let abandoned = deviceDeletions.removeValue(forKey: ticket.token)
        lock.unlock()
        abandoned?.continuation?.resume(throwing: QMPError.connectionLost)
    }

    func waitForDeviceDeleted(_ ticket: DeletionTicket, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard var pending = deviceDeletions[ticket.token] else {
                // Torn down under us — the connection dropped between the command
                // and this wait.
                let error = closeError ?? QMPError.connectionLost
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            if let closeError {
                deviceDeletions.removeValue(forKey: ticket.token)
                lock.unlock()
                continuation.resume(throwing: closeError)
                return
            }
            if pending.seen {
                deviceDeletions.removeValue(forKey: ticket.token)
                lock.unlock()
                continuation.resume()
                return
            }
            pending.continuation = continuation
            deviceDeletions[ticket.token] = pending
            lock.unlock()
            armDeadline(timeout) { [weak self] in
                self?.timeOutDeviceDeleted(token: ticket.token)
            }
        }
    }

    private func timeOutDeviceDeleted(token: UInt64) {
        lock.lock()
        // Removing by token is what keeps a deadline from failing a *different*
        // wait for the same device.
        let waiter = deviceDeletions.removeValue(forKey: token)?.continuation
        lock.unlock()
        waiter?.resume(throwing: QMPError.timeout)
    }

    func sendRequest(_ request: QMPRequest, timeout: TimeInterval) async throws -> QMPResponse? {
        lock.lock()
        if let closeError {
            lock.unlock()
            throw closeError
        }
        guard let channel = channel else {
            lock.unlock()
            throw QMPError.notConnected
        }
        nextRequestID += 1
        let id = "swiftqemu-\(nextRequestID)"
        lock.unlock()

        // Tag the request so its response can be correlated back to it. Without
        // an id, matching is positional — and a single timed-out request would
        // shift every later response onto the wrong caller. It matters twice as
        // much for an out-of-band request, which is answered out of order by
        // definition — so `outOfBand` has to be carried across this rebuild, or the
        // command silently goes out in-band.
        let identified = QMPRequest(
            execute: request.execute,
            arguments: request.arguments,
            id: id,
            outOfBand: request.outOfBand
        )
        let data = try encoder.encode(identified)
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeString("\n")
        let outbound = buffer

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QMPResponse?, Error>) in
            lock.lock()
            if let closeError {
                lock.unlock()
                continuation.resume(throwing: closeError)
                return
            }
            pendingRequests.append((id: id, continuation: continuation))
            lock.unlock()
            channel.writeAndFlush(outbound, promise: nil)
            armDeadline(timeout) { [weak self] in self?.timeOutRequest(id: id) }
        }
    }

    /// Start the deadline for a waiter that is *already installed*.
    ///
    /// Ordering is the whole point. Racing the deadline against the parking
    /// task in a group let the deadline fire first, in which case it found no
    /// waiter to fail, and the task then parked on a continuation nobody would
    /// ever resume — a timeout that hangs, the exact failure this file exists
    /// to remove. Arming only after installation makes that unrepresentable:
    /// the deadline either finds the waiter or finds it already resolved.
    ///
    /// A non-positive timeout expires immediately rather than never.
    private func armDeadline(_ seconds: TimeInterval, _ expire: @escaping @Sendable () -> Void) {
        guard seconds > 0 else {
            expire()
            return
        }
        // Detached so it cannot inherit cancellation from the caller: a
        // cancelled deadline that skipped `expire` would strand the waiter.
        Task.detached {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            // A no-op once the waiter resolved normally: every timeOut* helper
            // removes by key under the lock, so it fails only a live waiter.
            expire()
        }
    }

    private func timeOutRequest(id: String) {
        lock.lock()
        var waiter: CheckedContinuation<QMPResponse?, Error>?
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            waiter = pendingRequests.remove(at: index).continuation
        }
        lock.unlock()
        waiter?.resume(throwing: QMPError.timeout)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        self.channel = context.channel
        lock.unlock()
    }

    private func extractJSONMessage() -> Data? {
        // Look for complete JSON objects ending with newline
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }

        let messageLength = buffer.readableBytesView.startIndex.distance(to: newlineIndex) + 1
        guard let slice = buffer.readSlice(length: messageLength) else {
            return nil
        }
        // Reclaim the space this message occupied instead of letting the read
        // region grow for the lifetime of the connection.
        buffer.discardReadBytes()

        return Data(slice.readableBytesView.dropLast()) // Remove newline
    }

    private func processMessage(_ data: Data) {
        let message: QMPMessage
        do {
            message = try decoder.decode(QMPMessage.self, from: data)
        } catch {
            logger.warning("Unknown QMP message format", metadata: [
                "error": .string("\(error)")
            ])
            return
        }

        switch message {
        case .greeting(let greetingMessage):
            handleGreeting(greetingMessage)
        case .response(let response):
            handleResponse(response)
        case .event(let event):
            handleEvent(event)
        }
    }

    private func handleGreeting(_ greetingMessage: QMPGreeting) {
        logger.debug("Received QMP greeting", metadata: [
            "version": .stringConvertible("\(greetingMessage.QMP.version.qemu.major).\(greetingMessage.QMP.version.qemu.minor).\(greetingMessage.QMP.version.qemu.micro)"),
            "capabilities": .string(greetingMessage.QMP.capabilities.joined(separator: ","))
        ])
        lock.lock()
        // Stored under the same lock as the latch, so a negotiation woken by the
        // latch is guaranteed to see the greeting it was waiting for.
        self.greetingMessage = greetingMessage
        if case .pending = greeting {
            greeting = .satisfied
        }
        let waiter = greetingContinuation
        greetingContinuation = nil
        lock.unlock()
        waiter?.resume()
    }

    private func handleResponse(_ response: QMPResponse) {
        lock.lock()
        var waiter: CheckedContinuation<QMPResponse?, Error>?
        var unmatchedID: String?
        if let id = response.id?.stringValue {
            // Tagged: match strictly, and drop it if nothing matches. A
            // tagged response with no waiter is a late reply to a request
            // that already timed out — QEMU still answers those. Falling
            // back to FIFO here would hand it to whichever request is
            // pending *now*, which is precisely the response-shift
            // corruption id correlation exists to prevent.
            if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
                waiter = pendingRequests.remove(at: index).continuation
            } else {
                unmatchedID = id
            }
        } else if !pendingRequests.isEmpty {
            // Untagged (an older QEMU that does not echo `id`): submission
            // order is the only correlation available.
            waiter = pendingRequests.removeFirst().continuation
        }
        lock.unlock()

        if let unmatchedID {
            logger.debug(
                "Discarding QMP response with no matching request",
                metadata: ["id": .string(unmatchedID)])
        }
        waiter?.resume(returning: response)
    }

    private func handleEvent(_ event: QMPEvent) {
        logger.debug("Received QMP event", metadata: ["event": .string(event.event)])

        // The dedicated waiter first, then everyone watching. A detach needs a
        // targeted, timed wait, so it keeps its ticket path rather than scanning
        // the shared stream — but the event is still worth publishing.
        if event.event == QMPEventName.deviceDeleted,
           let device = event.data?["device"]?.stringValue {
            resolveDeviceDeletion(device: device)
        }

        broadcast(event)
    }

    private func resolveDeviceDeletion(device: String) {
        lock.lock()
        // The oldest outstanding expectation for this device, so repeated
        // detaches are matched in the order they were issued.
        let token = deviceDeletions
            .filter { $0.value.deviceId == device }
            .keys
            .min()
        var waiter: CheckedContinuation<Void, Error>?
        if let token {
            if let continuation = deviceDeletions[token]?.continuation {
                deviceDeletions.removeValue(forKey: token)
                waiter = continuation
            } else {
                // The command has not been answered yet; record it so the wait
                // that follows returns at once instead of timing out.
                deviceDeletions[token]?.seen = true
            }
        }
        lock.unlock()

        waiter?.resume()
    }
}
