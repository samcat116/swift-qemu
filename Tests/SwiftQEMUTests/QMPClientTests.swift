import Foundation
import Logging
import Testing
@testable import SwiftQEMU

/// End-to-end tests for `QMPClient` against a scripted in-process QMP server.
///
/// These cover the failure modes that used to hang the caller forever rather
/// than surfacing an error: a greeting that lands before anyone waits for it,
/// and a peer that accepts the connection but never speaks. `.hangBackstop` is
/// what makes a regression in any of them a failure rather than a stuck run.
@Suite("QMP client", .hangBackstop)
struct QMPClientTests {

    // MARK: - Scoped fixtures

    /// Run `body` against a scripted server whose lifetime is exactly this scope.
    ///
    /// A scope rather than the object's own lifetime, because ARC is free to
    /// release a local once nothing reads it again — and releasing this one closes
    /// the listening socket. `.silent` is the case that makes it matter:
    /// `connectUnix` retries, and a server collected between attempts turns the
    /// negotiation timeout these tests assert on into a connection refusal.
    private func withServer<R>(
        _ behaviour: FakeQMPServer.Behaviour,
        capabilities: [String] = [],
        _ body: (FakeQMPServer) async throws -> R
    ) async throws -> R {
        let server = try await FakeQMPServer(behaviour: behaviour, capabilities: capabilities)
        do {
            let result = try await body(server)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// The common case: a server, and a client already connected and negotiated
    /// with it. Disconnected afterwards, including when `body` fails — which the
    /// trailing `disconnect()` calls this replaces did not manage.
    private func withConnectedClient<R>(
        to behaviour: FakeQMPServer.Behaviour,
        capabilities: [String] = [],
        requestTimeout: Duration = .seconds(5),
        connectTimeout: Duration = .seconds(5),
        maximumFrameSize: Int = QMPClient.defaultMaximumFrameSize,
        requestedCapabilities: Set<QMPCapability> = [.oob],
        _ body: (QMPClient, FakeQMPServer) async throws -> R
    ) async throws -> R {
        try await withServer(behaviour, capabilities: capabilities) { server in
            let client = QMPClient(
                logger: Logger(label: "test"),
                requestTimeout: requestTimeout,
                connectTimeout: connectTimeout,
                maximumFrameSize: maximumFrameSize,
                requestedCapabilities: requestedCapabilities
            )
            try await client.connectUnix(path: server.socketPath)
            do {
                let result = try await body(client, server)
                try await client.disconnect()
                return result
            } catch {
                try? await client.disconnect()
                throw error
            }
        }
    }

    // MARK: - Connecting

    /// The greeting is written the instant the connection is accepted, so it
    /// routinely arrives before `waitForGreeting` installs its continuation.
    /// Before the greeting was latched, that ordering dropped the resume on the
    /// floor and the connect parked forever. Repeated to make the race likely.
    @Test func connectSucceedsWhenGreetingArrivesBeforeTheWaiterIsInstalled() async throws {
        for _ in 0..<25 {
            try await withConnectedClient(to: .greetImmediately) { _, _ in }
        }
    }

    /// A peer that accepts and then never speaks must surface an error within
    /// the budget. Previously `waitForGreeting` had no deadline at all, so this
    /// call never returned — the agent-level hang reported in strato#516.
    @Test func connectToSilentPeerTimesOutInsteadOfHanging() async throws {
        try await withServer(.silent) { server in
            // connectUnix retries, so keep the per-attempt budget small to bound
            // the test; what matters is that it terminates at all.
            let client = QMPClient(
                logger: Logger(label: "test"),
                requestTimeout: .milliseconds(200),
                connectTimeout: .milliseconds(200)
            )

            // Any surfaced error is acceptable; hanging is not.
            await #expect(throws: QMPError.self) {
                try await client.connectUnix(path: server.socketPath)
            }
        }
    }

    /// A peer that accepts but never greets fails with the negotiation's own
    /// error, not with a generic "could not connect" wrapped around it — the
    /// distinction between "nothing is there" and "something is there and
    /// wedged" is the whole diagnostic value.
    @Test func silentPeerKeepsItsNegotiationErrorRatherThanBeingWrapped() async throws {
        try await withServer(.silent) { server in
            let client = QMPClient(
                logger: Logger(label: "test"),
                requestTimeout: .milliseconds(100),
                connectTimeout: .milliseconds(100)
            )

            let error = try await #require(throws: QMPError.self) {
                try await client.connectUnix(path: server.socketPath)
            }
            guard case .timeout = error else {
                Issue.record("Expected .timeout, got \(error)")
                return
            }
        }
    }

