import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter

@testable import FoundationModelsACPAgent

/// Ends the work of one agent session before a real-model test ends.
///
/// A settled background run comes back as mail, and the mail can start a new
/// answer after the prompt ended with `end_turn`. A generation that still runs
/// on the MLX queue when the test process exits crashes the process. So a
/// real-model test drains its session, and then closes it through ACP.
///
/// The drain is `RoutedSession.awaitIdle()`: it returns when the session has
/// no open background run, no pump work and no queued run mail that can
/// start an answer. It waits for each change of the work of the session,
/// with no clock and no poll.
enum SessionDrain {
    /// Drains the Router session of `sessionId` and closes the ACP session.
    ///
    /// - Parameters:
    ///   - sessionId: The ACP session to end.
    ///   - harness: The harness that holds the agent and the client wire.
    /// - Returns: `true` when the session became idle, and `false` when it
    ///   closed or the task was cancelled first.
    /// - Throws: Whatever `session/close` throws.
    @discardableResult
    static func drainAndClose(
        _ sessionId: SessionId, in harness: AgentClientHarness
    ) async throws -> Bool {
        guard let session = await harness.agent.sessions[sessionId]?.session else {
            return true
        }
        let drained = await drain(session)
        _ = try await harness.connection.closeSession(CloseSessionRequest(sessionId: sessionId))
        return drained
    }

    /// Waits until `session` has no work.
    ///
    /// - Parameter session: The Router session to drain.
    /// - Returns: `true` when the session became idle.
    static func drain(_ session: any RoutedSession) async -> Bool {
        await session.awaitIdle()
    }
}
