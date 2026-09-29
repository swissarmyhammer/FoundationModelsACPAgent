import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The consumer of a prompt's `session/update` payloads. The production
/// sink posts through the bound `AgentSideConnection`; a test sink
/// records the sequence.
typealias SessionUpdateSink = @Sendable (SessionUpdate) async -> Void

extension AgentSideConnection {
    /// Sends one `session/update` for `sessionId`. A send failure is
    /// logged and dropped: the prompt already returned `{}` (plan.md §8.1),
    /// so no prompt error can become a JSON-RPC error, and a closed
    /// connection has no reader to correct.
    ///
    /// - Parameters:
    ///   - update: The update payload.
    ///   - sessionId: The session the update belongs to.
    func post(_ update: SessionUpdate, in sessionId: SessionId) async {
        do {
            try await sessionUpdate(
                UpdateSessionNotification(sessionId: sessionId, update: update))
        } catch {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A session/update send failed.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
        }
    }
}

/// The prompt-state owner of one session (plan.md §8.2).
///
/// It owns the `state_update` transitions of the session's one running
/// prompt: `running` at the prompt start, `requires_action` while the
/// prompt is blocked on the human, back to `running` at the answer, and
/// `idle` with a stop reason at the end.
/// It also records a `session/cancel` request, so the prompt ends as
/// `cancelled` even when the cancelled model work runs to completion
/// (plan.md §8.6).
actor PromptStateOwner {
    /// The sink every state update goes to.
    private let send: SessionUpdateSink

    /// Whether `session/cancel` asked this prompt to stop.
    private(set) var cancelRequested = false

    /// Whether ``promptDidStart()`` already sent `running` for the prompt.
    private var didStart = false

    /// The stop reason that the `idle` terminator carried, or `nil` while the
    /// prompt runs: a value tells that ``promptDidEnd(reason:)`` sent the
    /// terminator. `session/close` reads it, so the close response follows
    /// the terminator (plan.md §10.1), and the prompt span reads it when it
    /// ends.
    private(set) var stopReason: StopReason?

    /// The waiters suspended in ``waitForPromptEnd()`` until the terminator
    /// goes out.
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates the owner over `send`.
    ///
    /// - Parameter send: The sink every state update goes to.
    init(send: @escaping SessionUpdateSink) {
        self.send = send
    }

    /// Sends `state_update: running` one time for the prompt. The
    /// projection calls it at each Router `submissionStarted` event
    /// (plan.md §8.4), and a prompt can make more than one submission, so
    /// a later call sends nothing.
    func promptDidStart() async {
        guard !didStart else { return }
        didStart = true
        await sendRunning()
    }

    /// Runs `body` as a wait on the human (plan.md §8.2): sends
    /// `requires_action`, runs the body, and returns to `running` when the
    /// body ends — with a value or with an error.
    ///
    /// The wait is an ACP state only. Router has no call for it: its
    /// generation queue gives a wait for a person no release of the model.
    ///
    /// - Parameter body: The wait on the human.
    /// - Returns: The body's value.
    /// - Throws: The body's error, after the state returns to `running`.
    func awaitingUser<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await send(.stateUpdate(.requiresAction(RequiresActionStateUpdate())))
        do {
            let value = try await body()
            await sendRunning()
            return value
        } catch {
            await sendRunning()
            throw error
        }
    }

    /// Sends the one `state_update: idle` that ends the prompt, with its
    /// stop reason (plan.md §8.1).
    ///
    /// - Parameter reason: Why the prompt stopped.
    func promptDidEnd(reason: StopReason) async {
        await send(.stateUpdate(.idle(IdleStateUpdate(stopReason: reason))))
        stopReason = reason
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the prompt's `idle` terminator has gone out. A close
    /// during an active prompt awaits it, so the client learns the prompt
    /// ended before the close response (plan.md §10.1). It returns at once
    /// when the terminator already went out.
    func waitForPromptEnd() async {
        guard stopReason == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            endWaiters.append(continuation)
        }
    }

    /// Records that `session/cancel` asked this prompt to stop. The
    /// prompt reads it at the end, because a cancelled prompt does not
    /// always throw (plan.md §8.6).
    func noteCancelRequested() {
        cancelRequested = true
    }

    /// Sends `state_update: running`.
    private func sendRunning() async {
        await send(.stateUpdate(.running(RunningStateUpdate())))
    }
}
