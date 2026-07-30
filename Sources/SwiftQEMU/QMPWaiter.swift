import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// A one-shot, deadline-bounded slot for a value that is produced somewhere other
/// than the task waiting for it.
///
/// The QMP channel handler used to carry three variations on the same problem —
/// the reply landing before the caller parks, the deadline firing before the
/// caller parks, and the cancellation arriving before the caller parks — and each
/// one had its own latch, its own `cancelled` flag, and its own "install the
/// waiter first, arm the deadline second" ordering rule, repeated once per kind of
/// wait. They are all the same problem: a resolver that gets there before the
/// waiter finds nothing to resume, and the waiter then parks behind it forever.
///
/// Latching the outcome collapses all of it into one rule:
///
/// **The first resolution wins, and a caller that parks afterwards resumes
/// immediately with whatever was latched.**
///
/// Delivery, the deadline, cancellation and connection loss are then just four
/// callers of ``resolve(_:)``, in any order, from any thread — so there is no
/// ordering left to get wrong, and none of them needs to know whether anyone is
/// waiting yet.
final class QMPWaiter<Value: Sendable>: Sendable {
    private enum State {
        /// Unresolved, with nobody waiting.
        case pending
        /// Resolved before anyone waited. The next `value` hands this straight
        /// over rather than parking.
        case latched(Result<Value, QMPError>)
        /// A caller is parked on this continuation.
        ///
        /// Untyped, unavoidably: `withCheckedThrowingContinuation` hands out a
        /// `CheckedContinuation<_, any Error>` and is not generic over the error
        /// type. Only the resume crosses back out of this domain, and `value`
        /// narrows it again on the way to the caller.
        case waiting(CheckedContinuation<Value, any Error>)
        /// Resolved *and* delivered.
        case done
    }

    private struct Storage {
        var state: State = .pending
        /// Cancelled as soon as the waiter resolves, so a timer never outlives
        /// the thing it bounds. A `Task.detached` sleeping out its whole budget
        /// per waiter is what this replaces.
        var deadline: Scheduled<Void>?

        /// Remove and return the deadline, for the caller to cancel once the lock
        /// is dropped.
        mutating func takeDeadline() -> Scheduled<Void>? {
            defer { deadline = nil }
            return deadline
        }
    }

    private let storage = NIOLockedValueBox(Storage())

    /// - Parameters:
    ///   - timeout: The budget. A non-positive budget resolves the waiter as
    ///     already timed out — zero must fail immediately, not never.
    ///   - eventLoop: The loop the deadline runs on. Deliberately an event-loop
    ///     timer rather than a task: it cannot inherit the caller's cancellation
    ///     (a deadline that did, and so skipped firing, used to strand its
    ///     waiter), it costs no thread, and it is cancellable.
    ///   - timeoutError: What the deadline resolves the waiter with.
    init(
        timeout: Duration,
        on eventLoop: EventLoop,
        timeoutError: QMPError = .timeout
    ) {
        guard timeout > .zero else {
            storage.withLockedValue { $0.state = .latched(.failure(timeoutError)) }
            return
        }
        // `TimeAmount(_:)` truncates to nanoseconds and clamps at `Int64.max`, so
        // an absurd budget cannot overflow the conversion; the bound is a few
        // centuries, which is indistinguishable from "no deadline".
        let deadline = eventLoop.scheduleTask(in: TimeAmount(timeout)) { [weak self] () -> Void in
            self?.expire(with: timeoutError)
        }
        attach(deadline)
    }

    /// Resolve the waiter. The first caller wins; later ones are no-ops, which is
    /// what lets delivery, timeout, cancellation and teardown all call this
    /// blindly.
    func resolve(_ result: Result<Value, QMPError>) {
        let (waiter, deadline) = storage.withLockedValue {
            storage -> (CheckedContinuation<Value, any Error>?, Scheduled<Void>?) in
            switch storage.state {
            case .pending:
                storage.state = .latched(result)
                return (nil, storage.takeDeadline())
            case .waiting(let continuation):
                storage.state = .done
                return (continuation, storage.takeDeadline())
            case .latched, .done:
                return (nil, nil)
            }
        }
        deadline?.cancel()
        // Resumed after the lock is dropped, so this never calls out while held.
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    /// The resolved value, waiting for it if it has not arrived yet.
    ///
    /// Exactly one caller may await a given waiter; a second is a programming
    /// error, not a race, and is reported rather than allowed to displace the
    /// first.
    var value: Value {
        get async throws(QMPError) {
            // `resolve` only ever takes a `QMPError`, so this narrowing cannot
            // lose anything — it is here because the continuation and
            // `withTaskCancellationHandler` both deal in `any Error`. Nothing
            // actually reaches `QMPError.underlying(_:)`; having it is what keeps
            // the mapping total without inventing a case for an error we did not
            // throw.
            do {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Value, any Error>) in
                        let (immediate, deadline) = storage.withLockedValue {
                            storage -> (Result<Value, QMPError>?, Scheduled<Void>?) in
                            switch storage.state {
                            case .pending:
                                storage.state = .waiting(continuation)
                                return (nil, nil)
                            case .latched(let result):
                                storage.state = .done
                                return (result, storage.takeDeadline())
                            case .waiting, .done:
                                return (.failure(QMPError.invalidResponse), nil)
                            }
                        }
                        deadline?.cancel()
                        if let immediate {
                            continuation.resume(with: immediate.mapError { $0 as any Error })
                        }
                    }
                } onCancel: {
                    // Just another resolver. Whether this lands before or after the
                    // continuation is installed no longer matters.
                    //
                    // `.cancelled` rather than `CancellationError`: `resolve` is
                    // typed to this library's error, which a typed-throws API
                    // cannot smuggle a foreign error past.
                    resolve(.failure(.cancelled))
                }
            } catch {
                throw QMPError.wrapping(error)
            }
        }
    }

    /// Whether this waiter has been resolved, however that happened.
    ///
    /// Used to route an inbound event past a waiter that is already finished with:
    /// letting a cancelled or timed-out waiter absorb the event would hide it from
    /// a live wait for the same thing.
    var isResolved: Bool {
        storage.withLockedValue { storage in
            switch storage.state {
            case .pending, .waiting: return false
            case .latched, .done: return true
            }
        }
    }

    /// The deadline is firing, so there is nothing left to cancel — drop the
    /// reference before resolving so `resolve` does not try.
    private func expire(with error: QMPError) {
        storage.withLockedValue { _ = $0.takeDeadline() }
        resolve(.failure(error))
    }

    /// Hand a freshly scheduled deadline to the waiter it bounds, or cancel it if
    /// the waiter resolved while it was being scheduled. Unlike the code this
    /// replaces, no correctness rests on this: a deadline that arrives late finds
    /// the waiter resolved and does nothing. It is here so a pending timer does not
    /// keep this object alive until it fires.
    private func attach(_ deadline: Scheduled<Void>) {
        let alreadyResolved = storage.withLockedValue { storage -> Bool in
            switch storage.state {
            case .pending, .waiting:
                storage.deadline = deadline
                return false
            case .latched, .done:
                return true
            }
        }
        if alreadyResolved {
            deadline.cancel()
        }
    }
}

extension QMPWaiter where Value == Void {
    /// Convenience for the waiters whose only payload is "it happened".
    func resolve() {
        resolve(.success(()))
    }
}
