import Synchronization

/// The gate of the updates of one session: it tells whether the client knows
/// the session, and it keeps each send until then.
///
/// A root session is known from its `session/new` or `session/resume`
/// response, so its gate is open from the start. A nested session is not
/// known until the agent announces it. An update of a session that the client
/// does not know has no meaning for the client. Thus the gate of a nested
/// session starts closed, and the announcement opens it
/// (``SubagentAnnouncer``). The announcer owns the gate of each run
/// (``SubagentAnnouncer/gate(for:)``), and the session takes it. So the order
/// of the announcement and the registration does not matter.
///
/// While the gate is closed, the history sink
/// (``RoutedACPAgent/historySink(for:gate:)``) still keeps each update in the
/// retained history of the session. The gate keeps each send, in order. The
/// open sends the kept sends first. A send that comes while the open sends
/// the kept sends goes after them. So the client gets each update of the
/// session, in the order of the session, after the announcement.
final class SessionAnnouncementGate: Sendable {
    /// One send that the gate keeps or runs: the post of one update.
    typealias Send = @Sendable () async -> Void

    /// Where the gate is.
    private enum Phase {
        /// The client does not know the session. Each send waits.
        case closed

        /// The open sends the kept sends now. Each new send waits behind
        /// them.
        case flushing

        /// The client knows the session. Each send goes out at once.
        case open
    }

    /// The state that the lock guards.
    private struct State {
        /// Where the gate is.
        var phase: Phase

        /// The sends that wait, in the order of the submits.
        var pending: [Send] = []
    }

    /// The state, under its lock.
    private let state: Mutex<State>

    /// Makes a gate.
    ///
    /// - Parameter isOpen: Whether the gate starts open.
    init(isOpen: Bool) {
        state = Mutex(State(phase: isOpen ? .open : .closed))
    }

    /// Whether the client knows the session: the gate was opened. A gate that
    /// sends its kept sends now counts as open, because the announcement
    /// already went out.
    var isOpen: Bool {
        state.withLock { $0.phase != .closed }
    }

    /// Runs a send, or keeps it until the gate is open.
    ///
    /// - Parameter send: The post of one update.
    func submit(_ send: @escaping Send) async {
        let runsNow = state.withLock { state -> Bool in
            guard state.phase == .open else {
                state.pending.append(send)
                return false
            }
            return true
        }
        if runsNow {
            await send()
        }
    }

    /// Opens the gate, and sends each kept send, in order, before it returns.
    /// A send that is submitted meanwhile goes after the kept sends. A gate
    /// that is open stays open.
    func open() async {
        let starts = state.withLock { state -> Bool in
            guard state.phase == .closed else {
                return false
            }
            state.phase = .flushing
            return true
        }
        guard starts else {
            return
        }
        while let next = takeNextPending() {
            await next()
        }
    }

    /// Takes the next kept send. When none is left, the gate becomes open in
    /// the same locked step, so no send can slip between the last kept send
    /// and the open.
    ///
    /// - Returns: The next send, or `nil` when the gate is open now.
    private func takeNextPending() -> Send? {
        state.withLock { state in
            guard !state.pending.isEmpty else {
                state.phase = .open
                return nil
            }
            return state.pending.removeFirst()
        }
    }
}
