import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter

/// The current state of the children of a resumed session (ACP "Subagent Sessions" RFD).
///
/// The response of `session/resume` is the freshness boundary. The history of the tree goes out
/// before it. The current snapshot of each child goes out after it, with or without a replay.
/// The sync runs before any other live traffic of a child: the gate of a child session stays
/// closed until its snapshot went out, so an update that the child makes meanwhile waits for it.
extension RoutedACPAgent {
  /// Schedules the sync of the children to run after the response of the current request.
  ///
  /// Call it synchronously in the handler of the request, so the work follows the response.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session.
  ///   - connection: The connection of the request.
  func scheduleChildSync(of sessionId: SessionId, through connection: AgentSideConnection) {
    connection.afterRespondingInCurrentInstrumentationContext { [weak self] in
      await self?.syncChildren(of: sessionId)
    }
  }

  /// Sends the current state of each child of the tree of `sessionId`, the parent before the
  /// child. A child whose `agents` call has a final status in the history is not a live child: it
  /// gets nothing here, and neither do its descendants. Its history only replays, before the
  /// response. For a child that restored: its `subagent_update` on the stream of its parent, with
  /// the state that its ledger reports now (a cold-restored child is `idle`, a child that works
  /// shows `running`), the capabilities and the working directory. Then its own `state_update`
  /// on its own stream. For a child that did not restore: one `subagent_update` with no state, no
  /// capabilities and the reason (``SAH/RestoreFailure``).
  ///
  /// - Parameter sessionId: The resumed root session.
  func syncChildren(of sessionId: SessionId) async {
    guard let entry = sessions[sessionId], !entry.isClosed,
      let connection = connections.path(forSession: sessionId)?.connection
    else {
      return
    }
    let failures = entry.nestedRestore?.failed ?? []
    await syncChildren(of: sessionId, failures: failures, through: connection)
  }

  /// Syncs the children of one session, and then theirs.
  ///
  /// - Parameters:
  ///   - parent: The session whose children are synced.
  ///   - failures: The children that did not restore, in tree order.
  ///   - connection: The connection that carries the updates.
  private func syncChildren(
    of parent: SessionId, failures: [FailedChild], through connection: AgentSideConnection
  ) async {
    let started = sessions[parent]?.children ?? []
    for child in started where !(sessions[parent]?.history.endsCall(of: child) ?? false) {
      await syncRestoredChild(child, under: parent, through: connection)
      await syncChildren(of: child, failures: failures, through: connection)
    }
    for failed in failures where failed.child.parentSessionId.description == parent.rawValue {
      await announceFailure(of: failed, under: parent, through: connection)
      await syncChildren(
        of: SessionId(rawValue: failed.child.sessionID.description), failures: failures,
        through: connection)
    }
  }

  /// Sends the snapshot of a child that restored, then its own state.
  ///
  /// - Parameters:
  ///   - child: The child.
  ///   - parent: The session that started the child.
  ///   - connection: The connection that carries the updates.
  private func syncRestoredChild(
    _ child: SessionId, under parent: SessionId, through connection: AgentSideConnection
  ) async {
    guard let entry = sessions[child], let parentEntry = sessions[parent] else {
      return
    }
    var snapshot = parentEntry.history.announced(child) ?? SubagentUpdate(sessionId: child)
    snapshot.capabilities = .value(SubagentAnnouncer.childCapabilities)
    snapshot.cwd = .value(AbsolutePath(rawValue: entry.workingDirectory.path))
    snapshot.state = .value(await entry.stateLedger.currentSnapshot())
    await send(snapshot, on: parent, through: connection)
    await parentEntry.stateLedger.subagentAnnounced(child)
    // The client knows the child now: what the child made meanwhile goes out after the snapshot.
    await entry.announcement.open()
    await entry.stateLedger.announceCurrentState()
  }

  /// Announces a child that did not restore: no state, no capabilities, and the reason.
  ///
  /// - Parameters:
  ///   - failed: The child and why it did not restore.
  ///   - parent: The session whose stream carries the announcement.
  ///   - connection: The connection that carries the updates.
  private func announceFailure(
    of failed: FailedChild, under parent: SessionId, through connection: AgentSideConnection
  ) async {
    let child = SessionId(rawValue: failed.child.sessionID.description)
    var update =
      sessions[parent]?.history.announced(child)
      ?? SubagentUpdate(sessionId: child, title: .value(failed.child.agentID))
    update.state = .cleared
    update.capabilities = .cleared
    var held: FoundationModelsACP.JSONValue?
    if case .value(let meta) = update.meta {
      held = meta
    }
    update.meta = .value(SAH.RestoreFailure(reason: failed.reason).written(into: held))
    await send(update, on: parent, through: connection)
  }

  /// Records one announcement in the history of the stream that carries it, and sends it.
  ///
  /// - Parameters:
  ///   - update: The announcement.
  ///   - stream: The session whose stream carries it.
  ///   - connection: The connection that carries the updates.
  private func send(
    _ update: SubagentUpdate, on stream: SessionId, through connection: AgentSideConnection
  ) async {
    recordInHistory(.subagentUpdate(update), of: stream)
    await connection.post(.subagentUpdate(update), in: stream)
  }
}

extension SessionMergeEngine {
  /// Whether the history holds a final status for the `agents` call that started a child. The
  /// call links to the child in its `_meta`. A child with such a call is finished, so a resume
  /// does not restore it as a live child.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` when a `tool_call_update` with a final status links to `child`.
  func endsCall(of child: SessionId) -> Bool {
    replayUpdates(from: .start).contains { $0.endedChild == child }
  }

  /// The merged announcement that the history holds for a child.
  ///
  /// - Parameter child: The child.
  /// - Returns: The announcement, or `nil` when the history holds none.
  func announced(_ child: SessionId) -> SubagentUpdate? {
    subagents.first { $0.sessionId == child }
  }
}

extension SAH.RestoreFailure {
  /// Writes this object into `_meta.sah.restoreFailure` of a `_meta` value, without a throwing
  /// encoder step: the object is one string, so the announcement of a failed child always carries
  /// its reason.
  ///
  /// The function keeps every other member of `_meta` and of `_meta.sah`, and replaces an earlier
  /// `restoreFailure`. It agrees with ``inject(into:)`` when `_meta` and `_meta.sah` are objects,
  /// `null` or absent. It differs for a value that is not an object: ``inject(into:)`` returns it
  /// unchanged and so drops the reason, but this function replaces `_meta` (or `_meta.sah`) with a
  /// fresh object that holds the reason.
  ///
  /// - Parameter meta: The `_meta` value to write into, or `nil`.
  /// - Returns: The `_meta` value to send. It always carries the reason.
  func written(into meta: FoundationModelsACP.JSONValue?) -> FoundationModelsACP.JSONValue {
    var members = Self.members(of: meta)
    var sahMembers = Self.members(of: members[SAH.metaKey])
    sahMembers[Self.metaKey] = .object(["reason": .string(reason)])
    members[SAH.metaKey] = .object(sahMembers)
    return .object(members)
  }

  /// The members that a write starts from.
  ///
  /// - Parameter value: The value to write into, or `nil`.
  /// - Returns: The members of an object, or an empty set for any other value, which the write
  ///   replaces.
  private static func members(of value: FoundationModelsACP.JSONValue?) -> [String: FoundationModelsACP.JSONValue] {
    if case .object(let members)? = value {
      return members
    }
    return [:]
  }
}
