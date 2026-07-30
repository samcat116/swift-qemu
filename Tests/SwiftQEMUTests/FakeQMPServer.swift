import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import SwiftQEMU

/// A scripted in-process QMP server, for the failure modes a real QEMU will not
/// perform on request: greeting before anyone waits, accepting and then saying
/// nothing, replying under an id that belongs to nobody, withholding a newline
/// forever.
///
/// Lifetime is a scope: `QMPClientTests.withServer` shuts one of these down when
/// its body is over, on the failure path too, which is what replaces the
/// `defer { Task { await server.shutdown() } }` that fired off cleanup nobody
/// waited for. It matters that the scope and not ARC decides: releasing the server
/// closes the listening socket, and `connectUnix` retries — a server collected
/// between attempts would turn a negotiation timeout into a connection refusal.
///
/// `deinit` is the backstop for a server that escapes its scope anyway. Both halves
/// of it are synchronous: `Channel.close(promise: nil)` is safe from any thread and
/// does not have to be awaited.
final class FakeQMPServer: Sendable {

    /// What the server does once a client connects.
    enum Behaviour: Sendable, Equatable {
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
    static let floodPadding = 64 * 1024
    static let oversizedFramePadding = 400
    static let largeLegalPadding = 60_000

    /// How many events `.greetAndFloodEvents` emits per `system_reset`.
    static let floodedEventCount = 200

    private static let deviceDeletedEvent = #"{"timestamp": {"seconds": 1745000000, "microseconds": 1}, "event": "DEVICE_DELETED", "data": {"device": "vdb", "path": "/machine/peripheral/vdb"}}"#
    private static let resumeEvent = #"{"timestamp": {"seconds": 1745000000, "microseconds": 2}, "event": "RESUME"}"#

    static func greeting(capabilities: [String]) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"QMP": {"version": {"qemu": {"major": 8, "minor": 0, "micro": 0}, "package": ""}, "capabilities": [\#(list)]}}"#
    }

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
    init(behaviour: Behaviour, capabilities: [String] = []) async throws {
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

    /// Close the listening socket and remove the socket file. Closing does not
    /// disturb connections already accepted, so a client still under test is
    /// unaffected.
    func shutdown() async {
        try? await channel.close()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit {
        channel.close(promise: nil)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private final class ServerHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let behaviour: Behaviour
        private let capabilities: [String]
        private let received: NIOLockedValueBox<[String]>
        private var buffer = ByteBuffer()
        private var negotiated = false

        init(
            behaviour: Behaviour,
            capabilities: [String],
            received: NIOLockedValueBox<[String]>
        ) {
            self.behaviour = behaviour
            self.capabilities = capabilities
            self.received = received
        }

        func channelActive(context: ChannelHandlerContext) {
            guard behaviour != .silent else { return }
            write(FakeQMPServer.greeting(capabilities: capabilities), context: context)
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
                for sequence in 0..<FakeQMPServer.floodedEventCount {
                    write(#"{"event": "RESET", "data": {"seq": \#(sequence)}}"#, context: context)
                }
                reply("{}")
            } else if line.contains("\"cont\"") {
                // The event genuinely precedes the reply.
                write(FakeQMPServer.resumeEvent, context: context)
                reply("{}")
            } else if line.contains("device_del") {
                if behaviour == .greetAndDeleteBeforeReplying {
                    write(FakeQMPServer.deviceDeletedEvent, context: context)
                    reply("{}")
                } else {
                    reply("{}")
                    write(FakeQMPServer.deviceDeletedEvent, context: context)
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
                let pad = String(repeating: "A", count: FakeQMPServer.floodPadding)
                write("{\"return\": {\"pad\": \"\(pad)", context: context, terminated: false)
            case .greetThenSendOversizedFrame:
                let pad = String(repeating: "A", count: FakeQMPServer.oversizedFramePadding)
                write("{\"return\": {\"pad\": \"\(pad)\"}\(idField)}", context: context)
            case .greetThenReplyWithLargePayload:
                let pad = String(repeating: "A", count: FakeQMPServer.largeLegalPadding)
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
