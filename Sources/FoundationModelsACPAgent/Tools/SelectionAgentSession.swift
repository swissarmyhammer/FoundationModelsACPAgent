import FoundationModelsRouter
import FoundationModelsSkills

// `SelectionAgentSession` — a Router session presented as an `AgentSession`.
//
// The skills selection tier holds every session as `any AgentSession` and
// knows nothing of Router. The supported route is for each consumer to
// conform its own session type, and Multitool holds its own internal copy of
// this same join for `searchTools`. The shape is kept unchanged on purpose:
// a different shape here would be another definition of the same seam.

/// A `RoutedSession` presented to the skills selection tier as an
/// `AgentSession`.
struct SelectionAgentSession: AgentSession {
    /// The Router session every call travels to.
    private let session: any RoutedSession

    /// Makes the presentation over one Router session.
    ///
    /// - Parameter session: The session to present.
    init(session: any RoutedSession) {
        self.session = session
    }

    /// Sends `prompt` to the session and answers with its complete text.
    ///
    /// - Parameter prompt: The prompt to send.
    /// - Returns: The session's complete text response.
    /// - Throws: Whatever the underlying session throws.
    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt)
    }

    /// Forks a child session that continues this one's conversation.
    ///
    /// **This override is load-bearing, and the protocol default is wrong
    /// for a Router session.** `AgentSession.fork()` defaults to returning
    /// `self`, which is correct only for a session that cannot really fork.
    /// A `RoutedSession` forks at the cache level: the child gets a copy of
    /// the prefilled KV cache. Taking the default would leave the selection
    /// tier's cached-root path re-sending the assembled prefix on every
    /// call, and the loss would be silent — the tier would still answer
    /// correctly, only slower and at more tokens.
    ///
    /// - Returns: The forked child session.
    /// - Throws: Whatever the underlying session throws while forking.
    func fork() async throws -> any AgentSession {
        SelectionAgentSession(session: try await session.fork(workingDirectory: nil))
    }
}
