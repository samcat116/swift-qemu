import Foundation
import Logging
import NIOCore

/// The typed async channel a QMP connection runs over: newline-delimited frames
/// in, encoded requests out. Framing is `QMPFrameDecoder`'s job, so one inbound
/// element is exactly one message.
typealias QMPAsyncChannel = NIOAsyncChannel<ByteBuffer, ByteBuffer>

/// One live QMP connection: the loop that consumes inbound messages, the waiters
/// outstanding against it, and the write side.
///
/// This replaces a `ChannelInboundHandler` that did the same work from the event
/// loop behind an `NIOLock`, and the difference is where the connection's *end*
/// is decided. There used to be three places that could notice — `channelRead`
/// hitting an oversized frame, `channelInactive`, and `disconnect()` — so the
/// error a caller saw depended on which got there first, and `failAllWaiters` had
/// to latch the first one to keep `frameTooLarge` from being overwritten by the
/// `connectionLost` that followed a moment later. Now the inbound `AsyncSequence`
/// ending *is* the connection ending: whatever stops ``run()`` is the error every
/// waiter gets, and there is no ordering left to arbitrate.
///
/// Being an `actor` is what removes the second lock: the registries below are
/// touched only from isolated methods. The waiters have their own lock because
/// they are resolved from event-loop timers as well.
actor QMPConnection {
    private let logger: Logger
    private let asyncChannel: QMPAsyncChannel
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// The channel itself, for the two things that must work from outside the
    /// actor: reporting liveness, and closing.
    nonisolated let channel: Channel
    /// The loop waiter deadlines are scheduled on.
    nonisolated let eventLoop: EventLoop

    /// Resolved by the greeting QEMU sends the instant it accepts. Created here
    /// rather than when someone waits for it, so the greeting cannot arrive
    /// before there is something to receive it.
    ///
    /// It carries the greeting itself rather than merely signalling that one
    /// arrived, because its `capabilities` list is what negotiation is driven from.
    /// Holding the value *in* the latch is what removes the question of whether a
    /// negotiation woken by the latch can see the greeting it was waiting for.
    private let greeting: QMPWaiter<QMPGreeting>

    /// Fan-out of asynchronous events to `events()` subscribers. Lock-guarded and
    /// `nonisolated` so subscribing stays synchronous — see ``QMPEventBroadcaster``.
    nonisolated let events = QMPEventBroadcaster()

    /// Outstanding requests in submission order. QMP echoes our `id` back, so a
    /// reply is matched to its request rather than to whatever is at the head;
    /// the order only matters to the untagged fallback below.
    private var pendingRequests: [PendingRequest] = []
    /// One entry per outstanding `device_del`, keyed by ticket rather than by
    /// device name, so two concurrent detaches of the same device — or a detach
    /// of a device re-added under an old name — cannot be confused for each other.
    private var deviceDeletions: [UInt64: PendingDeletion] = [:]
    private var nextRequestID: UInt64 = 0
    private var nextTicket: UInt64 = 0

    /// Set once the connection has ended, so waits started afterwards fail
    /// immediately instead of parking on a dead connection.
    private var closeError: QMPError?
    /// Handed over by ``run()`` when it takes scoped ownership of the channel.
    /// Nothing can be sent before then, and nothing needs to be: the first write
    /// is the capability negotiation that follows the greeting, and only the
    /// reader loop can deliver a greeting.
    private var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?

    private struct PendingRequest {
        let id: String
        let waiter: QMPWaiter<QMPResponse>
        /// A request that has not reached the socket yet cannot be the one an
        /// untagged reply belongs to.
        var isSent = false
    }

    private struct PendingDeletion {
        let deviceId: String
        let waiter: QMPWaiter<Void>
    }

    /// A registered interest in the `DEVICE_DELETED` for one `device_del`.
    struct DeletionTicket: Sendable {
        let token: UInt64
    }

    init(logger: Logger, asyncChannel: QMPAsyncChannel, connectTimeout: Duration) {
        self.logger = logger
        self.asyncChannel = asyncChannel
        self.channel = asyncChannel.channel
        self.eventLoop = asyncChannel.channel.eventLoop
        self.greeting = QMPWaiter(timeout: connectTimeout, on: asyncChannel.channel.eventLoop)
    }

    /// Whether the connection is still usable. Read from outside the actor, and
    /// derived from the channel rather than from a flag someone has to remember
    /// to clear: a channel that has gone inactive is not a connection, whether it
    /// was closed by us, by QEMU exiting, or by a framing failure.
    nonisolated var isActive: Bool {
        channel.isActive
    }

    // MARK: - Reader loop

    /// Consume inbound messages until the connection ends, then fail everything
    /// still parked on it.
    ///
    /// Run as one unstructured task per connection, because the public API is a
    /// long-lived object with imperative `connect`/`execute`/`disconnect` calls
    /// and there is no caller scope to hold the channel open. Everything inside
    /// that task *is* structured: `executeThenClose` bounds the channel's
    /// lifetime, and closing the channel is what ends the loop.
    func run() async {
        var failure: Error?
        do {
            try await asyncChannel.executeThenClose { inbound, outbound in
                self.writer = outbound
                for try await frame in inbound {
                    self.deliver(frame)
                }
            }
        } catch {
            failure = error
        }
        finish(with: Self.endOfConnectionError(failure))
    }

    /// Why the connection ended, in the API's own vocabulary.
    ///
    /// The inbound sequence simply finishing means the peer closed. A framing
    /// failure already speaks this vocabulary — ``QMPFrameDecoder`` throws
    /// ``QMPError/frameTooLarge(limit:)``, which NIO delivers by failing the
    /// sequence — and is passed through so the in-flight caller learns the cause
    /// rather than a generic connection loss.
    private static func endOfConnectionError(_ failure: (any Error)?) -> QMPError {
        switch failure {
        case .none: return QMPError.connectionLost
        case .some(let error as QMPError): return error
        case .some: return QMPError.connectionLost
        }
    }

    private func deliver(_ frame: ByteBuffer) {
        let message: QMPMessage
        do {
            message = try decoder.decode(QMPMessage.self, from: Data(frame.readableBytesView))
        } catch {
            logger.warning("Unknown QMP message format", metadata: [
                "error": .string("\(error)")
            ])
            return
        }

        switch message {
        case .greeting(let greetingMessage):
            logger.debug("Received QMP greeting", metadata: [
                "version": .string(Self.describe(greetingMessage)),
                "capabilities": .string(greetingMessage.QMP.capabilities.joined(separator: ","))
            ])
            greeting.resolve(.success(greetingMessage))
        case .response(let response):
            deliverResponse(response)
        case .event(let event):
            deliverEvent(event)
        }
    }

    private static func describe(_ greeting: QMPGreeting) -> String {
        let qemu = greeting.QMP.version.qemu
        return "\(qemu.major).\(qemu.minor).\(qemu.micro)"
    }

    private func deliverResponse(_ response: QMPResponse) {
        if let id = response.id?.stringValue {
            // Tagged: match strictly, and drop it if nothing matches. A tagged
            // response with no waiter is a late reply to a request that already
            // timed out — QEMU still answers those — and falling back to FIFO
            // here would hand it to whichever request is pending *now*, which is
            // precisely the response-shift corruption id correlation prevents.
            guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
                logger.debug(
                    "Discarding QMP response with no matching request",
                    metadata: ["id": .string(id)])
                return
            }
            pendingRequests.remove(at: index).waiter.resolve(.success(response))
        } else if let index = pendingRequests.firstIndex(where: { $0.isSent }) {
            // Untagged (an older QEMU that does not echo `id`): submission order
            // is the only correlation available. Requests that have not reached
            // the socket are skipped — this reply cannot be theirs.
            pendingRequests.remove(at: index).waiter.resolve(.success(response))
        }
    }

    private func deliverEvent(_ event: QMPEvent) {
        logger.debug("Received QMP event", metadata: ["event": .string(event.event)])

        // The dedicated waiter first, then everyone watching. A detach needs a
        // targeted, timed wait, so it keeps its ticket path rather than scanning the
        // shared stream — but the event is still worth publishing, and resolving the
        // ticket must not consume it on the way.
        if event.event == QMPEventName.deviceDeleted,
           let device = event.data?["device"]?.stringValue {
            resolveDeviceDeletion(device: device)
        }

        events.broadcast(event)
    }

    private func resolveDeviceDeletion(device: String) {
        // The oldest live expectation for this device, so repeated detaches are
        // matched in the order they were issued. Already-resolved expectations are
        // skipped: one that has timed out or been cancelled would absorb the event
        // and hide it from a live wait for the same device.
        let token = deviceDeletions
            .filter { $0.value.deviceId == device && !$0.value.waiter.isResolved }
            .keys
            .min()
        guard let token else { return }
        // Left in place rather than removed: the record is the caller's, and the
        // caller removes it when its wait finishes. Resolving the waiter is
        // enough — a wait that has not started yet finds the result latched.
        deviceDeletions[token]?.waiter.resolve()
    }

    /// Fail everything parked on this connection, and latch the reason so waits
    /// started afterwards fail fast rather than parking on a dead channel.
    private func finish(with error: QMPError) {
        guard closeError == nil else { return }
        closeError = error
        // `executeThenClose` has finished the writer on its way out; dropping it
        // keeps the "is there anything to send on" question honest.
        writer = nil

        let requests = pendingRequests
        pendingRequests.removeAll()
        let deletions = Array(deviceDeletions.values)
        deviceDeletions.removeAll()

        greeting.resolve(.failure(error))
        for request in requests {
            request.waiter.resolve(.failure(error))
        }
        for deletion in deletions {
            deletion.waiter.resolve(.failure(error))
        }
        // Event streams end with the connection they belong to. Because only this
        // one place decides a connection has ended, that happens exactly once and at
        // a defined point: `disconnect()` waits for the reader task, so a stream is
        // already finished by the time it returns.
        events.finish()
    }

    // MARK: - Teardown

    /// Close the channel and wait for the reader loop to notice.
    ///
    /// Never reports an already-closed peer as a failure: QEMU exits in response
    /// to `quit` and closes from its end, so this routinely races a close that has
    /// already happened. Letting that escape used to propagate out of
    /// `QEMUManager.destroy()` *before* it terminated the process, leaving exactly
    /// the orphaned QEMU the cleanup path exists to prevent.
    nonisolated func close() async {
        closeWithoutWaiting()
        try? await channel.closeFuture.get()
    }

    /// The half of ``close()`` that a `deinit` can reach.
    nonisolated func closeWithoutWaiting() {
        channel.close(promise: nil)
    }

    // MARK: - Greeting

    /// The greeting QEMU sent, waiting for it if it has not arrived yet.
    func waitForGreeting() async throws(QMPError) -> QMPGreeting {
        try await greeting.value
    }

    // MARK: - Requests

    func sendRequest(_ request: QMPRequest, timeout: Duration) async throws(QMPError) -> QMPResponse {
        if let closeError { throw closeError }
        guard let writer else { throw QMPError.notConnected }

        nextRequestID += 1
        let id = "swiftqemu-\(nextRequestID)"
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
        // Encoded before the waiter is registered, so a failure here cannot leave
        // a registration behind with nothing to resolve it.
        let payload: Data
        do {
            payload = try encoder.encode(identified)
        } catch {
            throw QMPError.requestEncodingFailed(command: request.execute, underlying: error)
        }
        var frame = channel.allocator.buffer(capacity: payload.count + 1)
        frame.writeBytes(payload)
        frame.writeString("\n")

        // Registered *before* the write: QEMU can answer faster than this task is
        // rescheduled, and a reply that finds no waiter is discarded.
        let waiter = QMPWaiter<QMPResponse>(timeout: timeout, on: eventLoop)
        pendingRequests.append(PendingRequest(id: id, waiter: waiter))
        defer { removeRequest(id) }

        do {
            try await writer.write(frame)
        } catch {
            throw Self.writeError(error)
        }
        markSent(id)

        return try await waiter.value
    }

    /// A write that fails has either lost the channel or lost the writer with it
    /// (`executeThenClose` finishes the writer on its way out), and both mean the
    /// same thing to a caller. Cancellation keeps its own case rather than being
    /// reported as a connection that was never lost.
    private static func writeError(_ error: any Error) -> QMPError {
        switch error {
        case is CancellationError: return .cancelled
        case let error as QMPError: return error
        default: return .connectionLost
        }
    }

    private func removeRequest(_ id: String) {
        pendingRequests.removeAll { $0.id == id }
    }

    private func markSent(_ id: String) {
        guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else { return }
        pendingRequests[index].isSent = true
    }

    // MARK: - Device deletion events

    /// Register interest *before* `device_del` is sent.
    ///
    /// QEMU may emit `DEVICE_DELETED` before its reply to the command reaches us,
    /// and a waiter installed only afterwards misses the event and waits out the
    /// full timeout. Registering first makes the ordering irrelevant. Scoping the
    /// record to this one command matters too: a free-floating "this device was
    /// deleted" latch would still be sitting there if the guest ejected a device
    /// nobody was waiting on, and would then falsely satisfy a later detach of a
    /// device re-added under the same name.
    ///
    /// The event budget starts here, for the same reason: it covers the whole
    /// detach, command included.
    func expectDeviceDeleted(deviceId: String, timeout: Duration) -> DeletionTicket {
        nextTicket += 1
        let waiter = QMPWaiter<Void>(timeout: timeout, on: eventLoop)
        if let closeError {
            waiter.resolve(.failure(closeError))
        }
        deviceDeletions[nextTicket] = PendingDeletion(deviceId: deviceId, waiter: waiter)
        return DeletionTicket(token: nextTicket)
    }

    /// Drop a registration whose command never made it out.
    func cancelExpectation(_ ticket: DeletionTicket) {
        deviceDeletions.removeValue(forKey: ticket.token)?.waiter.resolve(.failure(QMPError.connectionLost))
    }

    func waitForDeviceDeleted(_ ticket: DeletionTicket) async throws(QMPError) {
        guard let pending = deviceDeletions[ticket.token] else {
            // Torn down between the command and this wait.
            throw closeError ?? QMPError.connectionLost
        }
        defer { deviceDeletions.removeValue(forKey: ticket.token) }
        try await pending.waiter.value
    }
}
