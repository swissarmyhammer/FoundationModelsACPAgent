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
/// The drain is a loop that looks for "done" under a deadline. It is not a
/// fixed wait: each attempt calls `RoutedSession.drain()`, and a short attempt
/// cancels only the wait, not the drain. The next attempt joins the same
/// drain.
enum SessionDrain {
    /// The longest time one attempt waits before it looks again.
    private static let attemptLength: Duration = .seconds(5)

    /// The longest time the whole drain waits.
    static let deadline: Duration = .seconds(120)

    /// Drains the Router session of `sessionId` and closes the ACP session.
    ///
    /// - Parameters:
    ///   - sessionId: The ACP session to end.
    ///   - harness: The harness that holds the agent and the client wire.
    /// - Returns: `true` when the drain completed inside ``deadline``.
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

    /// Calls `drain()` in short attempts until it reports done, or until
    /// ``deadline`` passes.
    ///
    /// - Parameter session: The Router session to drain.
    /// - Returns: `true` when the drain completed.
    static func drain(_ session: any RoutedSession) async -> Bool {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let attempt = Task { await session.drain() }
            let limit = Task {
                try? await Task.sleep(for: attemptLength)
                attempt.cancel()
            }
            let drained = await attempt.value
            limit.cancel()
            if drained {
                return true
            }
        }
        return false
    }
}
