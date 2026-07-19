import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Logging

/// QMP Client for communicating with QEMU Monitor Protocol
public final class QMPClient: @unchecked Sendable {
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
    private var channel: Channel?
    private var handler: QMPChannelHandler?

    /// Connection state
    private var isConnected = false
    private var capabilities: [String] = []

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
                // A fresh handler per attempt: a handler that saw a failed
                // negotiation has latched its greeting/close state and must not
                // be reused for the next connection.
                let handler = QMPChannelHandler(logger: logger)
                self.handler = handler

                let bootstrap = ClientBootstrap(group: eventLoopGroup)
                    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .channelInitializer { channel in
                        return channel.pipeline.addHandler(handler)
                    }

                self.channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
                self.isConnected = true

                // Wait for greeting and negotiate capabilities
                try await negotiateCapabilities()

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

        let handler = QMPChannelHandler(logger: logger)
        self.handler = handler

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHandler(handler)
            }

        do {
            self.channel = try await bootstrap.connect(host: host, port: port).get()
            self.isConnected = true

            // Wait for greeting and negotiate capabilities
            try await negotiateCapabilities()
        } catch {
            await teardownFailedAttempt()
            throw error
        }

        logger.info("Connected to QEMU successfully")
    }

    /// Disconnect from QEMU
    public func disconnect() async throws {
        guard isConnected else { return }

        logger.info("Disconnecting from QEMU")

        try await channel?.close()
        self.isConnected = false
        self.channel = nil
        self.handler = nil

        logger.info("Disconnected from QEMU")
    }

    /// Drop a half-open connection, failing anything still parked on it. Called
    /// when connect or negotiation fails so the next retry starts clean and no
    /// waiter is left holding a continuation on the abandoned channel.
    private func teardownFailedAttempt() async {
        handler?.failAllWaiters(with: QMPError.connectionLost)
        try? await channel?.close()
        self.isConnected = false
        self.channel = nil
        self.handler = nil
    }

    // MARK: - QMP Commands

    /// Execute a QMP command
    public func execute(_ command: QMPCommand, arguments: [String: Any]? = nil) async throws -> Any? {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let request = QMPRequest(
            execute: command.name,
            arguments: arguments?.mapValues { AnyCodable($0) }
        )

        guard let response = try await sendRequest(request) else {
            throw QMPError.invalidResponse
        }

        if let error = response.error {
            throw QMPError.qmpError(error.class, error.desc)
        }

        return response.return?.value
    }

    /// Query VM status
    public func queryStatus() async throws -> QMPStatusResponse {
        let result = try await execute(.queryStatus)

        guard let dict = result as? [String: Any],
              let status = dict["status"] as? String,
              let running = dict["running"] as? Bool,
              let singlestep = dict["singlestep"] as? Bool else {
            throw QMPError.invalidResponse
        }

        return QMPStatusResponse(
            status: status,
            singlestep: singlestep,
            running: running
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
        let arguments: [String: Any] = [
            "driver": "qcow2",
            "node-name": nodeName,
            "file": [
                "driver": "file",
                "filename": filename
            ],
            "read-only": readOnly
        ]
        _ = try await execute(.blockdevAdd, arguments: arguments)
    }

    /// Remove a block device backend
    /// - Parameter nodeName: The node name used when adding the device
    public func blockdevDel(nodeName: String) async throws {
        _ = try await execute(.blockdevDel, arguments: ["node-name": nodeName])
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
        var arguments: [String: Any] = [
            "driver": driver,
            "id": deviceId,
            "drive": driveId
        ]
        if let bus = bus {
            arguments["bus"] = bus
        }
        _ = try await execute(.deviceAdd, arguments: arguments)
    }

    /// Remove a device and wait for DEVICE_DELETED event
    /// - Parameters:
    ///   - deviceId: The device ID to remove
    ///   - timeout: Timeout in seconds for waiting on DEVICE_DELETED event
    public func deviceDel(deviceId: String, timeout: TimeInterval = 5) async throws {
        _ = try await execute(.deviceDel, arguments: ["id": deviceId])
        guard let handler = handler else {
            throw QMPError.notConnected
        }
        try await handler.waitForDeviceDeleted(deviceId: deviceId, timeout: timeout)
    }

    /// Query attached block devices
    public func queryBlock() async throws -> [AnyCodable] {
        guard let result = try await execute(.queryBlock) as? [Any] else {
            return []
        }
        return result.map { AnyCodable($0) }
    }

    // MARK: - Private Methods

    private func negotiateCapabilities() async throws {
        guard let handler = handler else {
            throw QMPError.notConnected
        }

        // Wait for greeting
        try await handler.waitForGreeting(timeout: connectTimeout)

        // Send capabilities command
        let request = QMPRequest(execute: "qmp_capabilities")
        _ = try await handler.sendRequest(request, timeout: connectTimeout)

        logger.debug("QMP capabilities negotiated")
    }

    private func sendRequest(_ request: QMPRequest) async throws -> QMPResponse? {
        guard let handler = handler else {
            throw QMPError.notConnected
        }

        return try await handler.sendRequest(request, timeout: requestTimeout)
    }
}

