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
    /// Makes the outlet of the announcer of a root session. The announcements
    /// go through this agent. The outlet keeps the agent weakly, so the
    /// announcer holds no strong reference back to it.
    ///
    /// - Parameters:
    ///   - root: The ACP id of the root session of the surface.
    ///   - runner: The runner of the surface, which finds the parent run of a
    ///     run.
    /// - Returns: The outlet.
    nonisolated func makeSubagentOutlet(root: SessionId, runner: AgentRunner) -> SubagentOutlet {
        SubagentOutlet(
            root: root,
            link: { [weak self] report in
                guard let self else {
                    return .unavailable
                }
                return await resolveAgentCallLink(of: report, root: root)
            },
            deliver: { [weak self] report, previous, link in
                guard let self else {
                    return .blocked
                }
                return await deliverSubagentReport(report, replacing: previous, link: link, root: root)
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
    /// run that no session started. The call sends nothing and records
    /// nothing in four cases. The parent is not in the table, is closed, has
    /// no connection, or is not known to the client yet.
    ///
    /// - Parameters:
    ///   - report: The report of the run.
    ///   - previous: The snapshot that the last sent update of the run made,
    ///     or `nil`.
    ///   - link: The wire id of the `agents` call that started the run, or
    ///     `nil` when the run has none or it is not known.
    ///   - root: The ACP id of the root session of the surface.
    /// - Returns: What was done.
    func deliverSubagentReport(
        _ report: SubagentReport, replacing previous: SubagentUpdate?, link: ToolCallId?, root: SessionId
    ) async -> SubagentDelivery {
        let parentId = parentSessionId(of: report, root: root)
        guard let parent = announcingParent(parentId) else {
            return .blocked
        }
        let target = makeSnapshot(of: report, replacing: previous, link: link)
        guard let patch = target.patch(replacing: previous) else {
            return .unchanged
        }
        await historySink(for: parentId, gate: parent.announcement)(.subagentUpdate(patch))
        return .sent(target)
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
        guard let callId = await parent.projector.runCallJoins.awaitToolCallId(for: token), !Task.isCancelled else {
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
    private nonisolated func parentSessionId(of report: SubagentReport, root: SessionId) -> SessionId {
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
            ACPAgentTelemetry.logger(.subagentAnnouncement).error(
                "The link of an agent run to its tool call did not encode. The announcement has no link.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return held
        }
    }
}
