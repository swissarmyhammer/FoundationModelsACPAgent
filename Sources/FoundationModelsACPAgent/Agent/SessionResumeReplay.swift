import FoundationModelsACP
import FoundationModelsRouter

/// One session of the tree that a `session/resume` replays, with the history to replay for it.
struct ReplayedSession {
  /// One announcement of a child, and the session whose stream carries it.
  struct Announcement {
    /// The session that carries the announcement: the parent of the announced child.
    let sessionId: SessionId

    /// The `subagent_update` of the child.
    let update: SessionUpdate
  }

  /// The session that the updates belong to.
  let sessionId: SessionId

  /// The retained history of the session.
  let history: SessionMergeEngine

  /// The sessions nested directly in this session that the replay covers, in the order that
  /// they started.
  let children: [ReplayedSession]

  /// The announcements of the children of the whole tree, the parent before the child. Each
  /// session announces its own children, so the order of the sessions is the order of the
  /// announcements.
  ///
  /// The announcement of a child that the replay covers carries the idle state of that child, if
  /// its own history ends in one (``endedState(of:)``). A shutdown stops the runs and sends no
  /// final announcement of them, so the history of the parent can hold the state `running` for a
  /// child that went idle. The replay sends no `state_update` of a child, and the final status of
  /// the `agents` call of the child is in the history of the parent, so the announcement is the
  /// only place that tells the idle state of the child before that final status.
  var announcements: [Announcement] {
    let own = history.replayAnnouncements.map { update -> Announcement in
      Announcement(sessionId: sessionId, update: endedState(of: update))
    }
    return own + children.flatMap(\.announcements)
  }

  /// The announcement of a child, with the idle state of the child when the history of the child
  /// ends in one.
  ///
  /// - Parameter announcement: An announcement from the history of this session.
  /// - Returns: The announcement with the idle state of the child. The announcement as it is when
  ///   the child is not in the replay, when its history holds no state, or when that state is not
  ///   idle.
  private func endedState(of announcement: SessionUpdate) -> SessionUpdate {
    guard case .subagentUpdate(var update) = announcement,
      let child = children.first(where: { $0.sessionId == update.sessionId }),
      case .idle(var idle)? = child.history.agentState
    else {
      return announcement
    }
    idle.background = nil
    update.state = .value(.idle(idle))
    return .subagentUpdate(update)
  }

  /// The child that an update ends, if the update is the final status of the `agents` call that
  /// started the child.
  ///
  /// - Parameter update: An update of the history of this session.
  /// - Returns: The child, or `nil` when the update is no final status of a call with a link.
  func child(endedBy update: SessionUpdate) -> ReplayedSession? {
    guard case .toolCallUpdate(let call) = update, BackgroundWatch.isFinal(call.status),
      case .value(let meta) = call.meta,
      let linked = SAH.AgentRun.extract(from: meta)?.sessionId
    else {
      return nil
    }
    return children.first { $0.sessionId == linked }
  }
}

extension RoutedACPAgent {
  /// The sessions that a replay covers: the resumed root, and the sessions nested in it. The
  /// restored nested sessions are in the table (``restoreNestedSessions(of:composition:)``).
  /// The history of each one is its own retained history. A child that did not restore is not in
  /// the table, so the replay announces it (its parent holds the announcement) and sends no
  /// history for it.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session, or a session nested in it.
  ///   - history: The history to replay for the session, or `nil` for the retained history of
  ///     its entry. The root gets the history with the recorded plans.
  /// - Returns: The tree of the session.
  func replayedTree(of sessionId: SessionId, history: SessionMergeEngine? = nil) -> ReplayedSession
  {
    let entry = sessions[sessionId]
    let children = (entry?.children ?? []).filter { sessions[$0] != nil }.map {
      replayedTree(of: $0)
    }
    return ReplayedSession(
      sessionId: sessionId, history: history ?? entry?.history ?? SessionMergeEngine(),
      children: children)
  }

  /// Sends the history of a session tree, each session under its own session id. The history of
  /// a session goes out in its own order. The history of a child goes out before the final
  /// status of the `agents` call that started it, so the final status comes after each update
  /// of the child. The history of a child with no such call goes out after the history of its
  /// parent.
  ///
  /// - Parameters:
  ///   - tree: The session and the sessions nested in it.
  ///   - cursor: Where the replay begins.
  ///   - connection: The connection that carries the updates.
  func replayTree(
    _ tree: ReplayedSession, from cursor: ReplayCursor, through connection: AgentSideConnection
  ) async {
    var unsent = tree.children
    for update in tree.history.replayUpdates(from: cursor) {
      if let ended = tree.child(endedBy: update),
        unsent.contains(where: { $0.sessionId == ended.sessionId })
      {
        unsent.removeAll { $0.sessionId == ended.sessionId }
        await replayTree(ended, from: cursor, through: connection)
      }
      await connection.post(update, in: tree.sessionId)
    }
    for child in unsent {
      await replayTree(child, from: cursor, through: connection)
    }
  }
}
