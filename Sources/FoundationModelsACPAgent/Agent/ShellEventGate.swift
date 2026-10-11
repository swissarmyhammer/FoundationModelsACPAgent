import Synchronization

/// The one-slot handoff between the forwarder of ``TerminalStream`` and its
/// consumer loop (task ^9xk3xf4).
///
/// The forwarder reads one event from the host-owned shell output stream,
/// gives it to the loop, and then waits here until the loop handled it. Only
/// then does the forwarder read the next event. Thus the terminal stream reads
/// at most one event ahead of what it sent. The upstream stream gives back the
/// budget of an event only when a reader takes it, so its pending-byte budget
/// stays in force: a slow client makes the upstream budget fill, and the
/// upstream replaces the excess with one `gap` event.
///
/// The loop calls ``pass()`` after it handled each event. A ``pass()`` that
/// comes before the forwarder waits is kept, so no turn is lost. ``close()``
/// ends each wait at once, and each later wait returns `false`.
final class ShellEventGate: Sendable {
    /// The turns and the waiting forwarder, under one lock.
    private struct State {
        /// The turns that the loop gave before the forwarder waited.
        var turns = 0

        /// The forwarder while it waits for a turn.
        var waiter: CheckedContinuation<Bool, Never>?

        /// Whether the loop ended.
        var isClosed = false
    }

    /// The state of the gate.
    private let state = Mutex(State())

    /// Waits until the loop handled the event that the forwarder gave it.
    ///
    /// - Returns: `true` when the forwarder can read the next event, and
    ///   `false` when the loop ended.
    func waitForTurn() async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = state.withLock { state -> Bool? in
                if state.isClosed {
                    return false
                }
                if state.turns > 0 {
                    state.turns -= 1
                    return true
                }
                state.waiter = continuation
                return nil
            }
            if let answer {
                continuation.resume(returning: answer)
            }
        }
    }

    /// Gives the forwarder its turn: the loop handled the last event.
    func pass() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard let waiter = state.waiter else {
                state.turns += 1
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: true)
    }

    /// Ends each wait of the forwarder: the loop ended.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.isClosed = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: false)
    }
}
