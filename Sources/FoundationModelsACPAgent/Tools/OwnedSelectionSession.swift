import FoundationModelsRouter
import FoundationModelsSkills

// `OwnedSelectionSession` — a Router session that closes when its work ends.
//
// The skills selection tier gets two kinds of Router session from this
// package:
//
// - A session that the session factory makes. The tier keeps one as the
//   cached root for its full life, and makes one for each run of an
//   over-budget search, sends one prompt to it, and then drops it.
// - A fork that `SelectionAgentSession.fork()` makes. The tier forks its
//   root one time for each search, sends one prompt to the child, and
//   then drops it.
//
// The `AgentSession` seam has no close, so the tier cannot tell a session
// that its work ended. The only signal is that the last reference to the
// session goes away. Until something calls `RoutedSession.close()`, the
// Router session keeps its prompt cache entry and can push out the cache
// of a real session.

/// A Router session that the skills selection tier uses, presented to the
/// tier as an `AgentSession`.
///
/// This type owns the Router session. When the last reference goes away,
/// `deinit` closes the session one time. While the tier holds the
/// session, it stays open, so the tier can fork a cached root as many
/// times as it must. A fork of this session is a different
/// ``OwnedSelectionSession``, so the close of a fork does not close this
/// session, and the close of this session does not close a fork.
///
/// A class, not a struct, because the close is tied to the identity of
/// one owner: a struct copy has no single end of life.
final class OwnedSelectionSession: AgentSession {
    /// The selection session over the Router session that this type owns.
    let selection: SelectionAgentSession

    /// Takes ownership of `session`.
    ///
    /// - Parameter session: The Router session to own and close.
    init(owning session: any RoutedSession) {
        selection = SelectionAgentSession(session: session)
    }

    /// Closes the owned Router session.
    ///
    /// `deinit` cannot wait for an `async` call, and `close()` is
    /// `async`, so `deinit` starts one task that calls it. The task
    /// captures the Router session, not `self`. The Router's own
    /// `ModelPool` releases a residency from a `deinit` in the same way.
    deinit {
        let session = selection.session
        Task {
            await session.close()
        }
    }

    /// Makes a synchronous session factory for the skills selection tier.
    /// `SkillsTool.make(registry:session:)` takes a synchronous factory. Each
    /// session that the factory gives owns the Router session that
    /// `makeSession` makes, and closes it when the tier drops it.
    ///
    /// - Parameter makeSession: Makes a new Router session for one request.
    /// - Returns: The factory that the selection tier calls.
    static func factory<Request>(
        makingEach makeSession: @escaping @Sendable (Request) -> any RoutedSession
    ) -> @Sendable (Request) -> any AgentSession {
        { request in OwnedSelectionSession(owning: makeSession(request)) }
    }

    /// Makes an async throwing session factory, in the shape that
    /// `SelectionConfig(model:)` takes. Each session that the factory gives
    /// owns the Router session that `makeSession` makes, and closes it when
    /// the tier drops it.
    ///
    /// The tier awaits the factory, so `makeSession` can wait, for example
    /// while a model loads. An error of `makeSession` comes out of the
    /// search that asked for the session, and no session is made.
    ///
    /// - Parameter makeSession: Makes a new Router session for one request.
    /// - Returns: The factory that the selection tier awaits.
    static func factory<Request>(
        makingEach makeSession: @escaping @Sendable (Request) async throws -> any RoutedSession
    ) -> @Sendable (Request) async throws -> any AgentSession {
        { request in OwnedSelectionSession(owning: try await makeSession(request)) }
    }

    /// Sends `prompt` to the Router session and answers with its complete
    /// text.
    ///
    /// - Parameter prompt: The prompt to send.
    /// - Returns: The complete text response of the Router session.
    /// - Throws: Whatever the Router session throws.
    func respond(to prompt: String) async throws -> String {
        try await selection.respond(to: prompt)
    }

    /// Forks a child of this session. The child is a separate
    /// ``OwnedSelectionSession``, so its close does not close this session.
    ///
    /// - Returns: The forked child session.
    /// - Throws: Whatever the Router session throws while forking.
    func fork() async throws -> any AgentSession {
        try await selection.fork()
    }
}
