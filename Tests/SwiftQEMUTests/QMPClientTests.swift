import XCTest
import NIOCore
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
        /// Greet and negotiate normally, then answer subsequent commands with
        /// an id belonging to no outstanding request. Models QEMU finally
        /// replying to a request that already timed out.
        case greetThenReplyWithStaleID
    }

    private static let greeting = #"{"QMP": {"version": {"qemu": {"major": 8, "minor": 0, "micro": 0}, "package": ""}, "capabilities": []}}"#

    final class FakeQMPServer: Sendable {
        private let channel: Channel
        let socketPath: String

        init(behaviour: ServerBehaviour) async throws {
            self.socketPath = NSTemporaryDirectory() + "qmp-test-\(UUID().uuidString).sock"

            let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(ServerHandler(behaviour: behaviour))
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
            private var buffer = ByteBuffer()
            private var negotiated = false

            init(behaviour: ServerBehaviour) {
                self.behaviour = behaviour
            }

            func channelActive(context: ChannelHandlerContext) {
                guard behaviour != .silent else { return }
                write(QMPClientTests.greeting, context: context)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard behaviour != .silent else { return }

                var input = self.unwrapInboundIn(data)
                buffer.writeBuffer(&input)

                // Echo back a success response per newline-delimited request,
                // preserving the request's `id` the way QEMU does.
                while let line = readLine(&buffer) {
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

            private func write(_ string: String, context: ChannelHandlerContext) {
                var out = context.channel.allocator.buffer(capacity: string.utf8.count + 1)
                out.writeString(string)
                out.writeString("\n")
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
}

extension QMPClientTests.ServerBehaviour: Equatable {}
