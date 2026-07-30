import XCTest
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Logging
@testable import SwiftQEMU

/// End-to-end tests for `QMPClient` against a scripted in-process QMP server.
///
/// These cover the failure modes that used to hang the caller forever rather
/// than surfacing an error: a greeting that lands before anyone waits for it,
/// and a peer that accepts the connection but never speaks.
final class QMPClientTests: XCTestCase {

    // MARK: - Fake QMP server

    /// What the fake server does once a client connects.
    enum ServerBehaviour: Sendable {
        /// Send the greeting immediately on connect, then answer every request
        /// with an empty success. This is the well-behaved QEMU case — and,
        /// because the greeting is written before the client can install its
        /// waiter, it is also the race that used to strand the greeting.
        case greetImmediately
        /// Accept the connection and then say nothing at all, forever. Models a
        /// wedged QEMU or a socket file that outlived its process.
        case silent
        /// Greet and negotiate normally, but never emit DEVICE_DELETED.
        case greetButSwallowDeviceDeleted
        /// Greet and negotiate normally, then never answer another command.
        /// Models a QEMU that has stopped servicing the monitor, which is the
        /// only way to hold a command parked long enough to cancel it.
        case greetThenSwallowCommands
        /// Greet and negotiate normally, then answer subsequent commands with
        /// an id belonging to no outstanding request. Models QEMU finally
        /// replying to a request that already timed out.
        case greetThenReplyWithStaleID
        /// Behave the way a real QEMU 11 does, which is the case the naive
        /// message decoding got wrong: interleave asynchronous events with
        /// replies (`RESUME` arrives *before* the reply to `cont`), answer
        /// `query-status` without the long-removed `singlestep`, emit
        /// `DEVICE_DELETED` after a `device_del`, and close the connection after
        /// answering `quit` the way an exiting process does.
        case greetAndBehaveLikeQEMU
        /// As above, but `DEVICE_DELETED` arrives *before* the reply to
        /// `device_del` — the ordering that loses the event if the waiter is only
        /// installed once the command has been answered.
        case greetAndDeleteBeforeReplying
        /// Negotiate normally, then answer the next command with a well-formed
        /// JSON *prefix* that is never terminated by a newline. Models a wedged
        /// or half-written frame: without a cap the client buffers all of it and
        /// keeps going.
        case greetThenFloodWithoutNewline
        /// Negotiate normally, then send one complete but over-limit frame.
        case greetThenSendOversizedFrame
        /// Negotiate normally, then reply with a payload that is large but still
        /// inside the cap — the case the cap must not break.
        case greetThenReplyWithLargePayload
        /// Greet and negotiate normally, then answer `system_reset` with a burst of
        /// `floodedEventCount` numbered events before its reply. Models an event
        /// source faster than its consumer, which a bounded buffer has to survive
        /// without stalling the connection.
        case greetAndFloodEvents
    }

    /// Padding sizes for the frame-limit tests. The flood is far past any cap a
    /// test sets; the oversized frame is small enough to arrive in a single read,
    /// so the complete-frame branch of the check is the one exercised.
    private static let floodPadding = 64 * 1024
    private static let oversizedFramePadding = 400
    private static let largeLegalPadding = 60_000

    /// How many events `.greetAndFloodEvents` emits per `system_reset`.
    static let floodedEventCount = 200

    private static let deviceDeletedEvent = #"{"timestamp": {"seconds": 1745000000, "microseconds": 1}, "event": "DEVICE_DELETED", "data": {"device": "vdb", "path": "/machine/peripheral/vdb"}}"#
    private static let resumeEvent = #"{"timestamp": {"seconds": 1745000000, "microseconds": 2}, "event": "RESUME"}"#

    private static func greeting(capabilities: [String]) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"QMP": {"version": {"qemu": {"major": 8, "minor": 0, "micro": 0}, "package": ""}, "capabilities": [\#(list)]}}"#
    }

    final class FakeQMPServer: Sendable {
        private let channel: Channel
        let socketPath: String
        /// Every request line the server received. Asserting on the wire form is the
        /// only way to tell a correctly encoded request from one that happens to
        /// produce the same result against a lenient fake.
        private let received: NIOLockedValueBox<[String]>

        var receivedRequests: [String] {
            received.withLockedValue { $0 }
        }

        /// - Parameter capabilities: what the greeting advertises. QEMU 11 offers
        ///   `["oob"]`; the empty default keeps the older tests unchanged.
        init(behaviour: ServerBehaviour, capabilities: [String] = []) async throws {
            self.socketPath = NSTemporaryDirectory() + "qmp-test-\(UUID().uuidString).sock"
            let received = NIOLockedValueBox<[String]>([])
            self.received = received

            let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        ServerHandler(
                            behaviour: behaviour,
                            capabilities: capabilities,
                            received: received
                        )
                    )
                }
            self.channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        }

