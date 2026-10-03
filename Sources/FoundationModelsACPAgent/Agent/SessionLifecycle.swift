import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import Logging

extension RoutedACPAgent {
    /// Closes one session and releases its resources (plan.md §10.1).
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
    ///   `RequestError.unknownSession` for an id no live session holds
    ///   (plan.md §10.1).
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try requireInitialized(before: ACPMethod.sessionClose)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        await tearDownSession(params.sessionId, entry: entry)
        return CloseSessionResponse()
    }

    /// Deletes one session outright (plan.md §10.2): a real delete of the
    /// working-tree transcript directory and the `sessions.jsonl` entry, not a
    /// tombstone. Version control keeps what git recorded, so the response and
    /// the docs never claim the content is unrecoverable.
    ///
    /// An active session is closed first, with the full §10.1 semantics, then
    /// deleted. An id that never existed, or one already deleted, gives silent
    /// success: "nothing to remove" is not an error.
    ///
    /// - Parameter params: The request naming the session to delete.
    /// - Returns: The empty response.
    /// - Throws: The order rule's invalid-request error.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try requireInitialized(before: ACPMethod.sessionDelete)
        guard let rootId = ULID(ulidString: params.sessionId.rawValue) else {
            // A non-ULID id names no session this agent ever minted; a real
            // delete of nothing is silent success (plan.md §10.2).
            return DeleteSessionResponse()
        }
        var roots = candidateTranscriptRoots()
        if let entry = sessions[params.sessionId] {
            roots.append(entry.transcriptDirectory.deletingLastPathComponent())
            await tearDownSession(params.sessionId, entry: entry)
            sessions.removeValue(forKey: params.sessionId)
            recordActiveSessions()
        }
        removeSessionTree(ulidString: rootId.ulidString, from: roots)
        return DeleteSessionResponse()
    }

    /// Adopts `descendant` as a child of `sessionId`, so `session/close`
    /// closes it too (plan.md §10.1). A fork or a spawned sub-agent is this
    /// session's work; a later Multitool agents capability registers each
    /// spawned session here, and this iteration registers forks.
    ///
    /// - Parameters:
    ///   - descendant: The child session to close at the parent's teardown.
    ///   - sessionId: The parent session in the table.
    func adoptDescendant(_ descendant: any RoutedSession, of sessionId: SessionId) {
        sessions[sessionId]?.descendants.append(descendant)
    }

    // MARK: - The close of the connection (plan.md §10.1)

    /// Closes each open session after the bound connection closed, as
    /// `session/close` closes one (plan.md §10.1: "so does agent shutdown").
    ///
    /// The teardown task of ``bind(connection:)`` calls it when
    /// `AgentSideConnection.closed` gives its reason. A client can go away
    /// with no `session/close`: it closes its end of the wire, its input
    /// stream fails, or the host closes the connection. Each open session
    /// then gets the full teardown here: the shell stream finishes, the MCP
    /// servers shut down, and `session-history.json` is written. A session
    /// already closed is skipped. One `notice` record names the reason.
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

    // MARK: - The teardown (plan.md §10.1)

    /// Runs the full §10.1 teardown of one session: cancel the running prompt,
    /// run the session sweep, close every descendant, finish the shell stream,
    /// shut the MCP servers down, and write the retained history to its file
    /// — in that order. The entry stays in the table, marked closed, so the
    /// session is still resumable.
    ///
    /// It is idempotent: a session already closed has released its resources,
    /// so this returns at once.
    ///
    /// - Parameters:
    ///   - sessionId: The session to tear down.
    ///   - entry: The session's table entry, captured before the teardown.
    private func tearDownSession(_ sessionId: SessionId, entry: ActiveSession) async {
        guard !entry.isClosed else {
            return
        }
        // A close during an active prompt cancels it as `session/cancel` would,
        // and waits for the `idle(cancelled)` terminator to go out before the
        // close response (plan.md §10.1). Every pending elicitation is
        // answered with `cancel` first (plan.md §16): the suspended tool must
        // resume, or the prompt's drive loop never ends and this wait holds
        // forever — Router's mailbox does not resume on task cancellation.
        if let promptState = entry.activePrompt {
            await promptState.noteCancelRequested()
            await entry.activeElicitationRelay?.cancelPendingElicitations()
            await entry.session.cancel()
            await promptState.waitForPromptEnd()
        }
        // The session sweep: it cancels every background run, rejects every
        // pending elicitation, journals the terminal events, and finishes
        // every `streamSessionEvents()` subscription. `deinit` does not run
        // it, so the host must call `close()`.
        await entry.session.close()
        for descendant in entry.descendants {
            await descendant.close()
        }
        // Mark closed and finish the host-owned shell stream, then shut the
        // MCP servers down — after the sweep, never before, so the settling
        // runs still have their transports (plan.md §10.1, §11.5). The pool
        // stops the attached `SurfaceRefresher` first.
        markSessionClosed(sessionId)
        await entry.surface.shutdown()
        // The retained history goes to its file last, with each update that
        // came after the last prompt, so a new process resumes it whole.
        writeHistory(of: sessionId)
    }

    // MARK: - The disk removal (plan.md §10.2)

    /// The recording roots of every registered project (plan.md §4.5),
    /// resolved through each project's own dotfolder stack — the same
    /// resolution `session/list` reads. A delete of a session no longer in
    /// the table searches these for the session's directory.
    ///
    /// - Returns: The resolved recording roots, one per registered project;
    ///   the empty array when the registry cannot be read.
    private func candidateTranscriptRoots() -> [URL] {
        guard let projects = try? ProjectRegistry(directory: registryUserLayerRoot()).projects()
        else {
            return []
        }
        return projects.compactMap { project in
            try? loadSessionContext(
                workingDirectory: URL(fileURLWithPath: project.path, isDirectory: true)
            ).transcriptRoot
        }
    }

    /// Removes the session's transcript directory and its index line under
    /// each distinct root (plan.md §10.2). A failed removal is logged and the
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
    /// is silent success (plan.md §10.2); a removal error is logged.
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
