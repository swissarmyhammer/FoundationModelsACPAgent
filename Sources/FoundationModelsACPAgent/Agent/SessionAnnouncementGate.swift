import Synchronization

/// The gate of the updates of one session: it tells whether the client knows
/// the session.
///
/// A root session is known from its `session/new` or `session/resume`
/// response, so its gate is open from the start. A nested session is not
/// known until the agent announces it, and an update of a session that the
/// client does not know has no meaning for the client. Thus the gate of a
/// nested session starts closed, and the announcement opens it
/// (``SubagentAnnouncer``); a nested session that the agent registers after its
/// announcement starts open. While the
/// gate is closed, the history sink (``RoutedACPAgent/historySink(for:gate:)``)
/// still keeps each update in the retained history of the session, and sends
/// nothing.
final class SessionAnnouncementGate: Sendable {
    /// Whether the gate is open, under its lock.
    private let opened: Mutex<Bool>

    /// Makes a gate.
    ///
    /// - Parameter isOpen: Whether the gate starts open.
    init(isOpen: Bool) {
        opened = Mutex(isOpen)
    }

    /// Whether the gate is open now.
    var isOpen: Bool {
        opened.withLock { $0 }
    }

    /// Opens the gate. Each later update goes out. A gate that is open stays
    /// open.
    func open() {
        opened.withLock { $0 = true }
    }
}
