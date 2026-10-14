import Synchronization

/// The error of a wait for a condition that ended before the condition came:
/// the task of the wait was cancelled.
///
/// A test has no time limit. A wait for a condition that never comes thus
/// ends only when its task is cancelled, and then it throws this error.
public struct ConditionWaitCancelled: Error, CustomStringConvertible {
    /// The name of the condition that did not come.
    public let condition: String

    /// Makes the error of a cancelled wait.
    ///
    /// - Parameter condition: The name of the condition that did not come.
    public init(condition: String) {
        self.condition = condition
    }

    /// The failure message. It names the condition that did not come.
    public var description: String {
        "the wait for \(condition) was cancelled before the condition came"
    }
}

/// A value that a test changes, and on which a test can wait until a
/// condition over the value is true.
///
/// The value and the waits are under one lock, and not in an actor: the
/// cancellation handler of a wait runs synchronously, and it must remove
/// its wait at once. Each wait resumes exactly one time: by the change that
/// makes its condition true, or by the cancellation of its task. The one
/// that removes the wait from the lock resumes it.
public final class WatchedValue<Value: Sendable>: Sendable {
    /// One suspended wait.
    private struct Wait {
        /// Tells if the condition of the wait is true for a value.
        let isMet: @Sendable (Value) -> Bool

        /// The continuation of the wait.
        let continuation: CheckedContinuation<Value, any Error>
    }

    /// The value and its waits.
    private struct State {
        /// The value of now.
        var value: Value

        /// The suspended waits. The key of a wait is its token.
        var waits: [Int: Wait] = [:]

        /// The token of the next wait.
        var nextToken = 0

        /// The tests that wait until a count of waits is kept, with that
        /// count.
        var keptWatchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    /// The state, under a lock because a change, a wait and a cancellation
    /// can come from different tasks.
    private let state: Mutex<State>

    /// Makes a watched value.
    ///
    /// - Parameter initialValue: The value before the first change.
    public init(_ initialValue: Value) {
        state = Mutex(State(value: initialValue))
    }

    /// The value of now.
    public var value: Value {
        state.withLock { $0.value }
    }

    /// The count of waits that are kept now: each wait that checked its
    /// condition, found it false, and is suspended until a change or a
    /// cancellation resumes it. A test reads this count to know that a wait
    /// is kept before it cancels the task of the wait.
    public var keptWaitCount: Int {
        state.withLock { $0.waits.count }
    }

    /// Waits until at least `count` waits are kept: each one checked its
    /// condition, found it false, and is suspended. Each kept wait checks
    /// the count again, so this wait uses no clock and no poll.
    ///
    /// - Parameter count: The number of kept waits to wait for.
    public func waitUntilKept(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state -> Bool in
                guard state.waits.count < count else { return true }
                state.keptWatchers.append((count, continuation))
                return false
            }
            if reached {
                continuation.resume()
            }
        }
    }

    /// Changes the value, and resumes each wait whose condition is now true.
    ///
    /// - Parameter change: The change to the value.
    public func update(_ change: (inout Value) -> Void) {
        let (value, metWaits) = state.withLock { state -> (Value, [Wait]) in
            change(&state.value)
            let value = state.value
            let metTokens = state.waits.filter { $0.value.isMet(value) }.map(\.key)
            return (value, metTokens.compactMap { state.waits.removeValue(forKey: $0) })
        }
        for wait in metWaits {
            wait.continuation.resume(returning: value)
        }
    }

    /// Waits until `isMet` is true for the value. Returns at once when it is
    /// true now.
    ///
    /// - Parameters:
    ///   - condition: The name of the condition. The error of a cancelled
    ///     wait gives this name.
    ///   - isMet: Tells if the condition is true for a value.
    /// - Returns: The first value for which `isMet` is true.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
    ///   cancelled before the condition comes.
    public func wait(
        for condition: String, until isMet: @escaping @Sendable (Value) -> Bool
    ) async throws -> Value {
        let token = state.withLock { state in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admit(Wait(isMet: isMet, continuation: continuation), token: token, condition: condition)
            }
        } onCancel: {
            let wait = state.withLock { $0.waits.removeValue(forKey: token) }
            wait?.continuation.resume(throwing: ConditionWaitCancelled(condition: condition))
        }
    }

    /// Keeps `wait` as a suspended wait, or resumes it at once when its
    /// condition is true or its task is cancelled.
    ///
    /// The cancel flag is read under the lock. A cancellation that comes
    /// before the wait is kept thus finds no wait, and this read sees the
    /// flag.
    ///
    /// - Parameters:
    ///   - wait: The wait to keep.
    ///   - token: The token of the wait.
    ///   - condition: The name of the condition of the wait.
    private func admit(_ wait: Wait, token: Int, condition: String) {
        let outcome = state.withLock { state -> Result<Value, any Error>? in
            if wait.isMet(state.value) {
                return .success(state.value)
            }
            if Task.isCancelled {
                return .failure(ConditionWaitCancelled(condition: condition))
            }
            state.waits[token] = wait
            return nil
        }
        if let outcome {
            wait.continuation.resume(with: outcome)
            return
        }
        let reached = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let kept = state.waits.count
            let reached = state.keptWatchers.filter { $0.count <= kept }.map(\.continuation)
            state.keptWatchers.removeAll { $0.count <= kept }
            return reached
        }
        for watcher in reached {
            watcher.resume()
        }
    }
}
