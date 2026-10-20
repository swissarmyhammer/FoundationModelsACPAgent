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
        try requireInitialized(before: ACPMethod.sessionClose)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        await tearDownSession(params.sessionId, entry: entry)
        return CloseSessionResponse()
    }

    /// Deletes one session outright: a real delete of the
    /// working-tree transcript directory and the `sessions.jsonl` entry, not a
    /// tombstone. Version control keeps what git recorded, so the response and
    /// the docs never claim the content is unrecoverable.
    ///
    /// An active session is closed first, with the full `session/close`
    /// semantics (``closeSession(_:)``, descendants included), then
    /// deleted. An id that never existed, or one already deleted, gives silent
    /// success: "nothing to remove" is not an error.
    ///
    /// The delete also removes the snapshot timeline of the session key, the
    /// ACP session id (``removeSnapshotTimeline(sessionKey:)``). Only a delete
    /// removes it: `session/close` and the start of the agent keep it.
    ///
    /// - Parameter params: The request naming the session to delete.
    /// - Returns: The empty response.
    /// - Throws: The order rule's invalid-request error.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try requireInitialized(before: ACPMethod.sessionDelete)
        guard let rootId = ULID(ulidString: params.sessionId.rawValue) else {
            // A non-ULID id names no session this agent ever minted; a real
            // delete of nothing is silent success.
            return DeleteSessionResponse()
        }
        var roots = await candidateTranscriptRoots()
        if let entry = sessions[params.sessionId] {
            roots.append(entry.transcriptDirectory.deletingLastPathComponent())
            await tearDownSession(params.sessionId, entry: entry)
            sessions.removeValue(forKey: params.sessionId)
            recordActiveSessions()
        }
        removeSessionTree(ulidString: rootId.ulidString, from: roots)
        await removeSnapshotTimeline(sessionKey: params.sessionId.rawValue)
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

    /// Closes each open session after the bound connection closed, as
    /// `session/close` closes one. Agent shutdown must close each session
    /// too, because `RoutedSession` does not run its sweep in `deinit`.
    ///
    /// The teardown task of ``bind(connection:)`` calls it when
    /// `AgentSideConnection.closed` gives its reason. A client can go away
    /// with no `session/close`: it closes its end of the wire, its input
    /// stream fails, or the host closes the connection. Each open session
    /// then gets the full teardown here: the shell stream finishes, the MCP
    /// servers shut down, and `session-history.json` is written. A session
    /// already closed is skipped. One `notice` record names the reason.
    ///
    /// After the sessions close, the call waits until the hook dispatcher
    /// delivered each post event (`HookDispatcher.drain()`). Thus the
    /// `SessionEnd` of each session and the last snapshots are complete
    /// before the host process ends, for `acp-agent acp` and for
    /// `acp-agent run`.
    ///
    /// The connection already ended each inbound handler when `closed`
    /// gives its reason, so no handler runs beside this teardown.
    ///
    /// - Parameter reason: Why the connection closed.
    func closeOpenSessions(after reason: ConnectionCloseReason) async {
        var metadata: Logger.Metadata = [
            ACPAgentTelemetry.LogMetadataKey.connectionCloseReason: "\(Self.connectionCloseReasonName(reason))"
        ]
        if case .transportFailed(let error) = reason {
            metadata[ACPAgentTelemetry.LogMetadataKey.errorType] =
                "\(ACPAgentTelemetry.errorTypeName(of: error))"
        }
        ACPAgentTelemetry.logger(.sessionLifecycle).notice(
            "The connection closed. The agent closes each open session.", metadata: metadata)
        for (sessionId, entry) in sessions where !entry.isClosed {
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

    /// The recording roots of every project in the user-layer project
    /// registry, resolved through the settings of each project
    /// (``loadSessionContext(workingDirectory:)``). A delete of a session no
    /// longer in the table searches these for the session's directory.
    ///
    /// A registry that cannot be read, or a project whose settings cannot be
    /// read, gives no root and one `warning` record with the type of the
    /// error. The delete then searches the other roots.
    ///
    /// - Returns: The resolved recording roots, one per registered project
    ///   whose settings can be read.
    private func candidateTranscriptRoots() async -> [URL] {
        let projects: [ProjectRegistryRecord]
        do {
            projects = try ProjectRegistry(directory: registryUserLayerRoot()).projects()
        } catch {
            Self.logCandidateRootFailure(
                "The project registry cannot be read. The delete searches no registered project.", error: error)
            return []
        }
        var roots: [URL] = []
        for project in projects {
            do {
                roots.append(
                    try await loadSessionContext(
                        workingDirectory: URL(fileURLWithPath: project.path, isDirectory: true)
                    ).transcriptRoot)
            } catch {
                Self.logCandidateRootFailure(
                    "The settings of a registered project cannot be read. The delete does not search that project.",
                    error: error)
            }
        }
        return roots
    }

    /// Writes one `warning` record about a recording root that a delete
    /// cannot search. The record holds the type of the error, and no path,
    /// because a path can hold content.
    ///
    /// - Parameters:
    ///   - message: The fixed message of the record.
    ///   - error: The error of the read.
    private static func logCandidateRootFailure(_ message: Logger.Message, error: any Error) {
        ACPAgentTelemetry.logger(.sessionLifecycle).warning(
            message,
            metadata: [ACPAgentTelemetry.LogMetadataKey.errorType: "\(ACPAgentTelemetry.errorTypeName(of: error))"])
    }

    /// Removes the session's transcript directory and its index line under
    /// each distinct root. A failed removal is logged and the
    /// walk continues, so a delete never fails partway and a shared root is
    /// swept once.
    ///
    /// - Parameters:
    ///   - ulidString: The session's canonical ULID string, the name of its
    ///     directory under a recording root.
    ///   - roots: The candidate recording roots to sweep.
    private func removeSessionTree(ulidString: String, from roots: [URL]) {
        var swept: Set<String> = []
        for root in roots where swept.insert(root.standardizedFileURL.path).inserted {
            removeSessionDirectory(ulidString: ulidString, under: root)
            removeIndexRecord(ulidString: ulidString, under: root)
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

    /// Removes the session's `sessions.jsonl` line under `root`. A read or a
    /// rewrite error is logged and swallowed, so a damaged index never fails
    /// the delete.
    ///
    /// - Parameters:
    ///   - ulidString: The session id whose index line to drop.
    ///   - root: The recording root whose index to rewrite.
    private func removeIndexRecord(ulidString: String, under root: URL) {
        do {
            try SessionIndex(root: root).removeRecords(sessionId: ulidString)
        } catch {
            logSessionDeleteError(
                "The delete could not remove the sessions.jsonl record of a session.",
                ulidString: ulidString, error: error)
        }
    }

    /// Removes the snapshot timeline of `sessionKey`: its shadow folder in
    /// the ``AgentHooks/snapshotStore``.
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
    /// - Parameter sessionKey: The session key of the timeline: the ACP
    ///   session id.
    private func removeSnapshotTimeline(sessionKey: String) async {
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
