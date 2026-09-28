import FoundationModelsRouter
import FoundationModelsSkills

// `SelectionAgentFork` — a Router fork that closes when its work ends.
//
// The skills selection tier forks its root session one time for each
// search, sends one prompt to the child, and then drops it. The
// `AgentSession` seam has no close, so the tier cannot tell the child
// that its work ended. The only signal is that the last reference to the
// child goes away. Until something calls `RoutedSession.close()`, the
// Router fork keeps its prompt cache entry and can push out the cache of
// a real session.

/// A Router fork that `SelectionAgentSession.fork()` made, presented to
/// the skills selection tier as an `AgentSession`.
///
/// This type owns the fork. When the last reference goes away, `deinit`
/// closes the fork one time. The session that the fork came from is not
/// closed: it is a different `RoutedSession`, and its owner closes it.
///
/// A class, not a struct, because the close is tied to the identity of
/// one owner: a struct copy has no single end of life.
final class SelectionAgentFork: AgentSession {
    /// The selection session over the Router fork that this type owns.
    let selection: SelectionAgentSession

    /// Takes ownership of `fork`.
    ///
    /// - Parameter fork: The Router fork to own and close.
    init(fork: any RoutedSession) {
        selection = SelectionAgentSession(session: fork)
    }

    /// Closes the owned Router fork.
    ///
    /// `deinit` cannot wait for an `async` call, and `close()` is
    /// `async`, so `deinit` starts one task that calls it. The task
    /// captures the fork, not `self`. The Router's own `ModelPool` releases
    /// a residency from a `deinit` in the same way.
    deinit {
        let fork = selection.session
        Task {
            await fork.close()
        }
    }

    /// Sends `prompt` to the fork and answers with its complete text.
    ///
    /// - Parameter prompt: The prompt to send.
    /// - Returns: The complete text response of the fork.
    /// - Throws: Whatever the fork throws.
    func respond(to prompt: String) async throws -> String {
        try await selection.respond(to: prompt)
    }

    /// Forks a child of this fork. The child is a separate
    /// ``SelectionAgentFork``, so its close does not close this fork.
    ///
    /// - Returns: The forked child session.
    /// - Throws: Whatever the fork throws while forking.
    func fork() async throws -> any AgentSession {
        try await selection.fork()
    }
}
