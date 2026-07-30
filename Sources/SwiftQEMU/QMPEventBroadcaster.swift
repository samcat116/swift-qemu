import NIOConcurrencyHelpers

/// Fan-out of QMP events to every live ``QMPClient/events(bufferSize:)``
/// subscriber.
///
/// Lock-guarded rather than actor-isolated, because subscribing must stay
/// synchronous: `events()` is called from ordinary code that then reads current
/// state, and making it `async` would open a window in which an event could slip
/// past between the call and the first iteration. The registration therefore
/// happens inside `AsyncStream`'s build closure, under this lock.
final class QMPEventBroadcaster: Sendable {
    private struct Storage {
        var subscribers: [UInt64: AsyncStream<QMPEvent>.Continuation] = [:]
        var nextToken: UInt64 = 0
        /// Latched when the connection ends, so a subscription taken out
        /// afterwards is handed a finished stream rather than a silent one.
        var isFinished = false
    }

    private let storage = NIOLockedValueBox(Storage())

    /// A new independent stream over this connection.
    func subscribe(bufferSize: Int) -> AsyncStream<QMPEvent> {
        AsyncStream(QMPEvent.self, bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            let token: UInt64? = storage.withLockedValue { storage in
                guard !storage.isFinished else { return nil }
                storage.nextToken += 1
                storage.subscribers[storage.nextToken] = continuation
                return storage.nextToken
            }

            guard let token else {
                // Already over: hand back a stream that is finished, rather than one
                // that will never produce anything and never end.
                continuation.finish()
                return
            }

            // Drops the registration when the consumer stops iterating (or its task
            // is cancelled), so an abandoned stream is not yielded to forever.
            continuation.onTermination = { [weak self] _ in
                self?.storage.withLockedValue { _ = $0.subscribers.removeValue(forKey: token) }
            }
        }
    }

    /// Deliver one event to every live subscriber.
    ///
    /// Called from the loop that also delivers command replies, so it must not
    /// block: `bufferingNewest` makes `yield` non-blocking, discarding a slow
    /// subscriber's *oldest* event rather than applying backpressure to QEMU's
    /// socket and stalling every other waiter with it.
    func broadcast(_ event: QMPEvent) {
        let subscribers = storage.withLockedValue { Array($0.subscribers.values) }
        for subscriber in subscribers {
            subscriber.yield(event)
        }
    }

    /// End every stream, because a stream belongs to one connection: a `for await`
    /// over it must complete when that connection does rather than park on a
    /// channel nobody owns.
    func finish() {
        let subscribers = storage.withLockedValue { storage -> [AsyncStream<QMPEvent>.Continuation] in
            storage.isFinished = true
            let subscribers = Array(storage.subscribers.values)
            storage.subscribers.removeAll()
            return subscribers
        }
        // Finished outside the lock: `finish()` invokes each `onTermination`, which
        // takes this same non-recursive lock.
        for subscriber in subscribers {
            subscriber.finish()
        }
    }
}
