import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// MARK: - The shared wait for a pending elicitation

/// The read and the wait for the elicitations that a session sent to the
/// client and that the client did not answer yet.
///
/// Each suite that tests an elicitation round trip uses this one wait. The
/// wait uses ``Poll/until(_:_:sourceLocation:)``, thus it stops at the fact
/// and never sleeps for a guessed span.
enum ElicitationPoll {
    /// The elicitations that `session` did not answer yet.
    ///
    /// - Parameter session: The session model that received the
    ///   elicitations.
    /// - Returns: The pending elicitations of the session, in arrival order.
    static func pendingElicitations(in session: SessionModel) async -> [PendingElicitation] {
        await session.pendingElicitations
    }

    /// Waits until `session` holds a pending elicitation, and gives the
    /// first one.
    ///
    /// - Parameters:
    ///   - session: The session model that receives the elicitations.
    ///   - sourceLocation: The line a timeout is reported at.
    /// - Returns: The first pending elicitation of the session.
    /// - Throws: When no elicitation reaches the session model, and
    ///   `CancellationError` when the test is cancelled.
    static func firstPendingElicitation(
        in session: SessionModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> PendingElicitation {
        let sessionId = await session.sessionId
        try await Poll.until(
            "an elicitation of \(sessionId.rawValue) reaches the client",
            { await !pendingElicitations(in: session).isEmpty },
            sourceLocation: sourceLocation)
        return try #require(
            await pendingElicitations(in: session).first,
            sourceLocation: sourceLocation)
    }
}
