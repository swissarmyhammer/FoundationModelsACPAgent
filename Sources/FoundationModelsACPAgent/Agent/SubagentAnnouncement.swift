import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Logging

extension SubagentUpdate {
    /// The fields of this snapshot that differ from the snapshot that the
    /// client holds. An omitted field is unchanged for the client.
    ///
    /// - Parameter previous: The snapshot that the last sent update made, or
    ///   `nil` when the client does not know the child yet.
    /// - Returns: This snapshot with no previous snapshot, the changed fields
    ///   only with one, or `nil` when nothing changed.
    func patch(replacing previous: SubagentUpdate?) -> SubagentUpdate? {
        guard let previous else {
            return self
        }
        let patch = SubagentUpdate(
            sessionId: sessionId,
            additionalDirectories: Self.changed(additionalDirectories, from: previous.additionalDirectories),
            capabilities: Self.changed(capabilities, from: previous.capabilities),
            cwd: Self.changed(cwd, from: previous.cwd),
            description: Self.changed(description, from: previous.description),
            state: Self.changed(state, from: previous.state),
            title: Self.changed(title, from: previous.title),
            meta: Self.changed(meta, from: previous.meta))
        return patch == SubagentUpdate(sessionId: sessionId) ? nil : patch
    }

    /// A field as a patch: the new value when it differs, and omitted when it
    /// is the value that the client holds.
    ///
    /// - Parameters:
    ///   - field: The new value of the field.
    ///   - previous: The value that the client holds.
    /// - Returns: `field`, or `.unchanged` when it equals `previous`.
    private static func changed<Value>(_ field: PatchField<Value>, from previous: PatchField<Value>) -> PatchField<Value> {
        field == previous ? .unchanged : field
    }
}

extension RoutedACPAgent {
    /// Makes the outlet of the announcer of a root session: the announcements
    /// go through this agent, and the agent keeps no strong reference from the
    /// announcer back to itself.
    ///
    /// - Parameters:
    ///   - root: The ACP id of the root session of the surface.
    ///   - runner: The runner of the surface, which finds the parent run of a
    ///     run.
    /// - Returns: The outlet.
    nonisolated func makeSubagentOutlet(root: SessionId, runner: AgentRunner) -> SubagentOutlet {
        SubagentOutlet(
            root: root,
            deliver: { [weak self] report, previous in
                guard let self else {
                    return .blocked
                }
                return await deliverSubagentReport(report, replacing: previous, root: root)
            },
            announced: { [weak self] child in
                await self?.openAnnouncementGate(of: child)
            },
            parentReport: { runID in
                await runner.run(id: runID).map(SubagentReport.init(run:))
            })
    }

    /// Sends one `subagent_update` for a report, on the session of the parent
    /// of the run, through the history sink of that session. The update is in
    /// the retained history of the parent, so a resume replays it.
    ///
    /// The update carries all fields when the client does not know the child
    /// (`previous` is `nil`), and only the changed fields after that. The
    /// parent is the session that started the run, and the root session for a
    /// run that no session started. Nothing is sent, and nothing is recorded,
    /// when the parent is not in the table, is closed, has no connection, or
    /// is not known to the client yet.
    ///
    /// - Parameters:
    ///   - report: The report of the run.
    ///   - previous: The snapshot that the last sent update of the run made,
    ///     or `nil`.
    ///   - root: The ACP id of the root session of the surface.
    /// - Returns: What was done.
    func deliverSubagentReport(
        _ report: SubagentReport, replacing previous: SubagentUpdate?, root: SessionId
    ) async -> SubagentDelivery {
        let parentId = report.caller.map { SessionId(rawValue: $0.description) } ?? root
        guard let parent = announcingParent(parentId) else {
            return .blocked
        }
        let target = await makeSnapshot(of: report, replacing: previous, below: parent)
        guard let patch = target.patch(replacing: previous) else {
            return .unchanged
        }
        // The link can wait, and the actor can run other work meanwhile, so
        // the parent is checked again before the send.
        guard let current = announcingParent(parentId) else {
            return .blocked
        }
        await historySink(for: parentId, gate: current.announcement)(.subagentUpdate(patch))
        return .sent(target)
    }

