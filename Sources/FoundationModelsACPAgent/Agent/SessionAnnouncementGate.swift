import Synchronization

/// The gate of the updates of one session. It tells whether the client knows the session. It keeps
/// each send until then.
///
/// A root session is known from its `session/new` or `session/resume` response. So its gate is open
/// from the start. A nested session is not known until the agent announces it. An update of a
/// session that the client does not know has no meaning for the client. Thus the gate of a nested
/// session starts closed, and the announcement opens it (``SubagentAnnouncer``). The announcer owns
/// the gate of each run (``SubagentAnnouncer/gate(for:)``), and the session takes it. So the order
/// of the announcement and the registration does not matter.
///
/// While the gate is closed, the history sink (``RoutedACPAgent/historySink(for:gate:)``) still
/// keeps each update in the retained history of the session. The gate keeps each send, in order.
/// The open sends the kept sends first. A send that comes while the open sends the kept sends goes
/// after them. So the client gets each update of the session, in the order of the session, after
/// the announcement.
///
/// ``submit(_:)`` returns after its own send ran. A caller that waits for its send resumes only
/// when the update is out. A send must not submit to its own gate, because it would wait for itself.
///
/// The gate keeps a bounded number of sends. At the bound, the oldest send leaves, and the gate
/// counts it. A gate that never opens ends with ``discard()``, which drops the kept sends.
final class SessionAnnouncementGate: Sendable {
  /// One send that the gate keeps or runs: the post of one update.
  typealias Send = @Sendable () async -> Void

  /// The most sends that a closed gate keeps. A run that sends more than this before its
  /// announcement loses its oldest sends.
  static let defaultPendingLimit = 10_000

  /// Where the gate is.
  private enum Phase {
    /// The client does not know the session. Each send waits.
    case closed

    /// The open sends the kept sends now. Each new send waits behind them.
    case flushing

    /// The client knows the session. Each send goes out at once.
    case open

    /// The session ended and the client never learned of it. Each send is dropped.
    case discarded
  }

  /// One kept send, and the caller that waits for it.
  private struct Pending {
    /// The post of one update.
    let send: Send

    /// Resumes the caller of the submit. The value tells that the gate ran or dropped the send.
    let done: CheckedContinuation<Bool, Never>
  }

  /// What a submit does when it sees the gate.
  private enum Verdict {
    /// The gate is open: the caller runs the send.
    case runNow

    /// The gate dropped the send.
    case drop

    /// The gate kept the send. The value is the oldest send that left at the bound, if any.
    case kept(leaving: Pending?)
  }

  /// The state that the lock guards.
  private struct State {
    /// Where the gate is.
    var phase: Phase

    /// The sends that wait, in the order of the submits.
    var pending: [Pending] = []

    /// The number of sends that the gate dropped.
    var dropped = 0
  }

  /// The state, under its lock.
  private let state: Mutex<State>

  /// The most sends that the gate keeps.
  private let pendingLimit: Int

  /// The id of the session, for the notice of dropped sends, or `nil`.
  private let owner: String?

  /// Makes a gate.
  ///
  /// - Parameters:
  ///   - isOpen: Whether the gate starts open.
  ///   - pendingLimit: The most sends that the gate keeps while it is not open.
  ///   - owner: The id of the session, for the notice of dropped sends.
  init(
    isOpen: Bool, pendingLimit: Int = SessionAnnouncementGate.defaultPendingLimit,
    owner: String? = nil
  ) {
    state = Mutex(State(phase: isOpen ? .open : .closed))
    self.pendingLimit = pendingLimit
    self.owner = owner
  }

  /// Makes a gate that dropped its sends already. It is for a session that no announcement can
  /// reach, so no send waits for an open that never comes.
  ///
  /// - Parameter owner: The id of the session, for the notice of dropped sends.
  /// - Returns: The gate.
  static func discarded(owner: String? = nil) -> SessionAnnouncementGate {
    let gate = SessionAnnouncementGate(isOpen: false, owner: owner)
    gate.discard()
    return gate
  }

  /// Whether the client knows the session: the gate was opened. A gate that sends its kept sends
  /// now counts as open, because the announcement already went out.
  var isOpen: Bool {
    state.withLock { $0.phase == .open || $0.phase == .flushing }
  }

  /// The number of sends that wait in the gate.
  var pendingCount: Int {
    state.withLock { $0.pending.count }
  }

  /// The number of sends that the gate dropped: at the bound, or at the discard.
  var droppedSendCount: Int {
    state.withLock { $0.dropped }
  }

  /// Runs a send, or keeps it until the gate is open. The call returns after the send ran, or
  /// after the gate dropped it.
  ///
  /// - Parameter send: The post of one update.
  func submit(_ send: @escaping Send) async {
    let ranByGate = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
      let verdict = state.withLock { state -> Verdict in
        switch state.phase {
        case .open:
          return .runNow
        case .discarded:
          state.dropped += 1
          return .drop
        case .closed, .flushing:
          state.pending.append(Pending(send: send, done: done))
          guard state.pending.count > pendingLimit else {
            return .kept(leaving: nil)
          }
          state.dropped += 1
          return .kept(leaving: state.pending.removeFirst())
        }
      }
      switch verdict {
      case .runNow:
        done.resume(returning: false)
      case .drop:
        done.resume(returning: true)
      case .kept(let leaving):
        leaving?.done.resume(returning: true)
      }
    }
    if !ranByGate {
      await send()
    }
  }

  /// Opens the gate, and sends each kept send, in order, before it returns. A send that is
  /// submitted meanwhile goes after the kept sends. A gate that is open stays open.
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
    reportDroppedSends()
    while let next = takeNextPending() {
      await next.send()
      next.done.resume(returning: true)
    }
  }

  /// Ends a gate that never opened. The kept sends are dropped, each caller that waits resumes,
  /// and each later send is dropped. A gate that is open, or that sends now, does not change.
  func discard() {
    let ended = state.withLock { state -> [Pending]? in
      guard state.phase == .closed else {
        return nil
      }
      state.phase = .discarded
      state.dropped += state.pending.count
      let kept = state.pending
      state.pending = []
      return kept
    }
    guard let ended else {
      return
    }
    reportDroppedSends()
    for pending in ended {
      pending.done.resume(returning: true)
    }
  }

  /// Writes one notice when the gate dropped sends. The notice has the session id and the count.
  private func reportDroppedSends() {
    let count = droppedSendCount
    guard count > 0 else {
      return
    }
    ACPAgentTelemetry.logger(.subagentAnnouncement).notice(
      "A session gate dropped sends that the client never got.",
      metadata: ["session_id": "\(owner ?? "unknown")", "dropped_sends": "\(count)"])
  }

  /// Takes the next kept send. When none is left, the gate becomes open in the same locked step.
  /// So no send can slip between the last kept send and the open.
  ///
  /// - Returns: The next send, or `nil` when the gate is open now.
  private func takeNextPending() -> Pending? {
    state.withLock { state in
      guard !state.pending.isEmpty else {
        state.phase = .open
        return nil
      }
      return state.pending.removeFirst()
    }
  }
}
