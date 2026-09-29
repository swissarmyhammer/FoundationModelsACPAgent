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
    /// The elicitations of `sessionId` that `client` did not answer yet.
    ///
    /// - Parameters:
    ///   - sessionId: The session to read.
    ///   - client: The client that received the elicitations.
    /// - Returns: The pending elicitations of `sessionId`, in arrival order.
    static func pendingElicitations(
        of sessionId: SessionId, on client: SwiftUIACPClient
    ) async -> [PendingElicitation] {
        await MainActor.run { client.pendingElicitations(for: sessionId) }
    }

    /// Waits until `client` holds a pending elicitation of `sessionId`, and
    /// gives the first one.
    ///
    /// - Parameters:
    ///   - sessionId: The session to watch.
    ///   - client: The client that receives the elicitations.
    ///   - sourceLocation: The line a timeout is reported at.
    /// - Returns: The first pending elicitation of `sessionId`.
    /// - Throws: When no elicitation of `sessionId` reaches the client, and
    ///   `CancellationError` when the test is cancelled.
    static func firstPendingElicitation(
        of sessionId: SessionId,
        on client: SwiftUIACPClient,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> PendingElicitation {
        try await Poll.until(
            "an elicitation of \(sessionId.rawValue) reaches the client",
            { await !pendingElicitations(of: sessionId, on: client).isEmpty },
            sourceLocation: sourceLocation)
        return try #require(
            await pendingElicitations(of: sessionId, on: client).first,
            sourceLocation: sourceLocation)
    }
}
