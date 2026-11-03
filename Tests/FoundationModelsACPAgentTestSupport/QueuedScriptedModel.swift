import FoundationModelsACPAgent
import FoundationModelsRouter
import Synchronization

// MARK: - The queued scripted model
//
// A scripted model whose passes take one model lock of one pool entry, as
// the passes of an MLX model take the FIFO lock of its
// `SerialAccessContainer` (`PooledGeneration` of FoundationModelsExtras).
// The Router has no queue of its own. Two ACP sessions over one pool entry
// thus share one lock, and the model plays one pass at a time.
//
// Here one pass is one generating call of a scripted backend: one play of
// the script. A pass holds the lock while it plays, and it leaves the lock
// for each tool body, as a real model does: no tool body runs under the lock.

/// Counts the passes of a queued scripted model: the passes that started,
/// the passes that hold the model, the maximum number that held it at the
/// same time, and the passes that wait for it.
///
/// A test waits for a count with ``wait(for:until:)``: each change of the
/// counts resumes the waits whose condition is now true, so the wait uses
/// no clock and no poll.
///
/// The counter also owns the model lock of the pool entry. The lock is
/// FIFO, and a cancel ends a wait for it at once.
public final class ScriptedPassCounter: Sendable {
    /// The counts of the passes at one time.
    public struct Counts: Sendable {
        /// The number of passes that started: that took the model for the
        /// first time.
        public var started = 0

        /// The number of passes that hold the model now.
        public var running = 0

        /// The maximum of ``running``.
        public var maximumRunning = 0

        /// The number of passes that wait for the model now.
        public var waiting = 0
    }

    /// The state of the model lock.
    private struct LockState {
        /// Whether a pass holds the model.
        var isHeld = false

        /// The passes that wait for the model, in arrival order, with the
        /// token of each wait.
        var waiters: [(token: Int, continuation: CheckedContinuation<Void, any Error>)] = []

        /// The token of the next wait.
        var nextToken = 0
    }

    /// The counts, with their waits. Passes start and end on many tasks.
    private let counts = WatchedValue(Counts())

    /// The model lock, guarded because a take, a cancel and a release can
    /// come from different tasks.
    private let lock = Mutex(LockState())

    /// Creates a counter that counted nothing.
    public init() {}

    /// The number of passes that started.
    public var startedCount: Int {
        counts.value.started
    }

    /// The number of passes that hold the model now.
    public var runningCount: Int {
        counts.value.running
    }

    /// The maximum number of passes that held the model at the same time.
    public var maximumRunningCount: Int {
        counts.value.maximumRunning
    }

    /// The number of passes that wait for the model now.
    public var waitingCount: Int {
        counts.value.waiting
    }

    /// Waits until `isMet` is true for the counts. Returns at once when it
    /// is true now.
    ///
    /// - Parameters:
    ///   - condition: The name of the condition, for the error of a
    ///     cancelled wait.
    ///   - isMet: Tells if the condition is true for the counts.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
    ///   cancelled before the condition comes.
    public func wait(for condition: String, until isMet: @escaping @Sendable (Counts) -> Bool) async throws {
        _ = try await counts.wait(for: condition, until: isMet)
    }

    /// Starts one pass: waits for the model, takes it, and counts the start.
    ///
    /// - Returns: The turn of the pass, which holds the model.
    /// - Throws: `CancellationError` when the task is cancelled while the
    ///   pass waits for the model.
    func startPass() async throws -> ScriptedModelTurn {
        try await takeModel()
        counts.update { $0.started += 1 }
        return ScriptedModelTurn(counter: self)
    }

