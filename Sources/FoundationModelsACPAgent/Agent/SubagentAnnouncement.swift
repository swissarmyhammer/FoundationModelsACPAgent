import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Logging

extension SubagentUpdate {
  /// The fields of this snapshot that differ from the snapshot that the
  /// client holds. An omitted field is unchanged for the client.
  ///
  /// - Parameter previous: The snapshot that the last sent update made. It is `nil` when the
  ///   client does not know the child yet.
  /// - Returns: This snapshot with no previous snapshot, the changed fields
  ///   only with one, or `nil` when nothing changed.
  func patch(replacing previous: SubagentUpdate?) -> SubagentUpdate? {
    guard let previous else {
      return self
    }
    let patch = SubagentUpdate(
      sessionId: sessionId,
      additionalDirectories: Self.changed(
        additionalDirectories, from: previous.additionalDirectories),
      capabilities: Self.changed(capabilities, from: previous.capabilities),
      cwd: Self.changed(cwd, from: previous.cwd),
      description: Self.changed(description, from: previous.description),
      state: Self.changed(state, from: previous.state),
      title: Self.changed(title, from: previous.title),
      meta: Self.changed(meta, from: previous.meta))
    return patch == SubagentUpdate(sessionId: sessionId) ? nil : patch
  }

  /// A field as a patch. It has the new value when it differs. It is omitted when it is the value
  /// that the client holds.
  ///
  /// - Parameters:
  ///   - field: The new value of the field.
  ///   - previous: The value that the client holds.
  /// - Returns: `field`, or `.unchanged` when it equals `previous`.
  private static func changed<Value>(_ field: PatchField<Value>, from previous: PatchField<Value>)
    -> PatchField<Value>
  {
    field == previous ? .unchanged : field
  }
}

extension RoutedACPAgent {
  /// Makes the outlet of the announcer of a root session. The announcements
  /// go through this agent. The outlet keeps the agent weakly, so the
  /// announcer holds no strong reference back to it.
  ///
  /// - Parameters:
  ///   - root: The ACP id of the root session of the surface.
  ///   - runner: The runner of the surface, which finds the parent run of a
  ///     run.
  ///   - holds: The holds on the final status of the `agents` calls of the
  ///     surface. The end of a child releases its hold.
  /// - Returns: The outlet.
  nonisolated func makeSubagentOutlet(root: SessionId, runner: AgentRunner, holds: AgentCallHolds)
    -> SubagentOutlet
  {
    SubagentOutlet(
      root: root,
      link: { [weak self] report in
        guard let self else {
          return .unavailable
        }
        return await resolveAgentCallLink(of: report, root: root)
      },
      deliver: { [weak self] report, previous, link, source in
        guard let self else {
          return .blocked
        }
        return await deliverSubagentReport(
          report, replacing: previous, link: link, root: root, source: source)
      },
      session: { [weak self] runID in
        self?.sessionDirectory.session(id: runID)
      },
      settle: { [weak self] report in
        await self?.settleSubagent(report, root: root, holds: holds)
      },
      parentReport: { runID in
        await runner.run(id: runID).map(SubagentReport.init(run:))
      })
  }

  /// Sends one `subagent_update` for a report, on the session of the parent of the run. It goes
  /// through the history sink of that session. The update is in the retained history of the
  /// parent, so a resume replays it.
  ///
  /// The first delivery of a run also registers the child session as a session nested in the
  /// parent (``registerNestedSession(_:parent:events:)``). It does this before it sends the
  /// announcement. The child projector reads the outputs of the run, and its gate opens after
  /// the announcement. So each update of the child goes out after the announcement, in order.
  /// The first delivery also links the `agents` call to the child: one `tool_call_update` with
  /// `_meta.sah.agentRun`.
  ///
  /// The update carries all fields when the client does not know the child (`previous` is `nil`).
  /// After that, it carries only the changed fields. The parent is the session that started the
  /// run. For a run that no session started, the parent is the root session. The call sends
  /// nothing and records nothing in four cases. The parent is not in the table, is closed, has no
  /// connection, or is not known to the client yet.
  ///
  /// - Parameters:
  ///   - report: The report of the run.
  ///   - previous: The snapshot that the last sent update of the run made,
  ///     or `nil`.
  ///   - link: The wire id of the `agents` call that started the run. It is `nil` when the run
  ///     has none or the id is not known.
  ///   - root: The ACP id of the root session of the surface.
  ///   - source: Where the events of the child come from, or `nil` when the session of the run
  ///     is not known. A child with no source is announced and has no session of its own.
  /// - Returns: What was done.
  func deliverSubagentReport(
    _ report: SubagentReport, replacing previous: SubagentUpdate?, link: ToolCallId?,
    root: SessionId,
    source: SubagentSource? = nil
  ) async -> SubagentDelivery {
    let parentId = parentSessionId(of: report, root: root)
    guard let parent = announcingParent(parentId) else {
      return .blocked
    }
    let target = makeSnapshot(of: report, replacing: previous, link: link)
    guard let patch = target.patch(replacing: previous) else {
      return .unchanged
    }
    let child = SessionId(rawValue: report.runID.description)
    if previous == nil {
      await registerChild(child, source: source, under: parentId)
    }
    let send = historySink(for: parentId, gate: parent.announcement)
    await send(.subagentUpdate(patch))
    if previous == nil, let link {
      await send(linkUpdate(of: link, to: child, on: parent))
    }
    return .sent(target)
  }

