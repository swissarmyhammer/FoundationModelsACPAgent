import FoundationModelsACP

/// The no-work mark of an `idle` state update.
///
/// In ACP an `idle` tells that the foreground work of the agent stopped, and
/// background work can continue after it. This agent sends `idle` only when
/// the session has no work at all: no prompt is open, no Router session of
/// the session works, nothing in the mailbox can start work, and no
/// background tool work is open. The `idle` says so in `_meta.noWork`.
///
/// A headless client (`acp-agent run`, a benchmark harness) ends on an `idle`
/// with the mark. A client with a user interface can ignore the mark and
/// wait. The mark is not a turn: it tells the work state of the session, and
/// not the end of one prompt.
extension IdleStateUpdate {
    /// The key of the mark in the `_meta` object of the `idle`.
    public static let noWorkMetaKey = "noWork"

    /// This `idle` with the mark that the session has no work. The other
    /// members of `_meta` stay.
    ///
    /// - Returns: The marked `idle`.
    public func sayingNoWork() -> IdleStateUpdate {
        var marked = self
        var members: [String: JSONValue] = [:]
        if case .object(let current)? = meta {
            members = current
        }
        members[Self.noWorkMetaKey] = .bool(true)
        marked.meta = .object(members)
        return marked
    }

    /// Whether this `idle` says that the session has no work.
    public var saysNoWork: Bool {
        guard case .object(let members)? = meta, case .bool(let noWork)? = members[Self.noWorkMetaKey] else {
            return false
        }
        return noWork
    }
}