    /// Waits for the model, and takes it. A pass that comes when the model
    /// is free takes it at once. Else the pass waits behind the passes that
    /// came before it.
    ///
    /// - Throws: `CancellationError` when the task is cancelled first. Then
    ///   the pass holds no model.
    func takeModel() async throws {
        let token = lock.withLock { state -> Int? in
            guard state.isHeld else {
                state.isHeld = true
                return nil
            }
            let token = state.nextToken
            state.nextToken += 1
            return token
        }
        if let token {
            counts.update { $0.waiting += 1 }
            defer { counts.update { $0.waiting -= 1 } }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    admit(continuation, token: token)
                }
            } onCancel: {
                removeWaiter(token: token)?.resume(throwing: CancellationError())
            }
        }
        counts.update { counts in
            counts.running += 1
            counts.maximumRunning = max(counts.maximumRunning, counts.running)
        }
    }

    /// Leaves the model. The first waiting pass, if there is one, gets it.
    func leaveModel() {
        counts.update { $0.running -= 1 }
        let next = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.waiters.isEmpty else {
                state.isHeld = false
                return nil
            }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }

    /// Keeps `continuation` as a waiter, or resumes it at once when the
    /// model became free or the task is cancelled.
    ///
    /// The cancel flag is read under the lock. A cancel that comes before
    /// the waiter is kept thus finds no waiter, and this read sees the flag.
    ///
    /// - Parameters:
    ///   - continuation: The continuation of the waiting pass.
    ///   - token: The token of the waiter.
    private func admit(_ continuation: CheckedContinuation<Void, any Error>, token: Int) {
        let outcome = lock.withLock { state -> Result<Void, any Error>? in
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            guard state.isHeld else {
                state.isHeld = true
                return .success(())
            }
            state.waiters.append((token: token, continuation: continuation))
            return nil
        }
        if let outcome {
            continuation.resume(with: outcome)
        }
    }

    /// Removes the waiter of `token`.
    ///
    /// - Parameter token: The token of the waiter.
    /// - Returns: The continuation of the waiter, or `nil` when no pass
    ///   waits with that token: the pass got the model already.
    private func removeWaiter(token: Int) -> CheckedContinuation<Void, any Error>? {
        lock.withLock { state in
            guard let index = state.waiters.firstIndex(where: { $0.token == token }) else { return nil }
            return state.waiters.remove(at: index).continuation
        }
    }
}

/// The hold of the model by one pass of a queued scripted model.
///
/// The pass leaves the model for each tool body and takes it again after
/// the body. The turn knows if the pass holds the model now, so ``end()``
/// leaves the model only when the pass holds it.
final class ScriptedModelTurn: ScriptedPassTurn {
    /// The counter that owns the model lock.
    private let counter: ScriptedPassCounter

    /// Whether the pass holds the model now.
    private let isHeld = Mutex(true)

    /// Makes the turn of a pass that holds the model.
    ///
    /// - Parameter counter: The counter that owns the model lock.
    init(counter: ScriptedPassCounter) {
        self.counter = counter
    }

    /// Leaves the model before a tool body.
    func leave() {
        let wasHeld = isHeld.withLock { held -> Bool in
            let wasHeld = held
            held = false
            return wasHeld
        }
        guard wasHeld else { return }
        counter.leaveModel()
    }

    /// Waits for the model after a tool body, and takes it.
    ///
    /// - Throws: `CancellationError` when the task is cancelled first.
    func takeAgain() async throws {
        guard !isHeld.withLock({ $0 }) else { return }
        try await counter.takeModel()
        isHeld.withLock { $0 = true }
    }

    /// Ends the pass: leaves the model when the pass holds it.
    func end() {
        leave()
    }
}

extension StubModelLoader {
    /// Makes a loader whose LLM containers play `script`. Each pass of the
    /// container of the `standard` slot, which each ACP session prompts,
    /// takes the model lock of `passCounter`, and the counter counts it.
    ///
    /// The `flash` slot is a different pool entry. Its container takes no
    /// lock and counts nothing, so the counter sees the passes of one pool
    /// entry only.
    ///
    /// - Parameters:
    ///   - script: The steps each pass plays.
    ///   - passCounter: The counter of the passes of the `standard` slot.
    /// - Returns: The loader to inject.
    public static func makeQueuedScriptedLoader(
        script: [ScriptedPassStep], passCounter: ScriptedPassCounter
    ) -> StubModelLoader {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { slot in
            ScriptedLLMContainer(
                script: script, passCounter: slot == .standard ? passCounter : nil)
        }
        return loader
    }
}