// MARK: - Timeout helper

/// Outcome of racing an operation against a deadline. A dedicated case (rather
/// than an optional) keeps "the operation returned nil" distinguishable from
/// "the deadline won".
private enum QMPTimeoutRace<T: Sendable>: Sendable {
    case value(T)
    case timedOut
}

/// Run `operation` under a deadline.
///
/// On expiry `unpark` is invoked *before* the group drains. That ordering is
/// load-bearing: `operation` is parked on a `CheckedContinuation`, and a task
/// group awaits all of its children before returning. Cancelling a parked
/// continuation does not resume it, so without `unpark` handing it an error the
/// group would wait on it forever — a "timeout" that hangs, which is precisely
/// the bug this replaces.
private func withQMPTimeout<T: Sendable>(
    seconds: TimeInterval,
    unpark: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: QMPTimeoutRace<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                // Cancelled because the operation already won; leave its
                // continuation alone.
                return .timedOut
            }
            unpark()
            return .timedOut
        }

        while let outcome = try await group.next() {
            if case .value(let value) = outcome {
                group.cancelAll()
                return value
            }
            // The deadline won. `unpark` has since failed the operation's
            // continuation, so the next `next()` rethrows that error.
        }
        throw QMPError.timeout
    }
}

// MARK: - QMP Channel Handler