    /// A refused connection is named in this library's own vocabulary, with the
    /// endpoint attached. NIO's own error says only that the connection failed.
    @Test func refusedConnectionIsReportedAsAConnectionFailure() async throws {
        // Port 1 on the loopback: privileged, and nothing is listening there.
        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: .seconds(5),
            connectTimeout: .seconds(5)
        )

        let error = try await #require(throws: QMPError.self) {
            try await client.connectTCP(host: "127.0.0.1", port: 1)
        }
        guard case .connectionFailed(let endpoint, _) = error else {
            Issue.record("Expected .connectionFailed, got \(error)")
            return
        }
        #expect(endpoint == "127.0.0.1:1")
        #expect(!client.isConnected)
    }

    // MARK: - Timeouts

    /// A request whose response never comes must time out rather than park.
    @Test func requestToSilentPeerTimesOut() async throws {
        try await withConnectedClient(to: .greetButSwallowDeviceDeleted) { client, _ in
            // The fake server answers commands but never emits DEVICE_DELETED, so
            // the post-command event wait is what must time out. The old
            // implementation left its continuation parked, which meant the
            // surrounding task group could never drain — the timeout itself hung.
            let error = try await #require(throws: QMPError.self) {
                try await client.deviceDel(deviceId: "vdb", timeout: .milliseconds(300))
            }
            guard case .timeout = error else {
                Issue.record("Expected .timeout, got \(error)")
                return
            }
        }
    }

    /// A response whose id matches no outstanding request must be discarded,
    /// not handed to whichever request happens to be pending. QEMU still
    /// answers requests that already timed out, and resuming a *different*
    /// caller with that stale payload is the response-shift corruption that id
    /// correlation exists to prevent.
    @Test func responseWithUnmatchedIDIsDiscardedRatherThanShifted() async throws {
        try await withConnectedClient(
            to: .greetThenReplyWithStaleID,
            requestTimeout: .milliseconds(400)
        ) { client, _ in
            // The server answers, but under an id nobody is waiting on. The
            // correct outcome is that this command times out — never that it
            // silently adopts a reply meant for someone else.
            let error = try await #require(throws: QMPError.self) {
                _ = try await client.execute(.cont)
            }
            guard case .timeout = error else {
                Issue.record("Expected .timeout, got \(error)")
                return
            }
        }
    }

    /// A tiny budget must fail immediately, not never.
    ///
    /// When the deadline raced the parking task, a deadline that reached its
    /// callback first found no waiter to fail; the operation then parked on a
    /// continuation nobody would resume and the wait hung — a timeout that
    /// hangs. A zero budget makes that ordering certain, and the small ones are
    /// repeated so they hit it too.
    ///
    /// The elapsed budget is the assertion, and is far tighter than a time-limit
    /// trait can express: 25 waits that each fail promptly are milliseconds' work.
    @Test(
        "A tiny timeout never strands the waiter",
        arguments: [Duration.zero, .microseconds(500), .milliseconds(1)]
    )
    func tinyTimeoutsNeverStrandTheWaiter(timeout: Duration) async throws {
        try await withConnectedClient(to: .greetButSwallowDeviceDeleted) { client, _ in
            let started = ContinuousClock.now
            for _ in 0..<25 {
                let error = try await #require(throws: QMPError.self) {
                    try await client.deviceDel(deviceId: "vdb", timeout: timeout)
                }
                guard case .timeout = error else {
                    Issue.record("Expected .timeout, got \(error)")
                    return
                }
            }
            #expect(started.duration(to: .now) < .seconds(5))
        }
    }

    // MARK: - Cancellation

    /// A cancelled command must come back at once, not when its deadline fires.
    ///
    /// The waits used to be cancellation-blind: the only thing that could resume
    /// them was the deadline, so a cancelled caller stayed parked for the whole
    /// budget — up to the 10s default — with nothing left to wait for.
    @Test func cancellingACommandReturnsWellBeforeItsTimeout() async throws {
        // A budget far longer than this test is willing to wait for: if
        // cancellation is not honoured, the only other way out is the timeout,
        // and the elapsed-time assertion fails long before it arrives.
        try await withConnectedClient(
            to: .greetThenSwallowCommands,
            requestTimeout: .seconds(60)
        ) { client, _ in
            let started = ContinuousClock.now
            let command = Task { try await client.execute(.cont) }
            // Give the command time to park, so this covers cancelling an
            // installed waiter; the pre-park ordering is covered below.
            try await Task.sleep(for: .milliseconds(100))
            command.cancel()

            let error = try await #require(throws: QMPError.self) { _ = try await command.value }
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            #expect(
                started.duration(to: .now) < .seconds(5),
                "A cancelled command must not wait out its request timeout"
            )
        }
    }

    /// The same for the `DEVICE_DELETED` wait, which parks after the command
    /// itself has been answered.
    @Test func cancellingADeviceDetachReturnsWellBeforeItsTimeout() async throws {
        try await withConnectedClient(to: .greetButSwallowDeviceDeleted) { client, _ in
            let started = ContinuousClock.now
            let detach = Task { try await client.deviceDel(deviceId: "vdb", timeout: .seconds(60)) }
            try await Task.sleep(for: .milliseconds(100))
            detach.cancel()

            let error = try await #require(throws: QMPError.self) { try await detach.value }
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            #expect(
                started.duration(to: .now) < .seconds(5),
                "A cancelled detach must not wait out its event timeout"
            )
        }
    }

    /// Cancellation that lands *before* the waiter parks is the mirror image of
    /// the deadline ordering hazard: the canceller finds nothing to cancel, and
    /// the operation then parks behind it. Repeated so that ordering is actually
    /// hit — an immediate `cancel()` usually beats the task to its first
    /// suspension.
    @Test func cancellationBeforeTheWaiterParksIsNotLost() async throws {
        try await withConnectedClient(
            to: .greetThenSwallowCommands,
            requestTimeout: .seconds(60)
        ) { client, _ in
            let started = ContinuousClock.now
            for _ in 0..<25 {
                let command = Task { try await client.execute(.cont) }
                command.cancel()

                let error = try await #require(throws: QMPError.self) { _ = try await command.value }
                guard case .cancelled = error else {
                    Issue.record("Expected .cancelled, got \(error)")
                    return
                }
            }
            #expect(
                started.duration(to: .now) < .seconds(5),
                "Cancellation must be honoured however it races the waiter"
            )
        }
    }

    /// A normal command round-trip still works, and the response is correlated
    /// back by id.
    @Test func commandRoundTrip() async throws {
        try await withConnectedClient(to: .greetImmediately) { client, _ in
            _ = try await client.execute(.cont)
        }
    }

    // MARK: - Events vs. replies

    /// `DEVICE_DELETED` must reach the waiter that asked for it.
    ///
    /// Every property of `QMPResponse` is optional, so decoding response-first
    /// accepted this event as an all-`nil` response and consumed it. The event
    /// branch was unreachable, the waiter was never resumed, and detaching a disk
    /// therefore always failed with a timeout — against a server doing everything
    /// right.
    ///
    /// Both orderings, because the waiter is installed only after the command has
    /// been answered: with the event second it has somewhere to go, and with the
    /// event first it is only survivable because an unclaimed deletion is latched.
    @Test(
        "DEVICE_DELETED reaches its waiter whichever side of the reply it arrives on",
        arguments: [FakeQMPServer.Behaviour.greetAndBehaveLikeQEMU, .greetAndDeleteBeforeReplying]
    )
    func deviceDeletedEventReachesItsWaiter(behaviour: FakeQMPServer.Behaviour) async throws {
        try await withConnectedClient(to: behaviour) { client, _ in
            try await client.deviceDel(deviceId: "vdb", timeout: .seconds(3))
        }
    }

    /// An event that arrives while a command is in flight must not be handed
    /// over as that command's reply.
    ///
    /// QEMU emits `RESUME` before it answers `cont`, and the untagged-response
    /// fallback used to hand that event straight to the waiting request — the
    /// caller got an empty payload while the real reply was discarded as
    /// unmatched.
    @Test func eventDoesNotStealACommandReply() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let result = try await client.execute(.cont)
            #expect(
                result?.objectValue != nil,
                "cont must return QEMU's `{}` reply, not the RESUME event that preceded it"
            )

            // And the connection is still correlated correctly afterwards.
            let status = try await client.queryStatus()
            #expect(status.status == "running")
        }
    }

    // MARK: - Inbound frame limit

    /// A peer that writes without ever sending a newline must fail the
    /// connection, not grow the inbound buffer for as long as it keeps writing.
    ///
    /// The request budget here is deliberately long: a client that only notices
    /// via the request deadline has buffered every byte in the meantime, which is
    /// the unbounded growth this guards against.
    @Test func unterminatedFrameFailsTheConnectionInsteadOfBufferingForever() async throws {
        let limit = 8 * 1024
        try await withConnectedClient(
            to: .greetThenFloodWithoutNewline,
            requestTimeout: .seconds(30),
            maximumFrameSize: limit
        ) { client, _ in
            let error = try await #require(throws: QMPError.self) {
                _ = try await client.execute(.cont)
            }
            guard case .frameTooLarge(let reported) = error else {
                Issue.record("Expected .frameTooLarge, got \(error)")
                return
            }
            #expect(reported == limit)
            #expect(!client.isConnected, "An overflowing peer is not a usable connection")
        }
    }

    /// The same verdict for a frame that is complete but over the limit — the cap
    /// is on frame size, not merely on how long a peer withholds its newline.
    @Test func completeButOversizedFrameFailsTheConnection() async throws {
        let limit = 300
        try await withConnectedClient(
            to: .greetThenSendOversizedFrame,
            requestTimeout: .seconds(30),
            maximumFrameSize: limit
        ) { client, _ in
            let error = try await #require(throws: QMPError.self) {
                _ = try await client.execute(.cont)
            }
            guard case .frameTooLarge(let reported) = error else {
                Issue.record("Expected .frameTooLarge, got \(error)")
                return
            }
            #expect(reported == limit)
        }
    }

    /// A large reply that still fits the cap must be delivered intact. QMP
    /// payloads like `query-block` on a long device list run to tens of KB, so a
    /// cap that clipped them would be worse than no cap at all. Arriving across
    /// several socket reads is also the case the incomplete-frame path has to get
    /// right.
    ///
    /// Once with a cap this test sets, and once with the shipped default — which
    /// has to be far above any real QMP message, or the well-behaved path pays for
    /// the protection.
    @Test("A large but legal frame is delivered", arguments: [64 * 1024, QMPClient.defaultMaximumFrameSize])
    func largeFrameWithinTheLimitIsStillDelivered(maximumFrameSize: Int) async throws {
        #expect(QMPClient.defaultMaximumFrameSize >= 256 * 1024)

        try await withConnectedClient(
            to: .greetThenReplyWithLargePayload,
            requestTimeout: .seconds(10),
            maximumFrameSize: maximumFrameSize
        ) { client, _ in
            let result = try await client.execute(.cont)
            #expect(result?["pad"]?.stringValue?.count == FakeQMPServer.largeLegalPadding)
            #expect(client.isConnected)
        }
    }

    // MARK: - Status parsing

    /// `query-status` on a modern QEMU carries no `singlestep`; requiring it made
    /// every status query fail, which surfaced as a permanently `.unknown` VM.
    @Test func queryStatusAcceptsModernQEMUShape() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let status = try await client.queryStatus()
            #expect(status.status == "running")
            #expect(status.running)
            #expect(status.singlestep == nil, "The field is absent, not false")
        }
    }

    // MARK: - Event stream

    /// The events QEMU announces have to reach a subscriber. Before there was a
    /// stream, everything except `DEVICE_DELETED` was logged at debug level and
    /// dropped, leaving callers to poll `query-status` for things QEMU had already
    /// reported.
    @Test func eventsReachASubscriber() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let events = try client.events()
            _ = try await client.execute(.cont)

            let received = await QMPEvents.collect(1, from: events)
            #expect(received.map(\.event) == ["RESUME"])
        }
    }

    /// Several consumers can watch one connection: the manager keeps its own status
    /// bookkeeping while an application watches the same events.
    @Test func everySubscriberSeesEveryEvent() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let first = try client.events()
            let second = try client.events()
            _ = try await client.execute(.cont)

            async let pendingFirst = QMPEvents.collect(1, from: first)
            async let pendingSecond = QMPEvents.collect(1, from: second)
            let firstReceived = await pendingFirst
            let secondReceived = await pendingSecond

            #expect(firstReceived.map(\.event) == ["RESUME"])
            #expect(secondReceived.map(\.event) == ["RESUME"])
        }
    }

    /// `disconnect()` must finish the stream, or a `for await` over it parks forever
    /// on a connection that no longer exists.
    @Test func eventStreamFinishesOnDisconnect() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let events = try client.events()
            try await client.disconnect()

            let received = await QMPEvents.drainUntilFinished(events)
            #expect(received != nil, "The stream must be over, not merely silent")
            #expect(received?.isEmpty == true)
        }
    }

    /// The same for a peer that goes away on its own — QEMU exiting in response to
    /// `quit` is the ordinary case, not an exceptional one.
    @Test func eventStreamFinishesWhenThePeerGoesAway() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let events = try client.events()
            _ = try await client.execute(.quit)

            // The fake server closes the socket after answering `quit`.
            let received = await QMPEvents.drainUntilFinished(events)
            #expect(received != nil, "The stream must finish when the peer closes the connection")
        }
    }

    @Test func subscribingWithoutAConnectionThrows() throws {
        let client = QMPClient(logger: Logger(label: "test"))

        let error = try #require(throws: QMPError.self) { _ = try client.events() }
        guard case .notConnected = error else {
            Issue.record("Expected .notConnected, got \(error)")
            return
        }
    }

    /// A subscriber that stops reading must not stall the event loop, so the buffer
    /// is bounded and drops the *oldest* events. The connection has to stay fully
    /// usable while that happens — a blocking yield here would wedge QEMU's socket
    /// for every other waiter too.
    @Test func slowSubscriberDropsOldestEventsWithoutStallingTheConnection() async throws {
        try await withConnectedClient(to: .greetAndFloodEvents) { client, _ in
            let bufferSize = 4
            let events = try client.events(bufferSize: bufferSize)

            // Nothing is read until the reply lands, by which point every event has
            // been yielded and the buffer has had to make its choice.
            _ = try await client.execute(.systemReset)

            // The connection is still alive and correlating replies.
            let status = try await client.queryStatus()
            #expect(status.status == "running")

            let received = await QMPEvents.collect(bufferSize, from: events)
            #expect(received.count == bufferSize)
            #expect(
                received.compactMap { $0.data?["seq"]?.intValue }
                    == Array((FakeQMPServer.floodedEventCount - bufferSize)..<FakeQMPServer.floodedEventCount),
                "A full buffer keeps the newest events and discards the oldest"
            )
        }
    }

    /// `DEVICE_DELETED` keeps its dedicated ticket path — a detach needs a targeted,
    /// timed wait, not a scan of a shared stream — and publishing it to subscribers
    /// must not consume it on the way.
    @Test func deviceDeletedReachesBothItsTicketAndTheStream() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            let events = try client.events()
            try await client.deviceDel(deviceId: "vdb", timeout: .seconds(3))

            let received = await QMPEvents.collect(1, from: events)
            #expect(received.map(\.event) == ["DEVICE_DELETED"])
            #expect(received.first?.data?["device"]?.stringValue == "vdb")
        }
    }

    // MARK: - Capability negotiation

    /// The greeting's capabilities were decoded and thrown away, so `oob` stayed off
    /// however new the QEMU was. What it offers and we support must be asked for by
    /// name.
    @Test func offeredCapabilitiesAreNegotiated() async throws {
        let client = try await withConnectedClient(
            to: .greetAndBehaveLikeQEMU,
            capabilities: ["oob"]
        ) { client, server in
            #expect(client.negotiatedCapabilities == [.oob])
            #expect(client.greeting?.QMP.capabilities == ["oob"], "The greeting is kept, not discarded")
            #expect(client.greeting?.QMP.version.qemu.major == 8)

            let negotiation = try #require(server.receivedRequests.first { $0.contains("qmp_capabilities") })
            #expect(negotiation.contains("\"enable\""), "\(negotiation)")
            #expect(negotiation.contains("\"oob\""), "\(negotiation)")
            return client
        }

        // The scope disconnected it, and what was negotiated belonged to that
        // connection rather than to the client.
        #expect(client.negotiatedCapabilities == [], "Capabilities belong to a connection")
        #expect(client.greeting == nil)
    }

    /// Asking for a capability QEMU did not offer fails the negotiation outright,
    /// which leaves a monitor that refuses every later command. So the request is the
    /// intersection, never the wish list — and opting out has to mean nothing is
    /// enabled even where QEMU offers it.
    @Test("No enable list is sent when nothing is both offered and wanted", arguments: [
        // What the greeting advertises, and what this client asks for.
        (["something-qemu-invents-later"], Set<QMPCapability>([.oob])),
        (["oob"], Set<QMPCapability>())
    ])
    func noEnableListWhenThereIsNoIntersection(
        offered: [String],
        requested: Set<QMPCapability>
    ) async throws {
        try await withConnectedClient(
            to: .greetAndBehaveLikeQEMU,
            capabilities: offered,
            requestedCapabilities: requested
        ) { client, server in
            #expect(client.negotiatedCapabilities == [])

            let negotiation = try #require(server.receivedRequests.first { $0.contains("qmp_capabilities") })
            #expect(
                !negotiation.contains("\"enable\""),
                "A capability the two sides did not both name must not be requested: \(negotiation)"
            )
        }
    }

    // MARK: - Out-of-band execution

    /// An out-of-band request is spelled `exec-oob`, not `execute` plus a `control`
    /// member: QEMU 11 rejects the latter with "QMP input member 'control' is
    /// unexpected" (verified against 11.0.2), so only the wire form proves this.
    @Test func outOfBandRequestUsesTheExecOOBKey() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU, capabilities: ["oob"]) { client, server in
            _ = try await client.queryYank(outOfBand: true)

            let sent = try #require(server.receivedRequests.first { $0.contains("query-yank") })
            #expect(sent.contains("\"exec-oob\":\"query-yank\""), "\(sent)")
            #expect(!sent.contains("\"execute\""), "\(sent)")
            #expect(!sent.contains("control"), "The `control` form is rejected by QEMU: \(sent)")
            #expect(sent.contains("\"id\""), "An out-of-band request must be correlatable: \(sent)")
        }
    }

    /// Without the capability, QEMU answers an `exec-oob` request with "QMP input
    /// member 'exec-oob' is unexpected", which names the JSON rather than the
    /// problem. Caught before it goes out instead.
    @Test func outOfBandExecuteRequiresTheCapability() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, server in
            let error = try await #require(throws: QMPError.self) {
                _ = try await client.executeOutOfBand(.queryYank)
            }
            guard case .capabilityNotNegotiated(.oob) = error else {
                Issue.record("Expected .capabilityNotNegotiated(.oob), got \(error)")
                return
            }

            #expect(
                !server.receivedRequests.contains { $0.contains("exec-oob") },
                "Nothing should have reached the wire"
            )
        }
    }

    /// In-band execution is unaffected by having the capability, and still goes out
    /// under `execute`.
    @Test func inBandRequestsStillUseExecute() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU, capabilities: ["oob"]) { client, server in
            _ = try await client.queryYank()

            let sent = try #require(server.receivedRequests.first { $0.contains("query-yank") })
            #expect(sent.contains("\"execute\":\"query-yank\""), "\(sent)")
            #expect(!sent.contains("exec-oob"), "\(sent)")
        }
    }

    // MARK: - Teardown

    /// A peer that has already closed is a completed disconnect, not a failed
    /// one.
    ///
    /// QEMU exits in response to `quit`, closing the channel from its end, so the
    /// close here fails with `ChannelError.alreadyClosed`. That error used to
    /// escape `disconnect()` and propagate out of `QEMUManager.destroy()` before
    /// it could terminate the process — leaving an orphaned QEMU behind.
    @Test func disconnectAfterPeerClosedIsNotAFailure() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            _ = try await client.execute(.quit)
            try await Task.sleep(for: .milliseconds(500)) // let the close land

            try await client.disconnect()
            #expect(!client.isConnected)

            // Idempotent: tearing down twice is not an error either, which the
            // scope's own disconnect makes a third time.
            try await client.disconnect()
        }
    }

    /// Losing the connection must clear the connected flag, so the next command
    /// fails as not-connected instead of being written into a dead channel and
    /// waiting out its timeout.
    @Test func connectionLossClearsConnectedState() async throws {
        try await withConnectedClient(to: .greetAndBehaveLikeQEMU) { client, _ in
            #expect(client.isConnected)

            _ = try await client.execute(.quit)
            try await Task.sleep(for: .milliseconds(500))

            #expect(!client.isConnected, "A closed channel is not a connection")

            let error = try await #require(throws: QMPError.self) {
                _ = try await client.execute(.queryStatus)
            }
            guard case .notConnected = error else {
                Issue.record("Expected .notConnected, got \(error)")
                return
            }
        }
    }
}