        func shutdown() async {
            try? await channel.close()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        private final class ServerHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private let behaviour: ServerBehaviour
            private let capabilities: [String]
            private let received: NIOLockedValueBox<[String]>
            private var buffer = ByteBuffer()
            private var negotiated = false

            init(
                behaviour: ServerBehaviour,
                capabilities: [String],
                received: NIOLockedValueBox<[String]>
            ) {
                self.behaviour = behaviour
                self.capabilities = capabilities
                self.received = received
            }

            func channelActive(context: ChannelHandlerContext) {
                guard behaviour != .silent else { return }
                write(QMPClientTests.greeting(capabilities: capabilities), context: context)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard behaviour != .silent else { return }

                var input = self.unwrapInboundIn(data)
                buffer.writeBuffer(&input)

                // Echo back a success response per newline-delimited request,
                // preserving the request's `id` the way QEMU does.
                while let line = readLine(&buffer) {
                    received.withLockedValue { $0.append(line) }

                    if behaviour == .greetAndBehaveLikeQEMU
                        || behaviour == .greetAndDeleteBeforeReplying
                        || behaviour == .greetAndFloodEvents {
                        replyLikeQEMU(to: line, context: context)
                        continue
                    }

                    if behaviour == .greetThenFloodWithoutNewline
                        || behaviour == .greetThenSendOversizedFrame
                        || behaviour == .greetThenReplyWithLargePayload {
                        replyWithSizedFrame(to: line, context: context)
                        continue
                    }

                    if behaviour == .greetThenSwallowCommands {
                        // Negotiation still has to succeed; everything after it
                        // goes unanswered.
                        guard !negotiated else { continue }
                        if line.contains("qmp_capabilities") {
                            negotiated = true
                        }
                    }

                    var id = Self.extractID(from: line)
                    if behaviour == .greetThenReplyWithStaleID {
                        // Negotiation must still succeed, so only corrupt the
                        // id on commands issued after qmp_capabilities.
                        if line.contains("qmp_capabilities") {
                            negotiated = true
                        } else if negotiated {
                            id = "stale-id-for-a-request-that-timed-out"
                        }
                    }
                    let idField = id.map { ", \"id\": \"\($0)\"" } ?? ""
                    write("{\"return\": {}\(idField)}", context: context)
                }
            }

            /// Answer one command with the payloads and event ordering QEMU 11
            /// actually uses.
            private func replyLikeQEMU(to line: String, context: ChannelHandlerContext) {
                let idField = Self.extractID(from: line).map { ", \"id\": \"\($0)\"" } ?? ""
                let reply = { (payload: String) in
                    self.write("{\"return\": \(payload)\(idField)}", context: context)
                }

                if line.contains("query-status") {
                    // No `singlestep`: removed from QEMU's StatusInfo.
                    reply("{\"status\": \"running\", \"running\": true}")
                } else if line.contains("system_reset"), behaviour == .greetAndFloodEvents {
                    // Numbered so a test can tell *which* events a bounded buffer
                    // kept when it could not keep them all.
                    for sequence in 0..<QMPClientTests.floodedEventCount {
                        write(#"{"event": "RESET", "data": {"seq": \#(sequence)}}"#, context: context)
                    }
                    reply("{}")
                } else if line.contains("\"cont\"") {
                    // The event genuinely precedes the reply.
                    write(QMPClientTests.resumeEvent, context: context)
                    reply("{}")
                } else if line.contains("device_del") {
                    if behaviour == .greetAndDeleteBeforeReplying {
                        write(QMPClientTests.deviceDeletedEvent, context: context)
                        reply("{}")
                    } else {
                        reply("{}")
                        write(QMPClientTests.deviceDeletedEvent, context: context)
                    }
                } else if line.contains("\"quit\"") {
                    reply("{}")
                    // An exiting QEMU closes the socket from its end.
                    context.close(promise: nil)
                } else {
                    reply("{}")
                }
            }

            /// Negotiate normally, then answer whatever comes next with a frame
            /// sized to probe the client's inbound cap.
            private func replyWithSizedFrame(to line: String, context: ChannelHandlerContext) {
                let idField = Self.extractID(from: line).map { ", \"id\": \"\($0)\"" } ?? ""

                // Negotiation must succeed, so only the command that follows it
                // gets the outsized reply.
                guard !line.contains("qmp_capabilities") else {
                    write("{\"return\": {}\(idField)}", context: context)
                    return
                }

                switch behaviour {
                case .greetThenFloodWithoutNewline:
                    let pad = String(repeating: "A", count: QMPClientTests.floodPadding)
                    write("{\"return\": {\"pad\": \"\(pad)", context: context, terminated: false)
                case .greetThenSendOversizedFrame:
                    let pad = String(repeating: "A", count: QMPClientTests.oversizedFramePadding)
                    write("{\"return\": {\"pad\": \"\(pad)\"}\(idField)}", context: context)
                case .greetThenReplyWithLargePayload:
                    let pad = String(repeating: "A", count: QMPClientTests.largeLegalPadding)
                    write("{\"return\": {\"pad\": \"\(pad)\"}\(idField)}", context: context)
                default:
                    write("{\"return\": {}\(idField)}", context: context)
                }
            }

            private func readLine(_ buffer: inout ByteBuffer) -> String? {
                guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                    return nil
                }
                let length = buffer.readableBytesView.startIndex.distance(to: newlineIndex) + 1
                guard let bytes = buffer.readBytes(length: length) else { return nil }
                return String(decoding: bytes.dropLast(), as: UTF8.self)
            }

            private static func extractID(from line: String) -> String? {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return object["id"] as? String
            }

            private func write(
                _ string: String,
                context: ChannelHandlerContext,
                terminated: Bool = true
            ) {
                var out = context.channel.allocator.buffer(capacity: string.utf8.count + 1)
                out.writeString(string)
                if terminated {
                    out.writeString("\n")
                }
                context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
            }
        }
    }

    // MARK: - Tests

    /// The greeting is written the instant the connection is accepted, so it
    /// routinely arrives before `waitForGreeting` installs its continuation.
    /// Before the greeting was latched, that ordering dropped the resume on the
    /// floor and the connect parked forever. Repeated to make the race likely.
    func testConnectSucceedsWhenGreetingArrivesBeforeTheWaiterIsInstalled() async throws {
        for _ in 0..<25 {
            let server = try await FakeQMPServer(behaviour: .greetImmediately)
            defer { Task { await server.shutdown() } }

            let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
            try await client.connectUnix(path: server.socketPath)
            try await client.disconnect()
        }
    }

    /// A peer that accepts and then never speaks must surface an error within
    /// the budget. Previously `waitForGreeting` had no deadline at all, so this
    /// call never returned — the agent-level hang reported in strato#516.
    func testConnectToSilentPeerTimesOutInsteadOfHanging() async throws {
        let server = try await FakeQMPServer(behaviour: .silent)
        defer { Task { await server.shutdown() } }

        // connectUnix retries, so keep the per-attempt budget small to bound
        // the test; what matters is that it terminates at all.
        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 0.2, connectTimeout: 0.2)

        do {
            try await client.connectUnix(path: server.socketPath)
            XCTFail("Expected connect to a silent peer to fail")
        } catch {
            // Any surfaced error is acceptable; hanging is not.
        }
    }

    /// A request whose response never comes must time out rather than park.
    func testRequestToSilentPeerTimesOut() async throws {
        let server = try await FakeQMPServer(behaviour: .greetButSwallowDeviceDeleted)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)
        defer { Task { try? await client.disconnect() } }

        // The fake server answers commands but never emits DEVICE_DELETED, so
        // the post-command event wait is what must time out. The old
        // implementation left its continuation parked, which meant the
        // surrounding task group could never drain — the timeout itself hung.
        do {
            try await client.deviceDel(deviceId: "vdb", timeout: 0.3)
            XCTFail("Expected deviceDel to time out waiting for DEVICE_DELETED")
        } catch let error as QMPError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    /// A response whose id matches no outstanding request must be discarded,
    /// not handed to whichever request happens to be pending. QEMU still
    /// answers requests that already timed out, and resuming a *different*
    /// caller with that stale payload is the response-shift corruption that id
    /// correlation exists to prevent.
    func testResponseWithUnmatchedIDIsDiscardedRatherThanShifted() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenReplyWithStaleID)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 0.4, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        // The server answers, but under an id nobody is waiting on. The correct
        // outcome is that this command times out — never that it silently
        // adopts a reply meant for someone else.
        do {
            _ = try await client.execute(.cont)
            XCTFail("Expected the command to time out rather than accept a mismatched response")
        } catch let error as QMPError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }

        try await client.disconnect()
    }

    /// A zero timeout must fail immediately, not never.
    ///
    /// When the deadline raced the parking task, a deadline that reached its
    /// callback first found no waiter to fail; the operation then parked on a
    /// continuation nobody would resume and the wait hung — a timeout that
    /// hangs. A zero (or near-zero) budget makes that ordering the likely one.
    func testZeroTimeoutFailsImmediatelyRatherThanHanging() async throws {
        let server = try await FakeQMPServer(behaviour: .greetButSwallowDeviceDeleted)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        do {
            try await client.deviceDel(deviceId: "vdb", timeout: 0)
            XCTFail("Expected a zero timeout to fail")
        } catch let error as QMPError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }

        try await client.disconnect()
    }

    /// The same ordering hazard at small-but-nonzero budgets, repeated so a
    /// deadline that fires before the waiter parks is likely to be hit.
    func testTinyTimeoutsNeverStrandTheWaiter() async throws {
        let server = try await FakeQMPServer(behaviour: .greetButSwallowDeviceDeleted)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        for _ in 0..<25 {
            do {
                try await client.deviceDel(deviceId: "vdb", timeout: 0.001)
                XCTFail("Expected the wait to time out")
            } catch let error as QMPError {
                guard case .timeout = error else {
                    return XCTFail("Expected .timeout, got \(error)")
                }
            }
        }

        try await client.disconnect()
    }

    // MARK: - Cancellation

    /// A cancelled command must come back at once, not when its deadline fires.
    ///
    /// The waits used to be cancellation-blind: the only thing that could resume
    /// them was the deadline, so a cancelled caller stayed parked for the whole
    /// budget — up to the 10s default — with nothing left to wait for.
    func testCancellingACommandReturnsWellBeforeItsTimeout() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenSwallowCommands)
        defer { Task { await server.shutdown() } }

        // A budget far longer than this test is willing to wait for: if
        // cancellation is not honoured, the only other way out is the timeout,
        // and the elapsed-time assertion fails long before it arrives.
        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 60, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let started = ContinuousClock.now
        let command = Task { try await client.execute(.cont) }
        // Give the command time to park, so this covers cancelling an installed
        // waiter; the pre-park ordering is covered below.
        try await Task.sleep(for: .milliseconds(100))
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("Expected the cancelled command to throw")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(
            started.duration(to: .now), .seconds(5),
            "A cancelled command must not wait out its request timeout")

        try await client.disconnect()
    }

    /// The same for the `DEVICE_DELETED` wait, which parks after the command
    /// itself has been answered.
    func testCancellingADeviceDetachReturnsWellBeforeItsTimeout() async throws {
        let server = try await FakeQMPServer(behaviour: .greetButSwallowDeviceDeleted)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let started = ContinuousClock.now
        let detach = Task { try await client.deviceDel(deviceId: "vdb", timeout: 60) }
        try await Task.sleep(for: .milliseconds(100))
        detach.cancel()

        do {
            try await detach.value
            XCTFail("Expected the cancelled detach to throw")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(
            started.duration(to: .now), .seconds(5),
            "A cancelled detach must not wait out its event timeout")

        try await client.disconnect()
    }

    /// Cancellation that lands *before* the waiter parks is the mirror image of
    /// the deadline ordering hazard: the canceller finds nothing to cancel, and
    /// the operation then parks behind it. Repeated so that ordering is actually
    /// hit — an immediate `cancel()` usually beats the task to its first
    /// suspension.
    func testCancellationBeforeTheWaiterParksIsNotLost() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenSwallowCommands)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 60, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let started = ContinuousClock.now
        for _ in 0..<25 {
            let command = Task { try await client.execute(.cont) }
            command.cancel()
            do {
                _ = try await command.value
                XCTFail("Expected the cancelled command to throw")
            } catch is CancellationError {
                // Expected.
            }
        }

        XCTAssertLessThan(
            started.duration(to: .now), .seconds(5),
            "Cancellation must be honoured however it races the waiter")

        try await client.disconnect()
    }

    /// A normal command round-trip still works, and the response is correlated
    /// back by id.
    func testCommandRoundTrip() async throws {
        let server = try await FakeQMPServer(behaviour: .greetImmediately)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)
        _ = try await client.execute(.cont)
        try await client.disconnect()
    }

    // MARK: - Events vs. replies

    /// `DEVICE_DELETED` must reach the waiter that asked for it.
    ///
    /// Every property of `QMPResponse` is optional, so decoding response-first
    /// accepted this event as an all-`nil` response and consumed it. The event
    /// branch was unreachable, the waiter was never resumed, and detaching a disk
    /// therefore always failed with a timeout — against a server doing everything
    /// right.
    func testDeviceDeletedEventReachesItsWaiter() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        try await client.deviceDel(deviceId: "vdb", timeout: 3)

        try await client.disconnect()
    }

    /// The same, with the event arriving before the reply to `device_del`. The
    /// waiter is installed only after the command is answered, so this ordering
    /// is only survivable because an unclaimed deletion is latched.
    func testDeviceDeletedArrivingBeforeTheReplyIsNotLost() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndDeleteBeforeReplying)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        try await client.deviceDel(deviceId: "vdb", timeout: 3)

        try await client.disconnect()
    }

    /// An event that arrives while a command is in flight must not be handed
    /// over as that command's reply.
    ///
    /// QEMU emits `RESUME` before it answers `cont`, and the untagged-response
    /// fallback used to hand that event straight to the waiting request — the
    /// caller got an empty payload while the real reply was discarded as
    /// unmatched.
    func testEventDoesNotStealACommandReply() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let result = try await client.execute(.cont)
        XCTAssertNotNil(
            result?.objectValue,
            "cont must return QEMU's `{}` reply, not the RESUME event that preceded it"
        )

        // And the connection is still correlated correctly afterwards.
        let status = try await client.queryStatus()
        XCTAssertEqual(status.status, "running")

        try await client.disconnect()
    }

    // MARK: - Inbound frame limit

    /// A peer that writes without ever sending a newline must fail the
    /// connection, not grow the inbound buffer for as long as it keeps writing.
    ///
    /// The request budget here is deliberately long: a client that only notices
    /// via the request deadline has buffered every byte in the meantime, which is
    /// the unbounded growth this guards against.
    func testUnterminatedFrameFailsTheConnectionInsteadOfBufferingForever() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenFloodWithoutNewline)
        defer { Task { await server.shutdown() } }

        let limit = 8 * 1024
        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: 30,
            connectTimeout: 5,
            maximumFrameSize: limit
        )
        try await client.connectUnix(path: server.socketPath)

        do {
            _ = try await client.execute(.cont)
            XCTFail("Expected an unterminated frame to fail the connection")
        } catch let error as QMPError {
            guard case .frameTooLarge(let reported) = error else {
                return XCTFail("Expected .frameTooLarge, got \(error)")
            }
            XCTAssertEqual(reported, limit)
        }

        XCTAssertFalse(client.isConnected, "An overflowing peer is not a usable connection")
        try await client.disconnect()
    }

    /// The same verdict for a frame that is complete but over the limit — the cap
    /// is on frame size, not merely on how long a peer withholds its newline.
    func testCompleteButOversizedFrameFailsTheConnection() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenSendOversizedFrame)
        defer { Task { await server.shutdown() } }

        let limit = 300
        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: 30,
            connectTimeout: 5,
            maximumFrameSize: limit
        )
        try await client.connectUnix(path: server.socketPath)

        do {
            _ = try await client.execute(.cont)
            XCTFail("Expected an oversized frame to fail the connection")
        } catch let error as QMPError {
            guard case .frameTooLarge(let reported) = error else {
                return XCTFail("Expected .frameTooLarge, got \(error)")
            }
            XCTAssertEqual(reported, limit)
        }

        try await client.disconnect()
    }

    /// A large reply that still fits the cap must be delivered intact. QMP
    /// payloads like `query-block` on a long device list run to tens of KB, so a
    /// cap that clipped them would be worse than no cap at all. Arriving across
    /// several socket reads is also the case the incomplete-frame path has to get
    /// right.
    func testLargeFrameWithinTheLimitIsStillDelivered() async throws {
        let server = try await FakeQMPServer(behaviour: .greetThenReplyWithLargePayload)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: 10,
            connectTimeout: 5,
            maximumFrameSize: 64 * 1024
        )
        try await client.connectUnix(path: server.socketPath)

        let result = try await client.execute(.cont)
        XCTAssertEqual(result?["pad"]?.stringValue?.count, Self.largeLegalPadding)
        XCTAssertTrue(client.isConnected)

        try await client.disconnect()
    }

    /// The default cap is far above any real QMP message, so the well-behaved
    /// path is unaffected by it.
    func testDefaultFrameLimitLeavesNormalTrafficAlone() async throws {
        XCTAssertGreaterThanOrEqual(QMPClient.defaultMaximumFrameSize, 256 * 1024)

        let server = try await FakeQMPServer(behaviour: .greetThenReplyWithLargePayload)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 10, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let result = try await client.execute(.cont)
        XCTAssertEqual(result?["pad"]?.stringValue?.count, Self.largeLegalPadding)

        try await client.disconnect()
    }

    // MARK: - Status parsing

    /// `query-status` on a modern QEMU carries no `singlestep`; requiring it made
    /// every status query fail, which surfaced as a permanently `.unknown` VM.
    func testQueryStatusAcceptsModernQEMUShape() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let status = try await client.queryStatus()
        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(status.running)
        XCTAssertNil(status.singlestep, "The field is absent, not false")

        try await client.disconnect()
    }

    // MARK: - Event stream

    /// Take up to `count` events, giving up after `timeout`.
    ///
    /// A bare `for await` would hang the whole suite if delivery regressed, which
    /// turns a failing assertion into a stuck test run.
    private static func collect(
        _ count: Int,
        from stream: AsyncStream<QMPEvent>,
        timeout: TimeInterval = 5
    ) async -> [QMPEvent] {
        await withTaskGroup(of: [QMPEvent]?.self) { group in
            group.addTask {
                var collected: [QMPEvent] = []
                for await event in stream {
                    collected.append(event)
                    if collected.count == count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// Drain a stream until it *finishes*, returning `nil` if it has not within
    /// `timeout`.
    ///
    /// The distinction matters: a stream that never ends and a stream that ends
    /// having produced nothing both look like "no events", and only the second one
    /// is correct. Anything asserting on completion has to be able to tell them
    /// apart.
    private static func drainUntilFinished(
        _ stream: AsyncStream<QMPEvent>,
        timeout: TimeInterval = 3
    ) async -> [QMPEvent]? {
        await withTaskGroup(of: [QMPEvent]?.self) { group in
            group.addTask {
                var collected: [QMPEvent] = []
                for await event in stream {
                    collected.append(event)
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The events QEMU announces have to reach a subscriber. Before there was a
    /// stream, everything except `DEVICE_DELETED` was logged at debug level and
    /// dropped, leaving callers to poll `query-status` for things QEMU had already
    /// reported.
    func testEventsReachASubscriber() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let events = try client.events()
        _ = try await client.execute(.cont)

        let received = await Self.collect(1, from: events)
        XCTAssertEqual(received.map(\.event), ["RESUME"])

        try await client.disconnect()
    }

    /// Several consumers can watch one connection: the manager keeps its own status
    /// bookkeeping while an application watches the same events.
    func testEverySubscriberSeesEveryEvent() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let first = try client.events()
        let second = try client.events()
        _ = try await client.execute(.cont)

        async let pendingFirst = Self.collect(1, from: first)
        async let pendingSecond = Self.collect(1, from: second)
        let firstReceived = await pendingFirst
        let secondReceived = await pendingSecond

        XCTAssertEqual(firstReceived.map(\.event), ["RESUME"])
        XCTAssertEqual(secondReceived.map(\.event), ["RESUME"])

        try await client.disconnect()
    }

    /// `disconnect()` must finish the stream, or a `for await` over it parks forever
    /// on a connection that no longer exists.
    func testEventStreamFinishesOnDisconnect() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let events = try client.events()
        try await client.disconnect()

        let received = await Self.drainUntilFinished(events)
        XCTAssertNotNil(received, "The stream must be over, not merely silent")
        XCTAssertEqual(received?.count, 0)
    }

    /// The same for a peer that goes away on its own — QEMU exiting in response to
    /// `quit` is the ordinary case, not an exceptional one.
    func testEventStreamFinishesWhenThePeerGoesAway() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let events = try client.events()
        _ = try await client.execute(.quit)

        // The fake server closes the socket after answering `quit`.
        let received = await Self.drainUntilFinished(events)
        XCTAssertNotNil(received, "The stream must finish when the peer closes the connection")

        try await client.disconnect()
    }

    func testSubscribingWithoutAConnectionThrows() throws {
        let client = QMPClient(logger: Logger(label: "test"))
        XCTAssertThrowsError(try client.events()) { error in
            guard case QMPError.notConnected = error else {
                return XCTFail("Expected .notConnected, got \(error)")
            }
        }
    }

    /// A subscriber that stops reading must not stall the event loop, so the buffer
    /// is bounded and drops the *oldest* events. The connection has to stay fully
    /// usable while that happens — a blocking yield here would wedge QEMU's socket
    /// for every other waiter too.
    func testSlowSubscriberDropsOldestEventsWithoutStallingTheConnection() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndFloodEvents)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let bufferSize = 4
        let events = try client.events(bufferSize: bufferSize)

        // Nothing is read until the reply lands, by which point every event has been
        // yielded and the buffer has had to make its choice.
        _ = try await client.execute(.systemReset)

        // The connection is still alive and correlating replies.
        let status = try await client.queryStatus()
        XCTAssertEqual(status.status, "running")

        let received = await Self.collect(bufferSize, from: events)
        XCTAssertEqual(received.count, bufferSize)
        XCTAssertEqual(
            received.compactMap { $0.data?["seq"]?.intValue },
            Array((Self.floodedEventCount - bufferSize)..<Self.floodedEventCount),
            "A full buffer keeps the newest events and discards the oldest"
        )

        try await client.disconnect()
    }

    /// `DEVICE_DELETED` keeps its dedicated ticket path — a detach needs a targeted,
    /// timed wait, not a scan of a shared stream — and publishing it to subscribers
    /// must not consume it on the way.
    func testDeviceDeletedReachesBothItsTicketAndTheStream() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        let events = try client.events()
        try await client.deviceDel(deviceId: "vdb", timeout: 3)

        let received = await Self.collect(1, from: events)
        XCTAssertEqual(received.map(\.event), ["DEVICE_DELETED"])
        XCTAssertEqual(received.first?.data?["device"]?.stringValue, "vdb")

        try await client.disconnect()
    }

    // MARK: - Capability negotiation

    /// The greeting's capabilities were decoded and thrown away, so `oob` stayed off
    /// however new the QEMU was. What it offers and we support must be asked for by
    /// name.
    func testOfferedCapabilitiesAreNegotiated() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU, capabilities: ["oob"])
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        XCTAssertEqual(client.negotiatedCapabilities, [.oob])
        XCTAssertEqual(client.greeting?.QMP.capabilities, ["oob"], "The greeting is kept, not discarded")
        XCTAssertEqual(client.greeting?.QMP.version.qemu.major, 8)

        let negotiation = try XCTUnwrap(server.receivedRequests.first { $0.contains("qmp_capabilities") })
        XCTAssertTrue(negotiation.contains("\"enable\""), negotiation)
        XCTAssertTrue(negotiation.contains("\"oob\""), negotiation)

        try await client.disconnect()

        XCTAssertEqual(client.negotiatedCapabilities, [], "Capabilities belong to a connection")
        XCTAssertNil(client.greeting)
    }

    /// Asking for a capability QEMU did not offer fails the negotiation outright,
    /// which leaves a monitor that refuses every later command. So the request is the
    /// intersection, never the wish list.
    func testNoEnableListWhenTheGreetingOffersNothingWeSupport() async throws {
        let server = try await FakeQMPServer(
            behaviour: .greetAndBehaveLikeQEMU,
            capabilities: ["something-qemu-invents-later"]
        )
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        XCTAssertEqual(client.negotiatedCapabilities, [])

        let negotiation = try XCTUnwrap(server.receivedRequests.first { $0.contains("qmp_capabilities") })
        XCTAssertFalse(
            negotiation.contains("\"enable\""),
            "A capability we do not implement must not be requested: \(negotiation)"
        )

        try await client.disconnect()
    }

    /// Opting out has to be possible, and has to mean nothing is enabled even when
    /// QEMU offers it.
    func testCapabilitiesAreNotNegotiatedWhenNoneAreRequested() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU, capabilities: ["oob"])
        defer { Task { await server.shutdown() } }

        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: 5,
            connectTimeout: 5,
            requestedCapabilities: []
        )
        try await client.connectUnix(path: server.socketPath)

        XCTAssertEqual(client.negotiatedCapabilities, [])
        let negotiation = try XCTUnwrap(server.receivedRequests.first { $0.contains("qmp_capabilities") })
        XCTAssertFalse(negotiation.contains("\"enable\""), negotiation)

        try await client.disconnect()
    }

    // MARK: - Out-of-band execution

    /// An out-of-band request is spelled `exec-oob`, not `execute` plus a `control`
    /// member: QEMU 11 rejects the latter with "QMP input member 'control' is
    /// unexpected" (verified against 11.0.2), so only the wire form proves this.
    func testOutOfBandRequestUsesTheExecOOBKey() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU, capabilities: ["oob"])
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        _ = try await client.queryYank(outOfBand: true)

        let sent = try XCTUnwrap(server.receivedRequests.first { $0.contains("query-yank") })
        XCTAssertTrue(sent.contains("\"exec-oob\":\"query-yank\""), sent)
        XCTAssertFalse(sent.contains("\"execute\""), sent)
        XCTAssertFalse(sent.contains("control"), "The `control` form is rejected by QEMU: \(sent)")
        XCTAssertTrue(sent.contains("\"id\""), "An out-of-band request must be correlatable: \(sent)")

        try await client.disconnect()
    }

    /// Without the capability, QEMU answers an `exec-oob` request with "QMP input
    /// member 'exec-oob' is unexpected", which names the JSON rather than the
    /// problem. Caught before it goes out instead.
    func testOutOfBandExecuteRequiresTheCapability() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        do {
            _ = try await client.executeOutOfBand(.queryYank)
            XCTFail("Expected an out-of-band request to be refused without the capability")
        } catch let error as QMPError {
            guard case .capabilityNotNegotiated(.oob) = error else {
                return XCTFail("Expected .capabilityNotNegotiated(.oob), got \(error)")
            }
        }

        XCTAssertFalse(
            server.receivedRequests.contains { $0.contains("exec-oob") },
            "Nothing should have reached the wire"
        )

        try await client.disconnect()
    }

    /// In-band execution is unaffected by having the capability, and still goes out
    /// under `execute`.
    func testInBandRequestsStillUseExecute() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU, capabilities: ["oob"])
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        _ = try await client.queryYank()

        let sent = try XCTUnwrap(server.receivedRequests.first { $0.contains("query-yank") })
        XCTAssertTrue(sent.contains("\"execute\":\"query-yank\""), sent)
        XCTAssertFalse(sent.contains("exec-oob"), sent)

        try await client.disconnect()
    }

    // MARK: - Against a real QEMU

    /// The out-of-band path end to end against a real QEMU.
    ///
    /// The fake server accepts whatever it is sent, so it can only prove the shape
    /// this library *intends* to send. QEMU is the authority on whether that shape
    /// is accepted at all — and it rejects the plausible-looking alternative with
    /// `QMP input member 'control' is unexpected`. Skipped where QEMU is not
    /// installed.
    func testOutOfBandCommandIsAcceptedByARealQEMU() async throws {
        let candidates = [
            "/opt/homebrew/bin/qemu-system-x86_64",
            "/usr/local/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-x86_64"
        ]
        guard let qemuPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("qemu-system-x86_64 not installed")
        }

        // The socket path is left to `QEMUProcess`, which puts it in a private
        // directory and keeps it inside `sun_path`'s ~104 bytes. A hand-built
        // `NSTemporaryDirectory() + UUID` path is about 100 of those on macOS —
        // close enough to the limit to be worth not doing.
        let process = QEMUProcess(qemuPath: qemuPath, logger: Logger(label: "test"))
        let socketPath = process.getQMPSocketPath()
        addTeardownBlock { await process.stop() }

        var config = QEMUConfiguration()
        config.memoryMB = 128
        try await process.start(with: config)

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: socketPath)

        XCTAssertEqual(client.negotiatedCapabilities, [.oob], "QEMU 11 offers oob")

        // `query-yank` is one of the four commands QEMU marks `allow-oob`. A reply at
        // all is the assertion: a malformed out-of-band request is answered with an
        // error, which `executeOutOfBand` throws.
        let instances = try await client.queryYank(outOfBand: true)
        XCTAssertFalse(instances.isEmpty, "The monitor's own chardev is always yankable")

        // And an in-band command still works on the same connection afterwards.
        let status = try await client.queryStatus()
        XCTAssertEqual(status.status, "prelaunch")

        try await client.disconnect()
    }

    // MARK: - Teardown

    /// A peer that has already closed is a completed disconnect, not a failed
    /// one.
    ///
    /// QEMU exits in response to `quit`, closing the channel from its end, so the
    /// close here fails with `ChannelError.alreadyClosed`. That error used to
    /// escape `disconnect()` and propagate out of `QEMUManager.destroy()` before
    /// it could terminate the process — leaving an orphaned QEMU behind.
    func testDisconnectAfterPeerClosedIsNotAFailure() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)

        _ = try await client.execute(.quit)
        try await Task.sleep(nanoseconds: 500_000_000) // let the close land

        try await client.disconnect()
        XCTAssertFalse(client.isConnected)

        // Idempotent: tearing down twice is not an error either.
        try await client.disconnect()
    }

    /// Losing the connection must clear the connected flag, so the next command
    /// fails as not-connected instead of being written into a dead channel and
    /// waiting out its timeout.
    func testConnectionLossClearsConnectedState() async throws {
        let server = try await FakeQMPServer(behaviour: .greetAndBehaveLikeQEMU)
        defer { Task { await server.shutdown() } }

        let client = QMPClient(logger: Logger(label: "test"), requestTimeout: 5, connectTimeout: 5)
        try await client.connectUnix(path: server.socketPath)
        XCTAssertTrue(client.isConnected)

        _ = try await client.execute(.quit)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(client.isConnected, "A closed channel is not a connection")

        do {
            _ = try await client.execute(.queryStatus)
            XCTFail("Expected a command on a lost connection to fail")
        } catch let error as QMPError {
            guard case .notConnected = error else {
                return XCTFail("Expected .notConnected, got \(error)")
            }
        }

        try await client.disconnect()
    }
}

extension QMPClientTests.ServerBehaviour: Equatable {}
