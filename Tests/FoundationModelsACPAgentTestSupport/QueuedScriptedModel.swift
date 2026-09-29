import FoundationModelsACPAgent
import FoundationModelsRouter
import Synchronization

// MARK: - The queued scripted model
//
// A scripted model whose passes go through the Router generation queue of
// one pool entry (`generation-queue.md` of the Router, section 5.3). The
// Router gives the queue of the pool entry to the container through
// `LoadedLLMContainer.submitting(to:)`. Each backend of that container names
// the queue, so the session submits each generating call of the backend to
// it as one item. Two ACP sessions over one pool entry thus share one queue.
//
// Here one pass is one generating call of a scripted backend: one play of
// the script. The Router runs it as one item of the queue.

/// A hold that a scripted pass waits on until the test calls ``release()``.
///
/// The wait also ends when the task of the pass is cancelled. Then it throws
/// `CancellationError`. The wait is event-driven: a continuation, never a
/// timer. After ``release()``, each wait ends at once.
public final class ScriptedHold: Sendable, Equatable {
    /// The state of a hold: the passes that wait, or released.
    private enum State {
        /// The hold holds. The key of a waiter is its token.
        case holding(waiters: [Int: CheckedContinuation<Void, any Error>], nextToken: Int)

        /// The test called ``ScriptedHold/release()``.
        case released
    }

    /// The state, guarded because a wait, a cancel and the release can
    /// come from different tasks.
    private let state = Mutex(State.holding(waiters: [:], nextToken: 0))

    /// Creates a hold that holds.
    public init() {}

    /// Two holds are equal only when they are the same hold.
    ///
    /// - Parameters:
    ///   - lhs: A hold.
    ///   - rhs: Another hold.
    /// - Returns: `true` when `lhs` and `rhs` are the same object.
    public static func == (lhs: ScriptedHold, rhs: ScriptedHold) -> Bool {
        lhs === rhs
    }

    /// Ends each wait on this hold, and each later wait at once.
    public func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard case .holding(let waiters, _) = state else { return [] }
            state = .released
            return Array(waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Waits until the test calls ``release()``, or until the task is
    /// cancelled.
    ///
    /// - Throws: `CancellationError` when the task is cancelled first.
    func waitForRelease() async throws {
        let token = state.withLock { state -> Int? in
            guard case .holding(let waiters, let nextToken) = state else { return nil }
            state = .holding(waiters: waiters, nextToken: nextToken + 1)
            return nextToken
        }
        guard let token else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admit(continuation, token: token)
            }
        } onCancel: {
            removeWaiter(token: token)?.resume(throwing: CancellationError())
        }
    }

    /// Keeps `continuation` as a waiter, or resumes it at once when the
    /// hold is released or the task is cancelled.
    ///
    /// The cancel flag is read under the lock. A cancel that comes before
    /// the waiter is kept thus finds no waiter, and this read sees the flag.
    ///
    /// - Parameters:
    ///   - continuation: The continuation of the waiting pass.
    ///   - token: The token of the waiter.
    private func admit(_ continuation: CheckedContinuation<Void, any Error>, token: Int) {
        let outcome = state.withLock { state -> Result<Void, any Error>? in
            guard case .holding(var waiters, let nextToken) = state else { return .success(()) }
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            waiters[token] = continuation
            state = .holding(waiters: waiters, nextToken: nextToken)
            return nil
        }
        if let outcome {
            continuation.resume(with: outcome)
        }
    }

    /// Removes the waiter of `token`.
    ///
    /// - Parameter token: The token of the waiter.
    /// - Returns: The continuation of the waiter, or `nil` when the hold
    ///   has no waiter with that token.
    private func removeWaiter(token: Int) -> CheckedContinuation<Void, any Error>? {
        state.withLock { state in
            guard case .holding(var waiters, let nextToken) = state else { return nil }
            let removed = waiters.removeValue(forKey: token)
            state = .holding(waiters: waiters, nextToken: nextToken)
            return removed
        }
    }
}

/// Counts the passes of a queued scripted model: the passes that started,
/// the passes that run, and the maximum number that ran at the same time.
///
/// It also keeps the generation queue of the pool entry, so a test can see
/// the passes that wait for a queue place.
public final class ScriptedPassCounter: Sendable {
    /// The counts, and the queue of the pool entry.
    private struct Counts {
        /// The number of passes that started.
        var started = 0

        /// The number of passes that run now.
        var running = 0

        /// The maximum of ``running``.
        var maximumRunning = 0

        /// The queue that the Router gave to the model, or `nil` before the
        /// Router gave one.
        var queue: GenerationQueue?
    }

    /// The counts, guarded because passes start and end on many tasks.
    private let counts = Mutex(Counts())

    /// Creates a counter that counted nothing.
    public init() {}

    /// The number of passes that started.
    public var startedCount: Int {
        counts.withLock { $0.started }
    }

    /// The number of passes that run now.
    public var runningCount: Int {
        counts.withLock { $0.running }
    }

    /// The maximum number of passes that ran at the same time.
    public var maximumRunningCount: Int {
        counts.withLock { $0.maximumRunning }
    }

    /// The number of passes that wait for a place in the queue of the pool
    /// entry. `0` before the Router gave a queue.
    public var waitingCount: Int {
        get async {
            guard let queue = counts.withLock({ $0.queue }) else { return 0 }
            return await queue.waitingCount
        }
    }

    /// Keeps `queue`, the queue that the Router gave to the model.
    ///
    /// - Parameter queue: The generation queue of the pool entry.
    func adopt(queue: GenerationQueue) {
        counts.withLock { $0.queue = queue }
    }

    /// Counts the start of one pass.
    func passDidStart() {
        counts.withLock { counts in
            counts.started += 1
            counts.running += 1
            counts.maximumRunning = max(counts.maximumRunning, counts.running)
        }
    }

    /// Counts the end of one pass.
    func passDidEnd() {
        counts.withLock { $0.running -= 1 }
    }
}

extension StubModelLoader {
    /// Makes a loader whose LLM containers play `script`. The container of
    /// the `standard` slot, which each ACP session prompts, plays through the
    /// generation queue of its pool entry and counts each pass on
    /// `passCounter`.
    ///
    /// The `flash` slot is a different pool entry with a different queue.
    /// Its container runs each call directly and counts nothing, so the
    /// counter sees the passes and the queue of one pool entry only.
    ///
    /// - Parameters:
    ///   - script: The steps each pass plays.
    ///   - passCounter: The counter of the passes of the `standard` slot.
    /// - Returns: The loader to inject.
    public static func makeQueuedScriptedLoader(
        script: [ScriptedTurnStep], passCounter: ScriptedPassCounter
    ) -> StubModelLoader {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { slot in
            ScriptedLLMContainer(
                script: script, passCounter: slot == .standard ? passCounter : nil)
        }
        return loader
    }
}
