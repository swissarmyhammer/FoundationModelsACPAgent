import Foundation
import FoundationModelsACP
import FoundationModelsHooks
import FoundationModelsRouter
import Logging

extension RoutedACPAgent {
    /// Closes one session and releases its resources.
    ///
    /// This is a MUST. A close during an active prompt cancels the prompt as
    /// `session/cancel` would, and the `idle` terminator with the `cancelled`
    /// stop reason goes out before this response. Then the session sweep runs
    /// through ``RoutedSession/close()`` — `deinit` does not run it — every
    /// descendant closes, the host-owned shell stream finishes, and the MCP
    /// servers shut down after the sweep. Recording closes; the transcript
    /// stays on disk, so the session stays listable and resumable.
    ///
    /// - Parameter params: The request naming the session to close.
    /// - Returns: The empty response. Close is idempotent: a second close of
    ///   the same session answers `{}` as well.
    /// - Throws: The order rule's invalid-request error, or
    ///   `RequestError.unknownSession` for an id no live session holds.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try await closeSession(params, from: .direct)
    }

    /// Closes one session for one connection: the work of
    /// ``closeSession(_:)``.
    ///
    /// - Parameters:
    ///   - params: The request naming the session to close.
    ///   - caller: The connection of the request.
    /// - Returns: The empty response.
    /// - Throws: The errors that ``closeSession(_:)`` names.
    func closeSession(_ params: CloseSessionRequest, from caller: ConnectionId) async throws -> CloseSessionResponse {
        try requireInitialized(before: ACPMethod.sessionClose, from: caller)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        await tearDownSession(params.sessionId, entry: entry)
        return CloseSessionResponse()
    }

    /// Deletes one session outright: a real delete of its session folder,
    /// which holds its `index.md` and its transcript, not a tombstone.
    /// Version control keeps what git recorded, so the response and the
    /// docs never claim the content is unrecoverable.
    ///
    /// An active session is closed first, with the full `session/close`
    /// semantics (``closeSession(_:)``, descendants included), then
    /// deleted. An id that never existed, or one already deleted, gives silent
    /// success: "nothing to remove" is not an error.
    ///
    /// The sessions of one working directory share one snapshot timeline. The
    /// delete removes that timeline when it deletes the last session of the
    /// working directory: no other session in the table and no other session
    /// recorded under a candidate root has the key
    /// (``removeSnapshotTimeline(of:recorded:)``). Only a delete removes it:
    /// `session/close` and the start of the agent keep it.
    ///
    /// - Parameter params: The request naming the session to delete.
    /// - Returns: The empty response.
    /// - Throws: The order rule's invalid-request error.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try await deleteSession(params, from: .direct)
    }

    /// Deletes one session for one connection: the work of
    /// ``deleteSession(_:)``.
    ///
    /// - Parameters:
    ///   - params: The request naming the session to delete.
    ///   - caller: The connection of the request.
    /// - Returns: The empty response.
    /// - Throws: The order rule's invalid-request error.
    func deleteSession(
        _ params: DeleteSessionRequest, from caller: ConnectionId
    ) async throws -> DeleteSessionResponse {
        try requireInitialized(before: ACPMethod.sessionDelete, from: caller)
        guard let rootId = ULID(ulidString: params.sessionId.rawValue) else {
            // A non-ULID id names no session this agent ever minted; a real
            // delete of nothing is silent success.
            return DeleteSessionResponse()
        }
        var roots = await candidateTranscriptRoots()
        let entry = sessions[params.sessionId]
        if let entry {
            roots.append(entry.transcriptDirectory.deletingLastPathComponent())
            await tearDownSession(params.sessionId, entry: entry)
            sessions.removeValue(forKey: params.sessionId)
            recordActiveSessions()
        }
        let recorded = Self.recordedSessions(under: roots)
        let sessionKey = snapshotKey(of: params.sessionId, workingDirectory: entry?.workingDirectory, recorded: recorded)
        removeSessionTree(ulidString: rootId.ulidString, from: roots)
        SnapshotSessionKeys.shared.forget(params.sessionId)
        if let sessionKey {
            await removeSnapshotTimeline(
                of: sessionKey, recorded: recorded.excluding(sessionId: params.sessionId))
        }
        return DeleteSessionResponse()
    }

    /// Adopts `descendant` as a child of `sessionId`, so `session/close`
    /// closes it too. A fork is this session's work: if it continued after
    /// the close, it would take the model from other sessions with no
    /// watcher. The runs
    /// of the `agents` tool are not registered here: the teardown stops them
    /// through `SessionSurface.stopAgentRuns()`.
    ///
    /// - Parameters:
    ///   - descendant: The child session to close at the parent's teardown.
    ///   - sessionId: The parent session in the table.
    func adoptDescendant(_ descendant: any RoutedSession, of sessionId: SessionId) {
        sessions[sessionId]?.descendants.append(descendant)
    }

    // MARK: - The close of the connection

    /// Tears down one connection after it closed (ACPA-5d, D120 d): removes
    /// its row from ``connections`` and frees each session that it owns. A
    /// freed session has no owner, and it is not closed: its work goes on
    /// (D68), each of its updates goes into its retained history, and any
    /// connection that can take it takes it with `session/resume`. A client
    /// can go away with no `session/close`: it closes its end of the wire,
    /// its input stream fails, or the host closes the connection. One
    /// `notice` record names the reason. The teardown also cancels each
    /// GraphQL tunnel subscription of the connection (ACPA-13), because no
    /// notification of it can reach the client.
    ///
    /// The teardown task of ``bind(connection:)`` calls it when
    /// `AgentSideConnection.closed` gives its reason. The connection already
    /// ended each inbound handler then, so no handler of it runs beside this
    /// teardown.
    ///
    /// The close of the sessions is the job of the host at its end
    /// (``closeOpenSessions()``), not of a connection close.
    ///
    /// - Parameters:
    ///   - id: The id of the closed connection.
    ///   - reason: Why the connection closed.
    func tearDownConnection(_ id: ConnectionId, after reason: ConnectionCloseReason) {
        var metadata: Logger.Metadata = [
            ACPAgentTelemetry.LogMetadataKey.connectionCloseReason: "\(Self.connectionCloseReasonName(reason))"
        ]
        if case .transportFailed(let error) = reason {
            metadata[ACPAgentTelemetry.LogMetadataKey.errorType] =
                "\(ACPAgentTelemetry.errorTypeName(of: error))"
        }
        ACPAgentTelemetry.logger(.sessionLifecycle).notice(
            "The connection closed. Its sessions go on with no owner.", metadata: metadata)
        connections.remove(id)
        graphQLSubscriptions.cancelAll(of: id)
    }

    /// Closes each open session of the agent, as `session/close` closes one:
    /// the shell stream finishes, the MCP servers shut down, and
    /// `session-history.json` is written. A session already closed is
    /// skipped. A host calls it at its end, after its connections closed,
    /// because a closed connection frees its sessions and does not close
    /// them (``tearDownConnection(_:after:)``), and `RoutedSession` does not
    /// run its sweep in `deinit`.
    ///
    /// After the sessions close, the call waits until the hook dispatcher
    /// delivered each post event (`HookDispatcher.drain()`). Thus the
    /// `SessionEnd` of each session and the last snapshots are complete
    /// before the host process ends, for `acp-agent acp` and for
    /// `acp-agent run`. Last, the call stops the watch of each `config.yaml`
    /// of the ``settingsStore`` (``SettingsStore/stopWatching()``), because
    /// no session reads the settings again.
    ///
    /// The agent stays usable: a later `session/resume` brings a closed
    /// session back.
    public func closeOpenSessions() async {
        for (sessionId, entry) in sessions where !entry.isClosed {
            await tearDownSession(sessionId, entry: entry)
        }
        await hooks.dispatcher.drain()
        await settingsStore.stopWatching()
    }

    /// Closes each open session that has no owner now, as `session/close`
    /// closes one, and waits until the hook dispatcher delivered each post
    /// event. A session that a bound connection or ``ConnectionId/direct``
    /// owns stays open, and the watch of the ``settingsStore`` goes on.
    ///
    /// A host that serves many connections in turn calls it to end the
    /// sessions that no client took after their connection closed. The test
    /// harness calls it at the close of one harness, so that the sessions of
    /// that harness end inside its test, while another harness on the same
    /// agent keeps its own sessions.
    public func closeSessionsWithNoOwner() async {
        for (sessionId, entry) in sessions
        where !entry.isClosed && connections.owner(of: sessionId) == nil {
            await tearDownSession(sessionId, entry: entry)
        }
        await hooks.dispatcher.drain()
    }

    /// The name of a close reason, for the log record of a connection close.
    /// The error of a failed transport is not in the name, because an error
    /// message can hold content.
    ///
    /// - Parameter reason: Why the connection closed.
    /// - Returns: `endOfInput`, `transportFailed` or `closedLocally`.
    static func connectionCloseReasonName(_ reason: ConnectionCloseReason) -> String {
        switch reason {
        case .endOfInput: "endOfInput"
        case .transportFailed: "transportFailed"
        case .closedLocally: "closedLocally"
        }
    }

    // MARK: - The teardown

    /// Runs the full `session/close` teardown of one session: cancel the open prompts,
    /// stop the agent runs, run the session sweep, close every descendant,
    /// finish the shell stream, shut the MCP servers down, and write the
    /// retained history to its file — in that order. The entry stays in the
    /// table, marked closed, so the session is still resumable.
    ///
    /// It is idempotent: a session already closed has released its resources,
    /// so this returns at once.
    ///
    /// - Parameters:
    ///   - sessionId: The session to tear down.
    ///   - entry: The session's table entry, captured before the teardown.
    func tearDownSession(_ sessionId: SessionId, entry: ActiveSession) async {
        guard !entry.isClosed else {
            return
        }
        // A close during open prompts cancels them as `session/cancel` would,
        // and waits for the end of each prompt before the close response, so
        // a client with a spinner learns that the prompts ended with the
        // `idle(cancelled)` terminator.
        if !entry.openPrompts.isEmpty {
            for owner in entry.openPrompts {
                await owner.noteCancelRequested()
            }
            entry.session.cancelAll()
            for owner in entry.openPrompts {
                await owner.waitForPromptEnd()
            }
        }
        // The agent runs stop first: the Router does not know the runs that
        // a `start agent` call started, thus the session sweep below cannot
        // cancel them, and a run that outlives the root session would send
        // its final message to a closed session.
        await entry.surface.stopAgentRuns()
        // The session sweep: it cancels every background run, rejects every
        // pending elicitation, journals the terminal events, and finishes
        // every `streamSessionEvents()` subscription. `deinit` does not run
        // it, so the host must call `close()`.
        await entry.session.close()
        // The closed Router session released its store key, so the
        // `snapshots` endpoints no longer act as it for the ACP session.
        SnapshotSessionKeys.shared.forgetLiveOwner(of: sessionId)
        for descendant in entry.descendants {
            await descendant.close()
        }
        // The subscription of the session ended with the close, so the
        // projector sends each event of it, and then it stops.
        await entry.projector.stop(after: [entry.session.id])
        // Mark closed and finish the host-owned shell stream, then shut the
        // MCP servers down — after the sweep, never before, so the settling
        // runs still have their transports. The pool
        // stops the attached `SurfaceRefresher` first.
        markSessionClosed(sessionId)
        await entry.surface.shutdown()
        // The retained history goes to its file last, with each update that
        // came after the last prompt, so a new process resumes it whole.
        writeHistory(of: sessionId)
    }

    // MARK: - The disk removal

    /// The recording roots of every project in the project store of the
    /// home, resolved through the settings of each project
    /// (``RegisteredRecordingRoots/resolve(in:)``). A delete of a session no
    /// longer in the table searches these for the session's directory.
    ///
    /// A project store that cannot be read, or a project whose settings
    /// cannot be read, gives no root and one `warning` record with the type
    /// of the error. The delete then searches the other roots.
    ///
    /// - Returns: The resolved recording roots, one per registered project
    ///   whose settings can be read.
    private func candidateTranscriptRoots() async -> [URL] {
        let resolution = await RegisteredRecordingRoots.resolve(in: settingsStore)
        for failure in resolution.failures {
            switch failure {
            case .registryUnreadable(let error):
                Self.logCandidateRootFailure(
                    "The project store cannot be read. The delete searches no registered project.", error: error)
            case .projectUnreadable(_, let error):
                Self.logCandidateRootFailure(
                    "The settings of a registered project cannot be read. The delete does not search that project.",
                    error: error)
            }
        }
        return resolution.roots
    }

    /// Writes one `warning` record about a recording root that a delete
    /// cannot search. The record holds the type of the error, and no path,
    /// because a path can hold content.
    ///
    /// - Parameters:
    ///   - message: The fixed message of the record.
    ///   - error: The error of the read.
    private static func logCandidateRootFailure(_ message: Logger.Message, error: any Error) {
        ACPAgentTelemetry.logger(.sessionLifecycle).warning(message, metadata: ACPAgentTelemetry.errorMetadata(error))
    }

    /// Removes the session's folder under each distinct root: the folder
    /// holds the whole record of the session, its `index.md` and its
    /// transcript, so no other file changes. A failed removal is logged and
    /// the walk continues, so a delete never fails partway and a shared root
    /// is swept once.
    ///
    /// - Parameters:
    ///   - ulidString: The session's canonical ULID string, the name of its
    ///     directory under a recording root.
    ///   - roots: The candidate recording roots to sweep.
    private func removeSessionTree(ulidString: String, from roots: [URL]) {
        var swept: Set<String> = []
        for root in roots where swept.insert(root.standardizedFileURL.path).inserted {
            removeSessionDirectory(ulidString: ulidString, under: root)
        }
    }

    /// Removes `<root>/<ulidString>/` when it is present. An absent directory
    /// is silent success; a removal error is logged.
    ///
    /// - Parameters:
    ///   - ulidString: The session directory's name.
    ///   - root: The recording root the directory lives under.
    private func removeSessionDirectory(ulidString: String, under root: URL) {
        let directory = root.appendingPathComponent(ulidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logSessionDeleteError(
                "The delete could not remove the transcript directory of a session.",
                ulidString: ulidString, error: error)
        }
    }

    // MARK: - The snapshot timeline of a delete

    /// The sessions recorded under the candidate roots of a delete, read
    /// before the delete removes the folder of its session.
    private struct RecordedSessions {
        /// The record of each session that a root holds.
        let records: [SessionRecord]

        /// Whether each root could be read. When one could not, a session of
        /// any working directory can be missing from ``records``.
        let isComplete: Bool

        /// These records with no record of `sessionId`.
        ///
        /// - Parameter sessionId: The session to leave out.
        /// - Returns: The other records, with the same completeness.
        func excluding(sessionId: SessionId) -> RecordedSessions {
            RecordedSessions(
                records: records.filter { $0.sessionId.description != sessionId.rawValue }, isComplete: isComplete)
        }

        /// Whether a recorded session works in a folder whose key is
        /// `sessionKey`.
        ///
        /// - Parameter sessionKey: The key of a working directory.
        /// - Returns: `true` when a record has the key.
        func hasSession(withKey sessionKey: String) -> Bool {
            records.contains { AgentHome.projectKey(of: $0.workingDirectory) == sessionKey }
        }
    }

    /// Reads the sessions recorded under each distinct root. A root with no
    /// folder holds no session. A root that cannot be read gives one
    /// `warning` record with the type of the error, and makes the result
    /// incomplete.
    ///
    /// - Parameter roots: The candidate recording roots of the delete.
    /// - Returns: The records, and whether each root could be read.
    private static func recordedSessions(under roots: [URL]) -> RecordedSessions {
        var records: [SessionRecord] = []
        var isComplete = true
        var read: Set<String> = []
        for root in roots where read.insert(root.standardizedFileURL.path).inserted {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                records += try RouterSessionDirectory.recordedSessions(in: root)
            } catch {
                isComplete = false
                logCandidateRootFailure(
                    "The sessions of a recording root cannot be read. The delete keeps the snapshot timeline.",
                    error: error)
            }
        }
        return RecordedSessions(records: records, isComplete: isComplete)
    }

    /// The snapshot key of a session: the key that the agent recorded for it
    /// (``SnapshotSessionKeys``), else the key of its working directory, from
    /// its table entry or from its record.
    ///
    /// - Parameters:
    ///   - sessionId: The session.
    ///   - workingDirectory: The working directory of its table entry, or
    ///     `nil` when the table has no entry.
    ///   - recorded: The recorded sessions, which can hold its record.
    /// - Returns: The key, or `nil` when the agent knows no working
    ///   directory of the session.
    private func snapshotKey(of sessionId: SessionId, workingDirectory: URL?, recorded: RecordedSessions) -> String? {
        if let sessionKey = SnapshotSessionKeys.shared.sessionKey(of: sessionId.rawValue) {
            return sessionKey
        }
        let record = recorded.records.first { $0.sessionId.description == sessionId.rawValue }
        return (workingDirectory ?? record?.workingDirectory).map(AgentHome.projectKey(of:))
    }

    /// Whether a session other than the deleted one uses the timeline of
    /// `sessionKey`: an entry of the table, a recorded session of the same
    /// working directory, or a session of a root that could not be read.
    ///
    /// - Parameters:
    ///   - sessionKey: The key of the timeline.
    ///   - recorded: The recorded sessions with no record of the deleted
    ///     session.
    /// - Returns: `true` when the timeline must stay.
    private func timelineHasOtherSessions(_ sessionKey: String, recorded: RecordedSessions) -> Bool {
        let inTable = sessions.contains { sessionId, entry in
            snapshotKey(of: sessionId, workingDirectory: entry.workingDirectory, recorded: recorded) == sessionKey
        }
        return inTable || recorded.hasSession(withKey: sessionKey) || !recorded.isComplete
    }

    /// Removes the snapshot timeline of `sessionKey`, its shadow folder in
    /// the ``AgentHooks/snapshotStore``, when no other session uses it
    /// (``timelineHasOtherSessions(_:recorded:)``). Then the timeline stays,
    /// and one `notice` record names the key.
    ///
    /// The teardown of the session sent its `SessionEnd`, and `SnapshotHook`
    /// releases the key on that event. The hook gets the event on the queue
    /// of the dispatcher, thus the call drains the dispatcher first. Then the
    /// release is done before the remove.
    ///
    /// The delete never fails because of the timeline. When another owner
    /// has the key open, the timeline stays and one `notice` record names the
    /// key. Each other error gives one `error` record with the key and the
    /// error case. A key with no shadow folder is not an error.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key of the timeline: the key of the
    ///     working directory of the deleted session.
    ///   - recorded: The recorded sessions with no record of the deleted
    ///     session.
    private func removeSnapshotTimeline(of sessionKey: String, recorded: RecordedSessions) async {
        guard !timelineHasOtherSessions(sessionKey, recorded: recorded) else {
            ACPAgentTelemetry.logger(.sessionLifecycle).notice(
                "Another session of the working directory is left. The delete keeps its snapshot timeline.",
                metadata: ACPAgentTelemetry.snapshotKeyMetadata(sessionKey))
            return
        }
        await hooks.dispatcher.drain()
        do {
            try await hooks.snapshotStore.remove(sessionKey: sessionKey)
        } catch SnapshotError.sessionKeyOpen {
            ACPAgentTelemetry.logger(.sessionLifecycle).notice(
                "Another owner has the session key open. The delete keeps its snapshot timeline.",
                metadata: ACPAgentTelemetry.snapshotKeyMetadata(sessionKey))
        } catch {
            ACPAgentTelemetry.logger(.sessionLifecycle).error(
                "The delete could not remove the snapshot timeline of a session key.",
                metadata: ACPAgentTelemetry.snapshotKeyMetadata(sessionKey, error: error))
        }
    }

    /// Writes one `error` record for a removal that failed during a delete.
    /// The metadata holds the session id and the error type, from
    /// `ACPAgentTelemetry.errorMetadata(_:sessionId:)`. The message is a
    /// fixed text that tells which removal failed.
    ///
    /// - Parameters:
    ///   - message: The fixed text that tells which removal failed.
    ///   - ulidString: The canonical ULID string of the deleted session.
    ///   - error: The error that the removal threw.
    private func logSessionDeleteError(
        _ message: Logger.Message, ulidString: String, error: any Error
    ) {
        ACPAgentTelemetry.logger(.sessionLifecycle).error(
            message,
            metadata: ACPAgentTelemetry.errorMetadata(
                error, sessionId: SessionId(rawValue: ulidString)))
    }
}
