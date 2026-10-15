import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - The shared wait for a pending elicitation

/// The read and the wait for the elicitations that a session sent to the
/// client and that the client did not answer yet.
///
/// Each suite that tests an elicitation round trip uses this one wait. The
/// wait observes the session model (``ObservedValue``), thus each change of
/// the model checks the fact again, and the wait uses no clock and no poll.
enum ElicitationWait {
    /// The elicitations that `session` did not answer yet.
    ///
    /// - Parameter session: The session model that received the
    ///   elicitations.
    /// - Returns: The pending elicitations of the session, in arrival order.
    static func pendingElicitations(in session: SessionModel) async -> [PendingElicitation] {
        await session.pendingElicitations
    }

    /// Waits until `session` holds no pending elicitation: each client
    /// request ended, with an answer or with a cancel of the agent.
    ///
    /// - Parameter session: The session model that received the
    ///   elicitations.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    static func waitUntilNoPendingElicitation(in session: SessionModel) async throws {
        let sessionId = session.sessionId
        try await ObservedValue.wait(for: "each elicitation of \(sessionId.rawValue) ends at the client") {
            session.pendingElicitations.isEmpty
        }
    }

    /// Waits until `session` holds a pending elicitation, and gives the
    /// first one.
    ///
    /// - Parameters:
    ///   - session: The session model that receives the elicitations.
    ///   - sourceLocation: The line a failed read is reported at.
    /// - Returns: The first pending elicitation of the session.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    static func firstPendingElicitation(
        in session: SessionModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> PendingElicitation {
        let sessionId = session.sessionId
        try await ObservedValue.wait(for: "an elicitation of \(sessionId.rawValue) reaches the client") {
            !session.pendingElicitations.isEmpty
        }
        return try #require(
            await pendingElicitations(in: session).first,
            sourceLocation: sourceLocation)
    }
}
