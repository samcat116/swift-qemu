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

    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup
    private let requestTimeout: TimeInterval
    private let connectTimeout: TimeInterval

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
    }
    private let state = NIOLockedValueBox(State())

    public init(
        logger: Logger = Logger(label: "SwiftQEMU.QMPClient"),
        requestTimeout: TimeInterval = QMPClient.defaultRequestTimeout,
        connectTimeout: TimeInterval = QMPClient.defaultConnectTimeout
    ) {
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.connectTimeout = connectTimeout
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
        let handler = try connectedHandler()

        let request = QMPRequest(execute: command.name, arguments: arguments)

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

    // MARK: - Private Methods

    private func connectedHandler() throws -> QMPChannelHandler {
        let state = self.state.withLockedValue { $0 }
        guard state.isConnected, let handler = state.handler else {
            throw QMPError.notConnected
        }
        return handler
    }

    private func negotiateCapabilities(handler: QMPChannelHandler) async throws {
        // Wait for greeting
        try await handler.waitForGreeting(timeout: connectTimeout)

        // Send capabilities command
        let request = QMPRequest(execute: QMPCommand.capabilities.name)
        _ = try await handler.sendRequest(request, timeout: connectTimeout)

        logger.debug("QMP capabilities negotiated")
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
    private var greetingDeadline: Scheduled<Void>?
    /// The task waiting on the greeting was cancelled. Latched, because the
    /// cancellation can land before the waiter parks.
    private var greetingCancelled = false
    /// Outstanding requests in submission order, keyed for out-of-order and
    /// timed-out removal. QMP echoes our `id` back, so a response is matched to
    /// its request rather than to whatever happens to be at the head.
    private var pendingRequests: [PendingRequest] = []
    /// One entry per outstanding `device_del`, keyed by ticket token rather than
    /// by device id. A single slot per device meant two concurrent waits on the
    /// same device overwrote each other, abandoning the first continuation with
    /// nothing to resume it and no deadline to fail it.
    private var deviceDeletions: [UInt64: PendingDeletion] = [:]

    /// One outstanding QMP command.
    ///
    /// The record is created before the command is written and before the caller
    /// parks on it, so a cancellation that arrives first has something to mark
    /// rather than nothing at all. The caller then finds that mark and resumes
    /// itself, instead of parking behind a canceller that has already been and
    /// gone — the same ordering hazard the deadlines have to respect.
    private struct PendingRequest {
        let id: String
        /// `nil` until the caller parks. A record without one has not been
        /// written to the channel yet, so no response can belong to it.
        var continuation: CheckedContinuation<QMPResponse?, Error>?
        /// Cancelled the moment the request resolves, so no deadline outlives
        /// the thing it bounds.
        var deadline: Scheduled<Void>?
        /// The waiting task was cancelled before it parked.
        var cancelled = false
    }

    private struct PendingDeletion {
        let deviceId: String
        /// The event arrived before the caller got around to waiting.
        var seen = false
        var continuation: CheckedContinuation<Void, Error>?
        var deadline: Scheduled<Void>?
        /// The waiting task was cancelled before it parked.
        var cancelled = false
    }
    /// Set once the channel goes inactive, so waiters that arrive afterwards
    /// fail immediately instead of parking on a dead connection.
    private var closeError: Error?
    private var nextRequestID: UInt64 = 0
    private var nextWaiterToken: UInt64 = 0
    private weak var channel: Channel?
    /// The loop deadlines are scheduled on, captured when the handler joins a
    /// pipeline. Held strongly and separately from `channel`, which is weak: a
    /// waiter whose channel has gone still has to be bounded.
    private var deadlineLoop: EventLoop?

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
        let deletions = Array(deviceDeletions.values)
        deviceDeletions.removeAll()
        let greetingWaiter = greetingContinuation
        greetingContinuation = nil
        let greetingDeadline = self.greetingDeadline
        self.greetingDeadline = nil
        if case .pending = greeting {
            greeting = .failed(error)
        }
        let isFirstClose = closeError == nil
        if isFirstClose {
            closeError = error
        }
        lock.unlock()

        // Every deadline goes with the waiter it bounded — there is nothing left
        // for it to fail, and leaving it scheduled would keep this handler alive
        // until it fired.
        for request in requests {
            request.deadline?.cancel()
            request.continuation?.resume(throwing: error)
        }
        for deletion in deletions {
            deletion.deadline?.cancel()
            deletion.continuation?.resume(throwing: error)
        }
        greetingDeadline?.cancel()
        greetingWaiter?.resume(throwing: error)

        if isFirstClose {
            onConnectionLost()
        }
    }

    func waitForGreeting(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !greetingCancelled else {
                    // Cancelled before we parked. The latch is what makes that
                    // ordering harmless: without it the canceller would find no
                    // waiter, and this continuation would park behind it.
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
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
                attachGreetingDeadline(armDeadline(timeout) { [weak self] in self?.timeOutGreeting() })
            }
        } onCancel: {
            self.cancelGreeting()
        }
    }

    private func timeOutGreeting() {
        lock.lock()
        let waiter = greetingContinuation
        greetingContinuation = nil
        greetingDeadline = nil
        lock.unlock()
        waiter?.resume(throwing: QMPError.timeout)
    }

    private func cancelGreeting() {
        lock.lock()
        greetingCancelled = true
        let waiter = greetingContinuation
        greetingContinuation = nil
        let deadline = greetingDeadline
        greetingDeadline = nil
        lock.unlock()
        deadline?.cancel()
        waiter?.resume(throwing: CancellationError())
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
        abandoned?.deadline?.cancel()
        abandoned?.continuation?.resume(throwing: QMPError.connectionLost)
    }

    func waitForDeviceDeleted(_ ticket: DeletionTicket, timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
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
                if pending.cancelled {
                    // Cancelled before we parked. Checked ahead of `seen` so the
                    // answer is the same whichever way that race lands:
                    // cancellation does not un-detach the device either way, and
                    // first-mover-wins is the rule callers can reason about.
                    deviceDeletions.removeValue(forKey: ticket.token)
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
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
                attachDeadline(
                    armDeadline(timeout) { [weak self] in
                        self?.timeOutDeviceDeleted(token: ticket.token)
                    },
                    toDeletion: ticket.token
                )
            }
        } onCancel: {
            self.cancelDeviceDeleted(token: ticket.token)
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

    private func cancelDeviceDeleted(token: UInt64) {
        lock.lock()
        var waiter: CheckedContinuation<Void, Error>?
        var deadline: Scheduled<Void>?
        if var pending = deviceDeletions[token] {
            if let continuation = pending.continuation {
                deadline = pending.deadline
                deviceDeletions.removeValue(forKey: token)
                waiter = continuation
            } else {
                // Not parked yet — leave the record behind, marked, for the wait
                // to find. Removing it here would send that wait down the
                // "torn down under us" path and report a connection loss that
                // did not happen.
                pending.cancelled = true
                deviceDeletions[token] = pending
            }
        }
        lock.unlock()
        deadline?.cancel()
        waiter?.resume(throwing: CancellationError())
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
        // shift every later response onto the wrong caller.
        let identified = QMPRequest(
            execute: request.execute,
            arguments: request.arguments,
            id: id
        )
        // Encoded before the record is registered, so a failure here cannot
        // leave an entry behind with nothing to resolve it.
        let data = try encoder.encode(identified)
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeString("\n")
        let outbound = buffer

        lock.lock()
        if let closeError {
            lock.unlock()
            throw closeError
        }
        // Registered before the cancellation handler is installed so that a
        // cancellation landing first has a record to mark. Nothing has been
        // written yet, so no response can arrive for it in the meantime.
        pendingRequests.append(PendingRequest(id: id))
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QMPResponse?, Error>) in
                lock.lock()
                guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
                    // Torn down under us between registration and here.
                    let error = closeError ?? QMPError.connectionLost
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                if pendingRequests[index].cancelled {
                    // Cancelled before we parked, so the command is never
                    // written at all.
                    pendingRequests.remove(at: index)
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[index].continuation = continuation
                lock.unlock()
                channel.writeAndFlush(outbound, promise: nil)
                attachDeadline(
                    armDeadline(timeout) { [weak self] in self?.timeOutRequest(id: id) },
                    toRequest: id
                )
            }
        } onCancel: {
            self.cancelRequest(id: id)
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
    /// Scheduled on the channel's event loop rather than run as a task of its
    /// own. A `Task.detached` per waiter slept out the whole budget even once
    /// its waiter had resolved, so a burst of commands left one task per command
    /// idling for the full timeout. The returned `Scheduled` goes to the waiter,
    /// which cancels it the moment it resolves, so a deadline never outlives
    /// what it bounds. Scheduling also keeps the deadline out of reach of the
    /// caller's cancellation, which is the property the detached task existed
    /// for: a deadline that inherited cancellation and skipped `expire` would
    /// strand its waiter.
    ///
    /// A non-positive timeout expires immediately rather than never, and returns
    /// nothing to cancel.
    private func armDeadline(
        _ seconds: TimeInterval,
        _ expire: @escaping @Sendable () -> Void
    ) -> Scheduled<Void>? {
        guard seconds > 0 else {
            expire()
            return nil
        }
        lock.lock()
        // Any loop will do — every `expire` takes the lock — so a waiter that
        // somehow predates `handlerAdded` is bounded rather than silently
        // deadline-less.
        let loop = deadlineLoop ?? MultiThreadedEventLoopGroup.singleton.any()
        lock.unlock()
        // Clamped so an absurd budget cannot overflow the conversion; the bound
        // is a few centuries, which is indistinguishable from "no deadline".
        let nanoseconds = Int64(min(seconds, 9_000_000_000) * 1_000_000_000)
        return loop.scheduleTask(in: .nanoseconds(nanoseconds)) {
            // A no-op once the waiter resolved normally: every timeOut* helper
            // removes by key under the lock, so it fails only a live waiter.
            expire()
        }
    }

    /// Hand a freshly armed deadline to its waiter, or cancel it outright if the
    /// waiter resolved in the window between parking and arming.
    private func attachDeadline(_ deadline: Scheduled<Void>?, toRequest id: String) {
        guard let deadline else { return }
        lock.lock()
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            pendingRequests[index].deadline = deadline
            lock.unlock()
        } else {
            lock.unlock()
            deadline.cancel()
        }
    }

    private func attachDeadline(_ deadline: Scheduled<Void>?, toDeletion token: UInt64) {
        guard let deadline else { return }
        lock.lock()
        if deviceDeletions[token]?.continuation != nil {
            deviceDeletions[token]?.deadline = deadline
            lock.unlock()
        } else {
            lock.unlock()
            deadline.cancel()
        }
    }

    private func attachGreetingDeadline(_ deadline: Scheduled<Void>?) {
        guard let deadline else { return }
        lock.lock()
        if greetingContinuation != nil {
            greetingDeadline = deadline
            lock.unlock()
        } else {
            lock.unlock()
            deadline.cancel()
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

    private func cancelRequest(id: String) {
        lock.lock()
        var waiter: CheckedContinuation<QMPResponse?, Error>?
        var deadline: Scheduled<Void>?
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            if let continuation = pendingRequests[index].continuation {
                deadline = pendingRequests[index].deadline
                pendingRequests.remove(at: index)
                waiter = continuation
            } else {
                // Not parked yet — leave the record behind, marked, so the
                // caller resumes itself rather than parking on a continuation
                // whose canceller has already run.
                pendingRequests[index].cancelled = true
            }
        }
        lock.unlock()
        deadline?.cancel()
        waiter?.resume(throwing: CancellationError())
    }

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        self.channel = context.channel
        self.deadlineLoop = context.eventLoop
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
            "version": .stringConvertible("\(greetingMessage.QMP.version.qemu.major).\(greetingMessage.QMP.version.qemu.minor).\(greetingMessage.QMP.version.qemu.micro)")
        ])
        lock.lock()
        if case .pending = greeting {
            greeting = .satisfied
        }
        let waiter = greetingContinuation
        greetingContinuation = nil
        let deadline = greetingDeadline
        greetingDeadline = nil
        lock.unlock()
        deadline?.cancel()
        waiter?.resume()
    }

    private func handleResponse(_ response: QMPResponse) {
        lock.lock()
        var waiter: CheckedContinuation<QMPResponse?, Error>?
        var deadline: Scheduled<Void>?
        var unmatchedID: String?
        if let id = response.id?.stringValue {
            // Tagged: match strictly, and drop it if nothing matches. A
            // tagged response with no waiter is a late reply to a request
            // that already timed out — QEMU still answers those. Falling
            // back to FIFO here would hand it to whichever request is
            // pending *now*, which is precisely the response-shift
            // corruption id correlation exists to prevent.
            if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
                let removed = pendingRequests.remove(at: index)
                waiter = removed.continuation
                deadline = removed.deadline
            } else {
                unmatchedID = id
            }
        } else if let index = pendingRequests.firstIndex(where: { $0.continuation != nil }) {
            // Untagged (an older QEMU that does not echo `id`): submission
            // order is the only correlation available. Records without a
            // continuation are skipped — they have not been written yet, so
            // this reply cannot be theirs.
            let removed = pendingRequests.remove(at: index)
            waiter = removed.continuation
            deadline = removed.deadline
        }
        lock.unlock()

        if let unmatchedID {
            logger.debug(
                "Discarding QMP response with no matching request",
                metadata: ["id": .string(unmatchedID)])
        }
        deadline?.cancel()
        waiter?.resume(returning: response)
    }

    private func handleEvent(_ event: QMPEvent) {
        logger.debug("Received QMP event", metadata: ["event": .string(event.event)])

        // Handle DEVICE_DELETED event
        guard event.event == "DEVICE_DELETED",
              let device = event.data?["device"]?.stringValue else {
            return
        }

        lock.lock()
        // The oldest outstanding expectation for this device, so repeated
        // detaches are matched in the order they were issued.
        // Cancelled expectations are skipped: their waiter is going to throw
        // `CancellationError` regardless, and letting one absorb the event would
        // hide it from a live wait for the same device.
        let token = deviceDeletions
            .filter { $0.value.deviceId == device && !$0.value.cancelled }
            .keys
            .min()
        var waiter: CheckedContinuation<Void, Error>?
        var deadline: Scheduled<Void>?
        if let token {
            if let continuation = deviceDeletions[token]?.continuation {
                deadline = deviceDeletions[token]?.deadline
                deviceDeletions.removeValue(forKey: token)
                waiter = continuation
            } else {
                // The command has not been answered yet; record it so the wait
                // that follows returns at once instead of timing out.
                deviceDeletions[token]?.seen = true
            }
        }
        lock.unlock()

        deadline?.cancel()
        waiter?.resume()
    }
}