    /// Opens the gate of a session that the client knows now. A session that
    /// the table does not hold yet starts open when its entry is made
    /// (``registerSession(_:sessionId:parent:build:)``).
    ///
    /// - Parameter child: The ACP id of the child.
    func openAnnouncementGate(of child: SessionId) {
        sessions[child]?.announcement.open()
    }

    /// The entry of a session that can take an announcement now.
    ///
    /// - Parameter sessionId: The session.
    /// - Returns: The entry, or `nil` when the session is not in the table, is
    ///   closed, has no connection with an outbound path, or is not known to
    ///   the client yet (its gate is closed).
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
    /// The place of the child is the place of its parent, which it borrows.
    /// The link to the `agents` call is read once, at the announcement, and
    /// kept after that. Sending a partial `_meta.sah` object is never right,
    /// because ACP patches `_meta` by top-level key, so a later update never
    /// carries `_meta` at all.
    ///
    /// - Parameters:
    ///   - report: The report of the run.
    ///   - previous: The snapshot that the last sent update made, or `nil`.
    ///   - parent: The entry of the parent session.
    /// - Returns: The snapshot.
    private func makeSnapshot(
        of report: SubagentReport, replacing previous: SubagentUpdate?, below parent: ActiveSession
    ) async -> SubagentUpdate {
        let meta =
            if let previous {
                previous.meta
            } else {
                await agentCallLink(of: report, in: parent)
            }
        return SubagentUpdate(
            sessionId: SessionId(rawValue: report.runID.description),
            additionalDirectories: .value(parent.additionalRoots.compactMap { AbsolutePath(absolute: $0.path) }),
            capabilities: .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities())),
            cwd: AbsolutePath(absolute: parent.workingDirectory.path).map { .value($0) } ?? .unchanged,
            description: report.description.map { .value($0) } ?? .unchanged,
            state: .value(report.state),
            title: .value(report.title),
            meta: meta)
    }

    /// The `_meta` that links the announcement to the `agents` tool call that
    /// started the run: `_meta.sah.agentRun.toolCallId`.
    ///
    /// The Router records the completion token of the call as the spawn of the
    /// session of the run. The wire id of the call is the entry of that token
    /// in the join table of the parent. The projection of the parent writes the
    /// entry when it handles the open record of the call, and the observer of
    /// the run can see the first event of the run before that, so the call waits
    /// for the entry (``RunCallJoinTable/awaitToolCallId(for:)``).
    ///
    /// - Parameters:
    ///   - report: The report of the run.
    ///   - parent: The entry of the parent session.
    /// - Returns: The `_meta` value, or `.unchanged` when no tool call started
    ///   the run (a run of the host), or the record of the spawn is not there.
    private func agentCallLink(of report: SubagentReport, in parent: ActiveSession) async -> PatchField<FoundationModelsACP.JSONValue> {
        guard let token = await spawnToken(of: report) else {
            return .unchanged
        }
        let toolCallId = await parent.projector.runCallJoins.awaitToolCallId(for: token)
        do {
            return .value(try SAH.AgentRun(toolCallId: toolCallId).inject(into: nil))
        } catch {
            ACPAgentTelemetry.logger(.subagentAnnouncement).error(
                "The link of an agent run to its tool call did not encode. The announcement has no link.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return .unchanged
        }
    }

    /// The completion token of the call of the caller that started a run, as
    /// the Router recorded it in the `index.md` of the session of the run (the
    /// spawn of the record).
    ///
    /// The read goes through the recording root of the run, which the run
    /// itself names (``AgentRun/recordingDirectory``), so it needs no recording
    /// root of the host. It runs off the actor, because it reads files.
    ///
    /// - Parameter report: The report of the run.
    /// - Returns: The token, or `nil` for a run that no session started, a run
    ///   with no recording, or a record that does not read.
    private nonisolated func spawnToken(of report: SubagentReport) async -> String? {
        guard report.caller != nil, let root = report.recordingRoot else {
            return nil
        }
        do {
            let records = try RouterSessionDirectory.recordedSessions(in: root)
            return records.first { $0.sessionId == report.runID }?.agentSpawn?.parentToolCallId
        } catch {
            ACPAgentTelemetry.logger(.subagentAnnouncement).notice(
                "The record of an agent run did not read. The announcement has no link.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return nil
        }
    }
}
