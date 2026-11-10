import FoundationModelsACP
import Synchronization

/// The hold of the live updates of one session tree while a hot resume moves the tree to a new
/// connection (``RoutedACPAgent/resumeLiveSession(_:entry:replayCursor:from:)``).
///
/// The take gives the tree to the new connection. The client of the new connection does not know
/// the children of the tree until the replay announces them, and the replay, the current state
/// and the response must come before the live traffic. So from the take on, each live update of
/// the tree goes into this hold, in one queue for all the sessions of the tree. The queue keeps
/// the order of the submits across the sessions, so a child update stays after the update of its
/// parent that came before it. After the response and the current snapshots of the children,
/// ``release()`` sends the kept updates in order, and the hold is open.
///
/// A submit to a hold that holds returns at once. The caller does not wait for the send. The
/// order on the wire is the order of the submits, because each later send of the tree goes into
/// the same queue. This is necessary: the ledger of a session sends one update at a time, and the
/// resume sends the current state of the root through the same ledger before the response. A
/// submit that waited for the release would stop that current state, and the response would
/// never come.
///
/// The sends of the resume itself (the replay, the current state and the snapshots) do not go
/// through the hold.
final class SessionResumeHold: Sendable {
  /// One send that the hold keeps or runs: the post of one update.
  typealias Send = SessionAnnouncementGate.Send

  /// Where the hold is.
  private enum Phase {
    /// The resume did not end. Each send waits in the queue.
    case holding

    /// The release sends the kept sends now. Each new send waits behind them.
    case flushing

    /// The release is done. Each send goes out at once.
    case open

    /// A later take or the close of the connection ended the hold. Each send is dropped.
    case discarded
  }

  /// The state that the lock guards.
  private struct State {
    /// Where the hold is.
    var phase = Phase.holding

    /// The sends that wait, in the order of the submits.
    var pending: [Send] = []
  }

  /// The state, under its lock.
  private let state = Mutex(State())

  /// The root session of the tree, for the notice of dropped sends.
  private let rootSessionId: SessionId

  /// Makes a hold that holds.
  ///
  /// - Parameter rootSessionId: The root session of the tree.
  init(rootSessionId: SessionId) {
    self.rootSessionId = rootSessionId
  }

  /// Runs a send when the hold is open. Else it keeps the send, and returns at once.
  ///
  /// - Parameter send: The post of one update.
  func submit(_ send: @escaping Send) async {
    let runsNow = state.withLock { state -> Bool in
      switch state.phase {
      case .open:
        return true
      case .discarded:
        return false
      case .holding, .flushing:
        state.pending.append(send)
        return false
      }
    }
    if runsNow {
      await send()
    }
  }

  /// Sends each kept send, in order, and opens the hold before it returns. A send that is
  /// submitted meanwhile goes after the kept sends. A hold that is not holding does not change.
  func release() async {
    let starts = state.withLock { state -> Bool in
      guard case .holding = state.phase else {
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

  /// Ends a hold that did not open. The kept sends are dropped, and each later send is dropped.
  /// The retained history holds each dropped update that the agent records, so a later resume
  /// replays it. A hold that is open does not change.
  func discard() {
    let dropped = state.withLock { state -> Int? in
      switch state.phase {
      case .holding, .flushing:
        state.phase = .discarded
        defer { state.pending = [] }
        return state.pending.count
      case .open, .discarded:
        return nil
      }
    }
    guard let dropped, dropped > 0 else {
      return
    }
    ACPAgentTelemetry.logger(.sessionResume).notice(
      "A later take ended the hold of a hot resume. The hold dropped the live sends that it kept.",
      metadata: ["session_id": "\(rootSessionId.rawValue)", "dropped_sends": "\(dropped)"])
  }

  /// Takes the next kept send. When none is left, the hold becomes open in the same locked step.
  /// So no send can slip between the last kept send and the open. A discard during the release
  /// ends the release.
  ///
  /// - Returns: The next send, or `nil` when the hold is open or discarded now.
  private func takeNextPending() -> Send? {
    state.withLock { state in
      guard case .flushing = state.phase else {
        return nil
      }
      guard !state.pending.isEmpty else {
        state.phase = .open
        return nil
      }
      return state.pending.removeFirst()
    }
  }
}

/// Where the live updates of a session go: the owner connection of the session, and the hold of a
/// hot resume of its tree, if one is there (``ConnectionTable/route(forSession:)``).
struct SessionUpdateRoute: Sendable {
  /// The connection that owns the session.
  let owner: ConnectionId

  /// The hold of the hot resume that gave the session to ``owner``, or `nil`.
  let hold: SessionResumeHold?
}
