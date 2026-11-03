import FoundationModelsACP
import Synchronization

/// Why ``SessionTree`` refused a link.
enum SessionTreeError: Error, Equatable {
    /// The session is its own parent.
    case selfParent(SessionId)

    /// The link would put the session below one of its own descendants, so
    /// the parent links would make a ring.
    case cycle(session: SessionId, parent: SessionId)

    /// The session has a parent already. A session has one parent for its
    /// whole life.
    case secondParent(session: SessionId, existing: SessionId, requested: SessionId)
}

/// The parent links of the sessions of one agent.
///
/// A sub-agent session is an ordinary session with a parent. The root of a
/// tree is a session with no parent link, and it needs no entry here. The
/// tree holds only the links; the table of the agent holds the sessions.
///
/// A `Mutex` holds the links, so the agent and a task that it does not
/// isolate can read and change them at the same time. Each change is one
/// locked step: the check of a link and the link cannot be split by another
/// change.
final class SessionTree: Sendable {
    /// The links under their lock.
    private struct State {
        /// The parent of each session that has one.
        var parents: [SessionId: SessionId] = [:]

        /// The children of each session, in the order of the links.
        var children: [SessionId: [SessionId]] = [:]
    }

    /// The links, under their lock.
    private let state = Mutex(State())

    /// Makes a tree with no link.
    init() {}

    /// Links `session` below `parent`.
    ///
    /// - Parameters:
    ///   - session: The child session.
    ///   - parent: The parent session.
    /// - Throws: ``SessionTreeError/selfParent(_:)`` when both are the same
    ///   session, ``SessionTreeError/secondParent(session:existing:requested:)``
    ///   when `session` has a parent, and ``SessionTreeError/cycle(session:parent:)``
    ///   when `parent` is a descendant of `session`. A refused link changes
    ///   nothing.
    func link(_ session: SessionId, toParent parent: SessionId) throws(SessionTreeError) {
        try state.withLock { state throws(SessionTreeError) in
            guard session != parent else {
                throw .selfParent(session)
            }
            if let existing = state.parents[session] {
                throw .secondParent(session: session, existing: existing, requested: parent)
            }
            guard !Self.ancestors(of: parent, in: state).contains(session) else {
                throw .cycle(session: session, parent: parent)
            }
            state.parents[session] = parent
            state.children[parent, default: []].append(session)
        }
    }

    /// Removes the parent link of `session`. The links of its children stay,
    /// so a caller removes the descendants first. A session with no link
    /// changes nothing.
    ///
    /// - Parameter session: The session to unlink from its parent.
    func remove(_ session: SessionId) {
        state.withLock { state in
            guard let parent = state.parents.removeValue(forKey: session) else {
                return
            }
            state.children[parent]?.removeAll { $0 == session }
            if state.children[parent]?.isEmpty ?? false {
                state.children.removeValue(forKey: parent)
            }
        }
    }

    /// The parent of a session.
    ///
    /// - Parameter session: The session.
    /// - Returns: The parent, or `nil` for a root session.
    func parent(of session: SessionId) -> SessionId? {
        state.withLock { $0.parents[session] }
    }

    /// The ancestors of a session, the root first and the parent last. The
    /// session itself is not in the list.
    ///
    /// - Parameter session: The session.
    /// - Returns: The chain of parents, or an empty list for a root session.
    func ancestors(of session: SessionId) -> [SessionId] {
        state.withLock { Self.ancestors(of: session, in: $0) }
    }

    /// The direct children of a session, in the order of the links.
    ///
    /// - Parameter session: The session.
    /// - Returns: The children, or an empty list for a session with none.
    func children(of session: SessionId) -> [SessionId] {
        state.withLock { $0.children[session] ?? [] }
    }

    /// The ancestors of a session in `state`, the root first.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - state: The links.
    /// - Returns: The chain of parents.
    private static func ancestors(of session: SessionId, in state: State) -> [SessionId] {
        var chain: [SessionId] = []
        var current = session
        while let parent = state.parents[current] {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }
}
