import NIOCore
import NIOPosix
import Testing
@testable import SwiftQEMU

/// The one-shot waiter every QMP wait is now built from.
///
/// These are the ordering hazards that used to be re-implemented per kind of wait
/// — greeting, reply, `DEVICE_DELETED` — and that could only be provoked
/// indirectly, by driving a whole client against a scripted server and hoping the
/// race landed the interesting way. Stated against the primitive they are
/// deterministic: the resolver simply runs before the waiter.
///
/// Every failure here is a wait that never comes back, so `.hangBackstop` bounds
/// them: a regression fails the run rather than stopping it.
@Suite("QMP waiter", .hangBackstop)
struct QMPWaiterTests {

    private var eventLoop: EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    /// A generous budget for waiters that are expected to be resolved by something
    /// other than their deadline. Long enough that a test failing to be prompt
    /// fails on its assertion instead of by timing out.
    private static let neverReachedTimeout: Duration = .seconds(60)

    // MARK: - Resolution before the waiter parks

    /// The whole point: a result that lands before anyone asks for it is latched,
    /// not dropped. This is the greeting-before-`waitForGreeting` case, which used
    /// to park the connect forever.
    @Test func resultLatchedBeforeAnyoneWaitsIsDeliveredImmediately() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.success(7))

        #expect(try await waiter.value == 7)
    }

    /// The same for a failure.
    @Test func errorLatchedBeforeAnyoneWaitsIsDeliveredImmediately() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.failure(QMPError.connectionLost))

        let error = try await #require(throws: QMPError.self) { try await waiter.value }
        guard case .connectionLost = error else {
            Issue.record("Expected .connectionLost, got \(error)")
            return
        }
    }

    /// Resolution from another task while a caller is parked resumes it.
    @Test func resolutionWhileParkedResumesTheWaiter() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiter.resolve(.success(9))

        #expect(try await waiting.value == 9)
    }

    /// The first resolution is the answer. Delivery, the deadline, cancellation and
    /// teardown all call `resolve` without knowing about each other, so anything
    /// else would make the outcome depend on how they interleave.
    @Test func firstResolutionWins() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.success(1))
        waiter.resolve(.failure(QMPError.connectionLost))
        waiter.resolve(.success(2))

        #expect(try await waiter.value == 1)
    }

    // MARK: - Deadlines

    /// A waiter nothing resolves fails on its deadline rather than parking.
    @Test func deadlineFailsAnUnresolvedWaiter() async throws {
        let waiter = QMPWaiter<Int>(timeout: .milliseconds(50), on: eventLoop)

        let error = try await #require(throws: QMPError.self) { try await waiter.value }
        guard case .timeout = error else {
            Issue.record("Expected .timeout, got \(error)")
            return
        }
    }

    /// A deadline that fires before its waiter has even parked is still just
    /// another resolver — but it is the ordering most likely to hang, because
    /// racing the deadline against the parking task used to leave nothing able to
    /// resume the caller. A zero budget makes that ordering certain; the rest are
    /// small enough to hit it often, and repeated so they do.
    ///
    /// The elapsed budget is the real assertion here, and is deliberately much
    /// tighter than `.hangBackstop` can express: 200 waits that each resolve
    /// promptly take milliseconds, and 200 that strand take forever.
    @Test(
        "A tiny budget fails promptly however it races the waiter",
        arguments: [Duration.zero, .nanoseconds(1), .microseconds(500), .milliseconds(1)]
    )
    func tinyDeadlinesNeverStrandTheWaiter(timeout: Duration) async throws {
        let started = ContinuousClock.now

        for _ in 0..<50 {
            let waiter = QMPWaiter<Int>(timeout: timeout, on: eventLoop)
            let error = try await #require(throws: QMPError.self) { try await waiter.value }
            guard case .timeout = error else {
                Issue.record("Expected .timeout, got \(error)")
                return
            }
        }

        #expect(started.duration(to: .now) < .seconds(5))
    }

    /// A deadline must not overrule a result that already arrived.
    @Test func deadlineDoesNotDisplaceAnEarlierResult() async throws {
        let waiter = QMPWaiter<Int>(timeout: .milliseconds(50), on: eventLoop)
        waiter.resolve(.success(3))
        // Well past the deadline: if resolving did not retire it, the value is
        // replaced by a timeout.
        try await Task.sleep(for: .milliseconds(150))

        #expect(try await waiter.value == 3)
    }

    // MARK: - Cancellation

    /// Cancelling a parked waiter comes back at once, not when the deadline fires.
    @Test func cancellationWhileParkedIsHonoured() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let started = ContinuousClock.now
        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()

        let error = try await #require(throws: QMPError.self) { try await waiting.value }
        guard case .cancelled = error else {
            Issue.record("Expected .cancelled, got \(error)")
            return
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    /// Cancellation landing *before* the waiter parks is the mirror image of the
    /// deadline hazard: the canceller finds nobody waiting. Latching makes that the
    /// same case as any other early resolution. Repeated, because an immediate
    /// `cancel()` usually beats the task to its first suspension.
    @Test func cancellationBeforeParkingIsNotLost() async throws {
        let started = ContinuousClock.now
        for _ in 0..<50 {
            let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
            let waiting = Task { try await waiter.value }
            waiting.cancel()

            let error = try await #require(throws: QMPError.self) { try await waiting.value }
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

    /// A cancelled waiter is resolved, so a result arriving afterwards has nowhere
    /// to go. That is what lets an inbound event skip past it to a live wait for
    /// the same device instead of being swallowed.
    @Test func aCancelledWaiterCountsAsResolved() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        #expect(!waiter.isResolved)

        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        _ = try? await waiting.value

        #expect(waiter.isResolved)
    }

    // MARK: - Misuse

    /// Two callers awaiting one waiter is a programming error, not a race. The
    /// second is refused rather than allowed to displace the first, which is what
    /// used to happen to the greeting: the new continuation overwrote the old one,
    /// abandoning it with nothing to resume it and no deadline to fail it.
    @Test func aSecondWaiterIsRefusedRatherThanDisplacingTheFirst() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let first = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))

        let error = try await #require(throws: QMPError.self) { try await waiter.value }
        guard case .invalidResponse = error else {
            Issue.record("Expected .invalidResponse, got \(error)")
            return
        }

        // And the first waiter is still intact.
        waiter.resolve(.success(5))
        #expect(try await first.value == 5)
    }
}
