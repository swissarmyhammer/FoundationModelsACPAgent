import FoundationModelsACP
import FoundationModelsRouter
import os

/// The logger of the turn: the state machine, the update sends, and the
/// ignored events.
let turnLogger = Logger(subsystem: RoutedACPAgent.implementation.name, category: "PromptTurn")

/// The consumer of a turn's `session/update` payloads. The production
/// sink posts through the bound `AgentSideConnection`; a test sink
/// records the sequence.
typealias SessionUpdateSink = @Sendable (SessionUpdate) async -> Void

extension AgentSideConnection {
    /// Sends one `session/update` for `sessionId`. A send failure is
    /// logged and dropped: the turn already returned `{}` (plan.md §8.1),
    /// so no turn error can become a JSON-RPC error, and a closed
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
            turnLogger.warning(
                "session/update send failed for session \(sessionId.rawValue, privacy: .public): \(error, privacy: .public)"
            )
        }
    }
}

/// The turn-state owner of one session (plan.md §8.2).
///
/// It owns the `state_update` transitions of the session's one running
/// turn: `running` at the turn start, `requires_action` paired with
/// Router's `awaitingUser` while the turn is blocked on the human, back
/// to `running` at the answer, and `idle` with a stop reason at the end.
/// It also records a `session/cancel` request, so the turn ends as
/// `cancelled` even when the cancelled model work runs to completion
/// (plan.md §8.6).
actor TurnStateOwner {
    /// The sink every state update goes to.
    private let send: SessionUpdateSink

    /// Whether `session/cancel` asked this turn to stop.
    private(set) var cancelRequested = false

    /// Creates the owner over `send`.
    ///
    /// - Parameter send: The sink every state update goes to.
    init(send: @escaping SessionUpdateSink) {
        self.send = send
    }

    /// Sends `state_update: running`. The turn projection calls it at
    /// Router's `turnStarted` event (plan.md §8.4).
    func turnDidStart() async {
        await sendRunning()
    }

    /// Runs `body` as a wait on the human (plan.md §8.2): sends
    /// `requires_action`, opens Router's model gate with the session's
    /// `awaitingUser`, and returns to `running` when the body ends —
    /// with a value or with an error.
    ///
    /// - Parameters:
    ///   - session: The Router session whose gate opens for the wait.
    ///   - body: The wait on the human.
    /// - Returns: The body's value.
    /// - Throws: The body's error, after the state returns to `running`.
    func awaitingUser<T: Sendable>(
        on session: any RoutedSession,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await send(.stateUpdate(.requiresAction(RequiresActionStateUpdate())))
        do {
            let value = try await session.awaitingUser(body)
            await sendRunning()
            return value
        } catch {
            await sendRunning()
            throw error
        }
    }

    /// Sends the one `state_update: idle` that ends the turn, with its
    /// stop reason (plan.md §8.1).
    ///
    /// - Parameter reason: Why the turn stopped.
    func turnDidEnd(reason: StopReason) async {
        await send(.stateUpdate(.idle(IdleStateUpdate(stopReason: reason))))
    }

    /// Records that `session/cancel` asked this turn to stop. The turn
    /// reads it at the end, because a cancelled turn does not always
    /// throw (plan.md §8.6).
    func noteCancelRequested() {
        cancelRequested = true
    }

    /// Sends `state_update: running`.
    private func sendRunning() async {
        await send(.stateUpdate(.running(RunningStateUpdate())))
    }
}