  /// Registers the child session of a run as a session nested in its parent. A child that has
  /// an entry already, and a child with no source, change nothing. A refused registration is
  /// logged: the child is still announced, and it has no session of its own.
  ///
  /// - Parameters:
  ///   - child: The ACP id of the child.
  ///   - source: Where the events of the child come from, or `nil`.
  ///   - parent: The ACP id of the session that started the run.
  private func registerChild(_ child: SessionId, source: SubagentSource?, under parent: SessionId)
    async
  {
    guard let source, sessions[child] == nil else {
      return
    }
    do {
      try await registerNestedSession(source.session, parent: parent, events: source.outputs)
    } catch {
      Self.logSubagentFailure(
        "The session of an agent run did not register. The run has an announcement and no session.",
        error)
    }
  }

  /// The `tool_call_update` that links an `agents` call to its child: the whole `_meta.sah` object
  /// with `agentRun.sessionId`. ACP patches `_meta` by top-level key, so the object is never
  /// partial. The translator sends no `_meta` for a tool call. So the held `_meta` is empty. The
  /// object holds the link alone. The update carries the name of the tool. So it is a valid first
  /// update of the call. The name is the same as in each other update of the call.
  ///
  /// - Parameters:
  ///   - call: The wire id of the `agents` call.
  ///   - child: The ACP id of the child.
  ///   - parent: The entry of the session that holds the call.
  /// - Returns: The update. It carries no `_meta` when the link did not encode.
  private func linkUpdate(of call: ToolCallId, to child: SessionId, on parent: ActiveSession)
    -> SessionUpdate
  {
    var update = ToolCallUpdate(toolCallId: call)
    if let name = parent.surface.agents?.tool.name {
      update.name = .value(name)
    }
    do {
      update.meta = .value(try SAH.AgentRun(sessionId: child).inject(into: nil))
    } catch {
      Self.logSubagentFailure(
        "The link of an agents call to its child did not encode. The call has no link.", error)
    }
    return .toolCallUpdate(update)
  }

  /// Ends the child of a run that ended, in the order that the wire rules ask for. The child
  /// session sends its last updates and its final `idle` with the stop reason. The session
  /// retires. Then the hold on the `agents` call ends. The final status of the call goes out on
  /// the session of the parent. So the final status comes after each update of the child.
  ///
  /// - Parameters:
  ///   - report: The final report of the run.
  ///   - root: The ACP id of the root session of the surface.
  ///   - holds: The holds on the final status of the `agents` calls.
  func settleSubagent(_ report: SubagentReport, root: SessionId, holds: AgentCallHolds) async {
    let child = SessionId(rawValue: report.runID.description)
    if let entry = sessions[child] {
      await endChild(entry, with: report)
      await retireSession(child)
    }
    guard let token = report.completionToken else {
      return
    }
    guard let parent = sessions[parentSessionId(of: report, root: root)] else {
      _ = holds.release(token)
      return
    }
    await parent.projector.releaseHold(of: token)
  }

  /// Ends the session of a child. A child that the client knows sends its last updates and its
  /// final `idle`. A child that was never announced sends nothing, because nothing about a child
  /// goes out before its announcement. Its gate drops the sends that it kept, and writes a notice.
  ///
  /// The child can send two `idle` updates at its end. The first has no stop reason. The state
  /// ledger sends it when the work of the child ends. The second has the stop reason. It is the
  /// end of the turn. The client keeps the last state, so it shows the stop reason.
  ///
  /// - Parameters:
  ///   - entry: The entry of the child.
  ///   - report: The final report of the run.
  private func endChild(_ entry: ActiveSession, with report: SubagentReport) async {
    guard entry.announcement.isOpen else {
      entry.announcement.discard()
      return
    }
    if case .idle(let idle) = report.state {
      await entry.projector.end(with: idle)
    }
  }

