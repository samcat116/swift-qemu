import XCTest
import NIOCore
import NIOPosix
@testable import SwiftQEMU

/// The one-shot waiter every QMP wait is now built from.
///
/// These are the ordering hazards that used to be re-implemented per kind of wait
/// — greeting, reply, `DEVICE_DELETED` — and that could only be provoked
/// indirectly, by driving a whole client against a scripted server and hoping the
/// race landed the interesting way. Stated against the primitive they are
/// deterministic: the resolver simply runs before the waiter.
final class QMPWaiterTests: XCTestCase {

    private var eventLoop: EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    /// A generous budget for waiters that are expected to be resolved by something
    /// other than their deadline. Long enough that a test failing to be prompt
    /// fails on its assertion instead of by timing out.
    private static let neverReachedTimeout: TimeInterval = 60

    // MARK: - Resolution before the waiter parks

    /// The whole point: a result that lands before anyone asks for it is latched,
    /// not dropped. This is the greeting-before-`waitForGreeting` case, which used
    /// to park the connect forever.
    func testResultLatchedBeforeAnyoneWaitsIsDeliveredImmediately() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.success(7))

        let value = try await waiter.value
        XCTAssertEqual(value, 7)
    }

    /// The same for a failure.
    func testErrorLatchedBeforeAnyoneWaitsIsDeliveredImmediately() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.failure(QMPError.connectionLost))

        do {
            _ = try await waiter.value
            XCTFail("Expected the latched failure")
        } catch let error as QMPError {
            guard case .connectionLost = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
        }
    }

    /// Resolution from another task while a caller is parked resumes it.
    func testResolutionWhileParkedResumesTheWaiter() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiter.resolve(.success(9))

        let value = try await waiting.value
        XCTAssertEqual(value, 9)
    }

    /// The first resolution is the answer. Delivery, the deadline, cancellation and
    /// teardown all call `resolve` without knowing about each other, so anything
    /// else would make the outcome depend on how they interleave.
    func testFirstResolutionWins() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        waiter.resolve(.success(1))
        waiter.resolve(.failure(QMPError.connectionLost))
        waiter.resolve(.success(2))

        let value = try await waiter.value
        XCTAssertEqual(value, 1)
    }

    // MARK: - Deadlines

    /// A waiter nothing resolves fails on its deadline rather than parking.
    func testDeadlineFailsAnUnresolvedWaiter() async throws {
        let waiter = QMPWaiter<Int>(timeout: 0.05, on: eventLoop)

        do {
            _ = try await waiter.value
            XCTFail("Expected the deadline to fire")
        } catch let error as QMPError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    /// A zero budget must fail immediately, not never. Racing the deadline against
    /// the parking task used to make this the ordering most likely to hang.
    func testZeroTimeoutFailsImmediately() async throws {
        let waiter = QMPWaiter<Int>(timeout: 0, on: eventLoop)

        let started = ContinuousClock.now
        do {
            _ = try await waiter.value
            XCTFail("Expected a zero budget to fail")
        } catch let error as QMPError {
            guard case .timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    /// A deadline that fires before its waiter is even constructed with one is
    /// still just another resolver, and repeated tiny budgets are how that
    /// ordering gets hit.
    func testTinyDeadlinesNeverStrandTheWaiter() async throws {
        for _ in 0..<50 {
            let waiter = QMPWaiter<Int>(timeout: 0.001, on: eventLoop)
            do {
                _ = try await waiter.value
                XCTFail("Expected the deadline to fire")
            } catch is QMPError {
                // Expected.
            }
        }
    }

    /// A deadline must not overrule a result that already arrived.
    func testDeadlineDoesNotDisplaceAnEarlierResult() async throws {
        let waiter = QMPWaiter<Int>(timeout: 0.05, on: eventLoop)
        waiter.resolve(.success(3))
        // Well past the deadline: if resolving did not retire it, the value is
        // replaced by a timeout.
        try await Task.sleep(for: .milliseconds(150))

        let value = try await waiter.value
        XCTAssertEqual(value, 3)
    }

    // MARK: - Cancellation

    /// Cancelling a parked waiter comes back at once, not when the deadline fires.
    func testCancellationWhileParkedIsHonoured() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let started = ContinuousClock.now
        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()

        do {
            _ = try await waiting.value
            XCTFail("Expected the cancelled wait to throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }

    /// Cancellation landing *before* the waiter parks is the mirror image of the
    /// deadline hazard: the canceller finds nobody waiting. Latching makes that the
    /// same case as any other early resolution. Repeated, because an immediate
    /// `cancel()` usually beats the task to its first suspension.
    func testCancellationBeforeParkingIsNotLost() async throws {
        let started = ContinuousClock.now
        for _ in 0..<50 {
            let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
            let waiting = Task { try await waiter.value }
            waiting.cancel()

            do {
                _ = try await waiting.value
                XCTFail("Expected the cancelled wait to throw")
            } catch is CancellationError {
                // Expected.
            }
        }
        XCTAssertLessThan(
            started.duration(to: .now), .seconds(5),
            "Cancellation must be honoured however it races the waiter")
    }

    /// A cancelled waiter is resolved, so a result arriving afterwards has nowhere
    /// to go. That is what lets an inbound event skip past it to a live wait for
    /// the same device instead of being swallowed.
    func testACancelledWaiterCountsAsResolved() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)
        XCTAssertFalse(waiter.isResolved)

        let waiting = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        _ = try? await waiting.value

        XCTAssertTrue(waiter.isResolved)
    }

    // MARK: - Misuse

    /// Two callers awaiting one waiter is a programming error, not a race. The
    /// second is refused rather than allowed to displace the first, which is what
    /// used to happen to the greeting: the new continuation overwrote the old one,
    /// abandoning it with nothing to resume it and no deadline to fail it.
    func testASecondWaiterIsRefusedRatherThanDisplacingTheFirst() async throws {
        let waiter = QMPWaiter<Int>(timeout: Self.neverReachedTimeout, on: eventLoop)

        let first = Task { try await waiter.value }
        try await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await waiter.value
            XCTFail("Expected the second wait to be refused")
        } catch let error as QMPError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
        }

        // And the first waiter is still intact.
        waiter.resolve(.success(5))
        let delivered = try await first.value
        XCTAssertEqual(delivered, 5)
    }
}