private final class QMPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let logger: Logger
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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
    /// Outstanding requests in submission order, keyed for out-of-order and
    /// timed-out removal. QMP echoes our `id` back, so a response is matched to
    /// its request rather than to whatever happens to be at the head.
    private var pendingRequests: [(id: String, continuation: CheckedContinuation<QMPResponse?, Error>)] = []
    private var deviceDeletedContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    /// Set once the channel goes inactive, so waiters that arrive afterwards
    /// fail immediately instead of parking on a dead connection.
    private var closeError: Error?
    private var nextRequestID: UInt64 = 0
    private weak var channel: Channel?

    /// Event-loop-confined: only touched from `channelRead`.
    private var buffer = ByteBuffer()

    init(logger: Logger) {
        self.logger = logger
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
        let deviceWaiters = Array(deviceDeletedContinuations.values)
        deviceDeletedContinuations.removeAll()
        let greetingWaiter = greetingContinuation
        greetingContinuation = nil
        if case .pending = greeting {
            greeting = .failed(error)
        }
        if closeError == nil {
            closeError = error
        }
        lock.unlock()

        for request in requests {
            request.continuation.resume(throwing: error)
        }
        for waiter in deviceWaiters {
            waiter.resume(throwing: error)
        }
        greetingWaiter?.resume(throwing: error)
    }

    func waitForGreeting(timeout: TimeInterval) async throws {
        try await withQMPTimeout(seconds: timeout, unpark: { [weak self] in
            self?.timeOutGreeting()
        }) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                switch greeting {
                case .satisfied:
                    // The greeting landed before we got here. Latching it is
                    // what keeps this from parking forever.
                    lock.unlock()
                    continuation.resume()
                case .failed(let error):
                    lock.unlock()
                    continuation.resume(throwing: error)
                case .pending:
                    greetingContinuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    private func timeOutGreeting() {
        lock.lock()
        let waiter = greetingContinuation
        greetingContinuation = nil
        lock.unlock()
        waiter?.resume(throwing: QMPError.timeout)
    }

    func waitForDeviceDeleted(deviceId: String, timeout: TimeInterval) async throws {
        try await withQMPTimeout(seconds: timeout, unpark: { [weak self] in
            self?.timeOutDeviceDeleted(deviceId: deviceId)
        }) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let closeError {
                    lock.unlock()
                    continuation.resume(throwing: closeError)
                    return
                }
                deviceDeletedContinuations[deviceId] = continuation
                lock.unlock()
            }
        }
    }

    private func timeOutDeviceDeleted(deviceId: String) {
        lock.lock()
        let waiter = deviceDeletedContinuations.removeValue(forKey: deviceId)
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
        let id = "strato-\(nextRequestID)"
        lock.unlock()

        // Tag the request so its response can be correlated back to it. Without
        // an id, matching is positional — and a single timed-out request would
        // shift every later response onto the wrong caller.
        let identified = QMPRequest(
            execute: request.execute,
            arguments: request.arguments,
            id: AnyCodable(id)
        )
        let data = try encoder.encode(identified)
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeString("\n")
        let outbound = buffer

        return try await withQMPTimeout(seconds: timeout, unpark: { [weak self] in
            self?.timeOutRequest(id: id)
        }) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QMPResponse?, Error>) in
                lock.lock()
                if let closeError {
                    lock.unlock()
                    continuation.resume(throwing: closeError)
                    return
                }
                pendingRequests.append((id: id, continuation: continuation))
                lock.unlock()
                channel.writeAndFlush(outbound, promise: nil)
            }
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
        guard let bytes = buffer.readBytes(length: messageLength) else {
            return nil
        }

        return Data(bytes.dropLast()) // Remove newline
    }

    private func processMessage(_ data: Data) {
        // Try to decode as greeting first
        if let greetingMessage = try? decoder.decode(QMPGreeting.self, from: data) {
            logger.debug("Received QMP greeting", metadata: [
                "version": .stringConvertible("\(greetingMessage.QMP.version.qemu.major).\(greetingMessage.QMP.version.qemu.minor).\(greetingMessage.QMP.version.qemu.micro)")
            ])
            lock.lock()
            if case .pending = greeting {
                greeting = .satisfied
            }
            let waiter = greetingContinuation
            greetingContinuation = nil
            lock.unlock()
            waiter?.resume()
            return
        }

        // Try to decode as response
        if let response = try? decoder.decode(QMPResponse.self, from: data) {
            lock.lock()
            var waiter: CheckedContinuation<QMPResponse?, Error>?
            var unmatchedID: String?
            if let id = response.id?.value as? String {
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
            return
        }

        // Try to decode as event
        if let event = try? decoder.decode(QMPEvent.self, from: data) {
            logger.debug("Received QMP event", metadata: ["event": .string(event.event)])

            // Handle DEVICE_DELETED event
            if event.event == "DEVICE_DELETED",
               let eventData = event.data?.value as? [String: Any],
               let device = eventData["device"] as? String {
                lock.lock()
                let waiter = deviceDeletedContinuations.removeValue(forKey: device)
                lock.unlock()
                waiter?.resume()
            }
            return
        }

        logger.warning("Unknown QMP message format")
    }
}