  /// Finds the link of a run to the `agents` call that started it. The link
  /// is the wire id that the projection of the parent sends for the call.
  ///
  /// The join table of the parent maps the completion token of the call to
  /// the wire id. The projection of the parent writes the entry when it
  /// handles the open record of the call. The observer of the run can see
  /// the first event of the run before that. So the call waits for the entry
  /// (``RunCallJoinTable/awaitToolCallId(for:)``). The wait ends with no id
  /// when the task is cancelled. Then the link is not available. A token is
  /// never sent as a wire id.
  ///
  /// - Parameters:
  ///   - report: The report of the run.
  ///   - root: The ACP id of the root session of the surface.
  /// - Returns: ``SubagentLink/none`` for a run that no call started,
  ///   the wire id, or ``SubagentLink/unavailable``.
  func resolveAgentCallLink(of report: SubagentReport, root: SessionId) async -> SubagentLink {
    guard let token = report.completionToken else {
      return .none
    }
    guard let parent = sessions[parentSessionId(of: report, root: root)], !parent.isClosed else {
      return .unavailable
    }
    guard let callId = await parent.projector.runCallJoins.awaitToolCallId(for: RunToken(token)),
      !Task.isCancelled
    else {
      return .unavailable
    }
    return .callId(callId)
  }

  /// The ACP id of the session that an announcement of a run goes on.
  ///
  /// - Parameters:
  ///   - report: The report of the run.
  ///   - root: The ACP id of the root session of the surface.
  /// - Returns: The session that started the run, or the root session.
  private nonisolated func parentSessionId(of report: SubagentReport, root: SessionId) -> SessionId
  {
    report.caller.map { SessionId(rawValue: $0.description) } ?? root
  }

  /// The entry of a session that can take an announcement now.
  ///
  /// - Parameter sessionId: The session.
  /// - Returns: The entry. `nil` when the session is not in the table, is
  ///   closed, or has no connection with an outbound path. Also `nil` when
  ///   the client does not know it yet (its gate is closed).
  private func announcingParent(_ sessionId: SessionId) -> ActiveSession? {
    guard let entry = sessions[sessionId], !entry.isClosed, entry.announcement.isOpen,
      connections.path(forSession: sessionId) != nil
    else {
      return nil
    }
    return entry
  }

  /// The full snapshot of a child after this report.
  ///
  /// The fields are the values of the child: its agent id as title, and its
  /// agent description. The run has no public working directory, so the
  /// snapshot omits `cwd` and `additionalDirectories` (an omitted field is
  /// unchanged). It never sends the place of the parent in their place.
  ///
  /// ACP patches `_meta` by top-level key, so a partial `_meta.sah` object
  /// is never right. The link goes into the whole `sah` object, on top of
  /// the `_meta` that the client holds.
  ///
  /// - Parameters:
  ///   - report: The report of the run.
  ///   - previous: The snapshot that the last sent update made, or `nil`.
  ///   - link: The wire id of the `agents` call, or `nil`.
  /// - Returns: The snapshot.
  private func makeSnapshot(
    of report: SubagentReport, replacing previous: SubagentUpdate?, link: ToolCallId?
  ) -> SubagentUpdate {
    SubagentUpdate(
      sessionId: SessionId(rawValue: report.runID.description),
      capabilities: .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities())),
      description: report.description.map { .value($0) } ?? .unchanged,
      state: .value(report.state),
      title: .value(report.title),
      meta: makeMeta(replacing: previous, link: link))
  }

  /// The `_meta` of a snapshot: the `_meta` that the client holds, with the
  /// link to the `agents` call in `_meta.sah.agentRun.toolCallId`.
  ///
  /// A link that is known after the first announcement gives a later
  /// patch with the whole `sah` object.
  ///
  /// - Parameters:
  ///   - previous: The snapshot that the last sent update made, or `nil`.
  ///   - link: The wire id of the `agents` call, or `nil`.
  /// - Returns: The `_meta` value, or `.unchanged` when there is none.
  private func makeMeta(
    replacing previous: SubagentUpdate?, link: ToolCallId?
  ) -> PatchField<FoundationModelsACP.JSONValue> {
    let held = previous?.meta ?? .unchanged
    guard let link else {
      return held
    }
    var existing: FoundationModelsACP.JSONValue?
    if case .value(let meta) = held {
      existing = meta
    }
    guard SAH.AgentRun.extract(from: existing)?.toolCallId != link else {
      return held
    }
    do {
      return .value(try SAH.AgentRun(toolCallId: link).inject(into: existing))
    } catch {
      Self.logSubagentFailure(
        "The link of an agent run to its tool call did not encode. The announcement has no link.",
        error)
      return held
    }
  }

  /// Records a failure of the announcement of a sub-agent run. The three catch blocks of this
  /// file write the same record, and only the message differs.
  ///
  /// - Parameters:
  ///   - message: What did not work, and what the run lacks because of it.
  ///   - error: The error that was thrown.
  private static func logSubagentFailure(_ message: Logger.Message, _ error: any Error) {
    ACPAgentTelemetry.logger(.subagentAnnouncement).error(
      message, metadata: ACPAgentTelemetry.errorMetadata(error))
  }
}