// MARK: - Against a real QEMU

/// The out-of-band path end to end against a real QEMU.
///
/// The fake server accepts whatever it is sent, so it can only prove the shape
/// this library *intends* to send. QEMU is the authority on whether that shape
/// is accepted at all — and it rejects the plausible-looking alternative with
/// `QMP input member 'control' is unexpected`.
@Suite("QMP client against a real QEMU", .requiresQEMU, .hangBackstop)
struct RealQEMUQMPClientTests {

    @Test func outOfBandCommandIsAcceptedByARealQEMU() async throws {
        // The socket path is left to `QEMUProcess`, which puts it in a private
        // directory and keeps it inside `sun_path`'s ~104 bytes. A hand-built
        // `NSTemporaryDirectory() + UUID` path is about 100 of those on macOS —
        // close enough to the limit to be worth not doing.
        let process = QEMUProcess(
            qemuPath: try QEMUFixtures.requireSystemBinary(),
            logger: Logger(label: "test")
        )
        let socketPath = process.getQMPSocketPath()

        var config = QEMUConfiguration()
        config.memoryMB = 128
        try await process.start(with: config)

        let client = QMPClient(
            logger: Logger(label: "test"),
            requestTimeout: .seconds(5),
            connectTimeout: .seconds(5)
        )
        try await client.connectUnix(path: socketPath)

        #expect(client.negotiatedCapabilities == [.oob], "QEMU 11 offers oob")

        // `query-yank` is one of the four commands QEMU marks `allow-oob`. A reply at
        // all is the assertion: a malformed out-of-band request is answered with an
        // error, which `executeOutOfBand` throws.
        let instances = try await client.queryYank(outOfBand: true)
        #expect(!instances.isEmpty, "The monitor's own chardev is always yankable")

        // And an in-band command still works on the same connection afterwards.
        let status = try await client.queryStatus()
        #expect(status.status == "prelaunch")

        try await client.disconnect()
        await process.stop()
    }
}
