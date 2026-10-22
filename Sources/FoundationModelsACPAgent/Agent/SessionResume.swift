import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The replay cursor of one resume: an inclusive position
/// in the retained history. `start` is the first variant; a resume from a
/// message id adds a case here and a starting rule in
/// `SessionMergeEngine.replayUpdates(from:)` — the replay path never
/// hardcodes replay-everything.
enum ReplayCursor: Equatable, Sendable {
    /// Replay the whole retained history.
    case start
}

extension RequestError {
    /// The cwd-mismatch refusal: the request `cwd` MUST
    /// equal the recorded original, and a mismatch is an error, never a
    /// silent re-root. Invalid params, with the id and both directories
    /// in `data`.
    ///
    /// - Parameters:
    ///   - id: The session the client tried to resume.
    ///   - requested: The request's cwd path.
    ///   - recorded: The cwd Router recorded at creation.
    /// - Returns: The typed invalid-params error.
    static func mismatchedWorkingDirectory(
        id: SessionId, requested: String, recorded: String
    ) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object([
                "sessionId": .string(id.rawValue),
                "cwd": .string(requested),
                "recordedCwd": .string(recorded),
            ]))
    }

    /// The `data.code` of ``sessionHasOwner(id:)``, for a client that tells
    /// the refusals apart by code.
    static let sessionHasOwnerCode = "SESSION_HAS_OWNER"

    /// The reason of ``sessionHasOwner(id:)``.
    private static let sessionHasOwnerReason =
        "the session has an owner, and an external connection cannot take it"

    /// The owner refusal (D120 c): an `external` connection asked to take a
    /// session that another connection owns. Invalid request, with the id,
    /// ``sessionHasOwnerCode`` and the reason in `data`. The owner does not
    /// change, and the session goes on.
    ///
    /// - Parameter id: The session the connection tried to take.
    /// - Returns: The typed invalid-request error.
    static func sessionHasOwner(id: SessionId) -> RequestError {
        RequestError(
            code: .invalidRequest,
            message: RequestError.invalidRequest.message,
            data: .object([
                "sessionId": .string(id.rawValue),
                "code": .string(sessionHasOwnerCode),
                "reason": .string(sessionHasOwnerReason),
            ]))
    }

    /// The unknown replay-cursor refusal: a cursor type
    /// this agent cannot honor must not degrade to a silent no-replay.
    /// Invalid params, with the refused type in `data`.
    ///
    /// - Parameter type: The cursor's wire `type` value.
    /// - Returns: The typed invalid-params error.
    static func unknownReplayCursor(_ type: String) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object(["replayFrom": .string(type)]))
    }
}

extension RoutedACPAgent {
    /// The key that carries the missing-tool report in the resume
    /// response's `_meta`. An extension goes in `_meta`, never at the root
    /// of a spec-defined type.
    static let missingToolsMetaKey = "missingTools"

    /// Resumes one recorded root session.
    ///
    /// The order is deliberate: the cwd equality pre-check runs through
    /// the synchronous `recordedWorkingDirectory` BEFORE any composition
    /// or restore, so a mismatch or an unknown id never builds a session
    /// only to throw it away. Then this package's side is reassembled
    /// from the recorded cwd — the config layer, the instructions, the
    /// tools, the confinement — and Router restores the session itself
    /// with the freshly assembled instructions and roster. The client's
    /// `additionalDirectories` and `mcpServers` are authoritative on each
    /// reconnect. Replay of the retained history and of the recorded plans,
    /// when asked for, goes out before the response returns
    /// (``resumedHistory(kept:directory:rootId:sessionId:)``).
    ///
    /// The agent never makes a session directory. When the recorded cwd or
    /// a requested additional root does not exist, the resume is
    /// replay-only: it replays the history, mounts no tool surface, and
    /// each later `session/prompt` is refused. `session/close` and
    /// `session/delete` work as for each other session.
    ///
    /// The request runs in one server span, and it writes one "enter" record
    /// when it starts, because the composition and the restore can take a
    /// long time (``RequestTracing``).
    ///
    /// - Parameter params: The resume request.
    /// - Returns: The response: the `availableCommands` list and the
    ///   `configOptions` list (ACP schema-v2.0.0-alpha.7), and a `_meta`
    ///   `missingTools` report when the restore could not re-apply every
    ///   recorded tool name.
    /// - Throws: The order rule's invalid-request error;
    ///   `RequestError.unknownSession` for an id no recording holds —
    ///   a deleted session included; the cwd-mismatch and
    ///   unknown-cursor refusals; the owner refusal of an `external`
    ///   connection (``RequestError/sessionHasOwner(id:)``); or whatever the
    ///   composition or the restore throws.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await resumeSession(params, from: .direct)
    }

    /// Resumes one recorded root session for one connection: the work of
    /// ``resumeSession(_:)``. The updates of the resumed session go out on
    /// `caller`.
    ///
    /// - Parameters:
    ///   - params: The resume request.
    ///   - caller: The connection of the request.
    /// - Returns: The response that ``resumeSession(_:)`` names.
    /// - Throws: The errors that ``resumeSession(_:)`` names.
    func resumeSession(
        _ params: ResumeSessionRequest, from caller: ConnectionId
    ) async throws -> ResumeSessionResponse {
        try await RequestTracing.withEnteredRequestSpan(
            ACPAgentTelemetry.SpanName.sessionResume, method: ACPMethod.sessionResume,
            sessionId: params.sessionId, meta: params.meta, logger: ACPAgentTelemetry.logger(.sessionResume)
        ) { _ in
            try await restoreSession(params, from: caller)
        }
    }

    /// Restores one recorded root session: the work of
    /// ``resumeSession(_:from:)`` in its span.
    ///
    /// - Parameters:
    ///   - params: The resume request.
    ///   - caller: The connection of the request.
    /// - Returns: The response that ``resumeSession(_:)`` names.
    /// - Throws: The errors that ``resumeSession(_:)`` names.
    private func restoreSession(
        _ params: ResumeSessionRequest, from caller: ConnectionId
    ) async throws -> ResumeSessionResponse {
        try requireInitialized(before: ACPMethod.sessionResume, from: caller)
        let userPresence = userPresence(of: caller)
        let workingDirectory = try SessionSetup.validatedWorkingDirectory(
            path: params.cwd.rawValue, field: .cwd)
        guard let rootId = ULID(ulidString: params.sessionId.rawValue) else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        let replayCursor = try Self.replayCursor(of: params)

        let context = try await loadSessionContext(workingDirectory: workingDirectory)
        try requireRecordedWorkingDirectory(
            of: rootId,
            sessionId: params.sessionId,
            toMatch: workingDirectory,
            transcriptRoot: context.transcriptRoot)

        // A non-empty list is the complete new root set; omitted or empty
        // means no additional roots. Former roots are never inherited.
        let additionalRoots = try SessionSetup.additionalRoots(
            fromPaths: (params.additionalDirectories ?? []).map(\.rawValue))

        // The resume takes the session for the connection of the request
        // (D120 c) before anything else changes: an `external` connection
        // cannot take a session that another connection owns. From here on,
        // each update and each request for the user goes to the new owner,
        // and the old owner gets none.
        try takeSession(params.sessionId, for: caller)

        // A live entry gets the full teardown of `session/close` first: its
        // open prompts end with `idle(cancelled)`, its Router session closes
        // and its projector stops. Thus no update of the old session comes
        // after the restore starts, and the session never has two
        // projectors (elicitation-plan task 3; task ^he1rmw6, decision A).
        if let live = sessions[params.sessionId], !live.isClosed {
            await tearDownSession(params.sessionId, entry: live)
        }

        // The replaced entry's surface is released before the new one is
        // composed, never after: its code context indexes the same working
        // directory the new composition is about to open a fresh code
        // context over, and two open index databases on the same path
        // race for the same SQLite write lock. The
        // retained history of the entry goes over to the resumed session.
        let keptHistory = sessions[params.sessionId]?.history
        await releaseReplacedSession(params.sessionId)

        let composition = try await composeResumedSession(
            from: context, workingDirectory: workingDirectory, additionalRoots: additionalRoots,
            params: params, userPresence: userPresence)
        let restored = try await restoreRecordedSession(
            rootId, sessionId: params.sessionId, composition: composition, userPresence: userPresence)
        let history = resumedHistory(
            kept: keptHistory, directory: restored.session.recordingDirectory, rootId: rootId,
            sessionId: params.sessionId)

        // The mount gives Router the new root set, unless the session is
        // replay-only: a replay-only session runs no prompt, so its
        // `index.md` stays as the session left it. A session that recorded
        // a title keeps it; the first prompt of one with none sets it.
        let activation = try await activateSession(
            restored.session,
            composition: composition,
            placement: SessionPlacement(
                workingDirectory: workingDirectory, additionalRoots: additionalRoots, userPresence: userPresence),
            titleRecorded: restored.session.facts.title != nil,
            history: history)

        try await replayHistory(history, from: replayCursor, sessionId: params.sessionId)

        let response = ResumeSessionResponse(
            availableCommands: activation.availableCommands,
            configOptions: activation.configOptions,
            meta: Self.missingToolsMeta(of: restored.configurationReport))
        // `SessionMergeEngine.seed(from:)` is the FoundationModelsACP method
        // that records the commands and the options of the response, so the
        // state part of a later replay holds them.
        sessions[params.sessionId]?.retainedHistory.seed(from: response)
        return response
    }

    // MARK: - The pre-checks

    /// Takes a session for the connection of a resume (D120 c): the
    /// connection becomes the owner (``ConnectionTable/take(_:by:)``). A
    /// `userDevice` connection takes each session; an `external` connection
    /// takes only a session with no owner, or one that it owns.
    ///
    /// - Parameters:
    ///   - sessionId: The session to take.
    ///   - caller: The connection of the resume.
    /// - Throws: ``RequestError/sessionHasOwner(id:)`` when the rule refuses
    ///   the take.
    private func takeSession(_ sessionId: SessionId, for caller: ConnectionId) throws {
        guard connections.take(sessionId, by: caller) else {
            ACPAgentTelemetry.logger(.sessionResume).warning(
                "An external connection tried to take a session that has an owner. The agent refuses the resume.",
                metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
            throw RequestError.sessionHasOwner(id: sessionId)
        }
    }

    /// The parsed replay cursor of the request, or `nil` for no replay.
    /// Parsed before any other work, so an unknown cursor refuses before
    /// anything is built.
    ///
    /// - Parameter params: The resume request.
    /// - Returns: The cursor, or `nil`.
    /// - Throws: ``RequestError/unknownReplayCursor(_:)`` for a cursor
    ///   type this agent cannot honor.
    private static func replayCursor(of params: ResumeSessionRequest) throws -> ReplayCursor? {
        switch params.replayFrom {
        case nil:
            return nil
        case .start:
            return .start
        case .unknown(let type, _):
            throw RequestError.unknownReplayCursor(type)
        }
    }

    /// The cwd equality pre-check: reads the recorded
    /// working directory through the synchronous
    /// `recordedWorkingDirectory` — no backend, no session, no write —
    /// and refuses a mismatch before anything is restored.
    ///
    /// - Parameters:
    ///   - rootId: The recorded root session's id.
    ///   - sessionId: The wire session id, for the refusals.
    ///   - workingDirectory: The request's validated cwd.
    ///   - transcriptRoot: The resolved recording root to read.
    /// - Throws: `RequestError.unknownSession` when the root holds no
    ///   session with this id, the cwd-mismatch refusal, or whatever the
    ///   tree load throws.
    private func requireRecordedWorkingDirectory(
        of rootId: ULID,
        sessionId: SessionId,
        toMatch workingDirectory: URL,
        transcriptRoot: URL
    ) throws {
        let recorded: URL
        do {
            recorded = try residentProfile.standard.recordedWorkingDirectory(
                ofSession: rootId, recordingRoot: transcriptRoot)
        } catch TranscriptTreeError.sessionNotFound {
            throw RequestError.unknownSession(id: sessionId)
        }
        let recordedPath = recorded.standardizedFileURL.path
        let requestedPath = workingDirectory.standardizedFileURL.path
        guard recordedPath == requestedPath else {
            // The record holds no path. The refusal gives both paths to the client.
            ACPAgentTelemetry.logger(.sessionResume).warning(
                "The resume cwd does not equal the recorded cwd. The agent refuses the resume.",
                metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
            throw RequestError.mismatchedWorkingDirectory(
                id: sessionId, requested: requestedPath, recorded: recordedPath)
        }
    }

    // MARK: - The restore

    /// Composes the resumed session, or makes the replay-only composition
    /// when the working directory or an additional root does not exist.
    ///
    /// The agent never makes a session directory, and each tool mount can
    /// make one: the code context index, for example, makes
    /// `<cwd>/.code-context` and each missing parent. A resume of a session
    /// whose directory is gone thus mounts nothing. The history is in the
    /// recording root and not in the cwd, so the replay still works.
    ///
    /// - Parameters:
    ///   - context: The resolved per-cwd configuration.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The requested additional roots, in wire order.
    ///   - params: The resume request.
    ///   - userPresence: The user presence of the session.
    /// - Returns: The full composition, or the replay-only composition.
    /// - Throws: Whatever ``composeSession(from:workingDirectory:additionalRoots:clientMCPServers:userPresence:)``
    ///   throws.
    private func composeResumedSession(
        from context: LoadedSessionContext,
        workingDirectory: URL,
        additionalRoots: [URL],
        params: ResumeSessionRequest,
        userPresence: UserPresence
    ) async throws -> SessionComposition {
        guard
            SessionSetup.allDirectoriesExist(
                workingDirectory: workingDirectory, additionalRoots: additionalRoots)
        else {
            ACPAgentTelemetry.logger(.sessionResume).notice(
                "A directory of the resumed session does not exist. The session is replay-only.",
                metadata: ACPAgentTelemetry.sessionMetadata(params.sessionId))
            return .replayOnly(from: context)
        }
        return try await composeSession(
            from: context,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: params.mcpServers ?? [],
            userPresence: userPresence)
    }

    /// Restores the recorded root session with the freshly assembled
    /// instructions and the composed roster. Router
    /// matches the roster by recorded name; every recorded name with no
    /// supplied instance lands in the returned report.
    ///
    /// A replay-only composition assembled no instructions, so the restore
    /// keeps the recorded instructions and writes no divergence event.
    ///
    /// A restore that throws releases what the composed surface holds —
    /// the surface never mounts, so nothing else would.
    ///
    /// - Parameters:
    ///   - rootId: The recorded root session's id.
    ///   - sessionId: The wire session id, for the refusals and the log.
    ///   - composition: The freshly composed session inputs.
    ///   - userPresence: The user presence of the session.
    /// - Returns: The restored session and its reports.
    /// - Throws: `RequestError.unknownSession` when the recording is
    ///   gone, or whatever the restore throws.
    private func restoreRecordedSession(
        _ rootId: ULID, sessionId: SessionId, composition: SessionComposition, userPresence: UserPresence
    ) async throws -> RestoredSession {
        do {
            let restored = try await residentProfile.standard.restoreSessionWithHostChecks(
                id: rootId,
                recordingRoot: composition.transcriptRoot,
                instructions: composition.isReplayOnly ? nil : composition.instructions,
                tools: composition.surface.tools,
                userPresence: userPresence)
            logRestoreReports(of: restored, sessionId: sessionId)
            return restored
        } catch {
            composition.surface.shellOutput?.finish()
            await composition.surface.shutdown()
            if case TranscriptTreeError.sessionNotFound = error {
                throw RequestError.unknownSession(id: sessionId)
            }
            throw error
        }
    }

    /// Logs what the restore could not re-apply: each missing tool name,
    /// and each context mismatch — a warning, not an error, because the
    /// same model can resolve a different context on a different machine.
    ///
    /// - Parameters:
    ///   - restored: The restore's result.
    ///   - sessionId: The session the rows belong to.
    private func logRestoreReports(of restored: RestoredSession, sessionId: SessionId) {
        for missing in restored.configurationReport.missingTools {
            var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.toolName] = "\(missing.toolName)"
            ACPAgentTelemetry.logger(.sessionResume).notice(
                "A recorded tool has no supplied instance.", metadata: metadata)
        }
        for mismatch in restored.contextMismatches {
            let metadata: Logger.Metadata = [
                ACPAgentTelemetry.LogMetadataKey.sessionId: "\(mismatch.session.description)",
                ACPAgentTelemetry.LogMetadataKey.recordedContextTokens: "\(mismatch.recorded)",
                ACPAgentTelemetry.LogMetadataKey.resolvedContextTokens: "\(mismatch.resolved)",
            ]
            ACPAgentTelemetry.logger(.sessionResume).notice(
                "A restored session resolved a context that is different from the recorded context.",
                metadata: metadata)
        }
    }

    /// Releases the table entry `sessionId` currently holds, if any: the
    /// resumed session replaces it, so its shell stream is finished and
    /// its server pool is shut down before the new entry mounts.
    ///
    /// - Parameter sessionId: The session being replaced.
    private func releaseReplacedSession(_ sessionId: SessionId) async {
        guard let existing = sessions.removeValue(forKey: sessionId) else {
            return
        }
        recordActiveSessions()
        existing.surface.shellOutput?.finish()
        await existing.surface.shutdown()
    }

    // MARK: - Replay

    /// Replays the retained history of the session (ACP
    /// schema-v2.0.0-alpha.7), before the resume response returns: each
    /// message that the client saw live, as one whole-message upsert with
    /// the id it had live, and never the `*_chunk` forms, so a client that
    /// saw the live chunk stream converges: a whole-message update with
    /// `content` replaces everything accumulated, chunks included. The
    /// Router journal is never a source of a replayed message: a compaction
    /// changes only the model context, and the history keeps every message.
    /// The plans that the journal recorded are in the history already
    /// (``resumedHistory(kept:directory:rootId:sessionId:)``), so the replay
    /// sends the last plan of each plan id.
    ///
    /// - Parameters:
    ///   - history: The retained history of the session.
    ///   - cursor: Where the replay begins, or `nil` for no replay.
    ///   - sessionId: The session the updates belong to.
    /// - Throws: An internal error when the session has no connection with
    ///   an outbound path.
    private func replayHistory(
        _ history: SessionMergeEngine, from cursor: ReplayCursor?, sessionId: SessionId
    ) async throws {
        guard let cursor else {
            return
        }
        guard let connection = connections.path(forSession: sessionId)?.connection else {
            throw RequestError.internalError(
                detail: "the agent has no connection to notify through")
        }
        for update in history.replayUpdates(from: cursor) {
            await connection.post(update, in: sessionId)
        }
    }

    // MARK: - The missing-tool report

    /// The `_meta` object that reports every recorded tool name the
    /// restore could not match, or `nil` when the report is complete.
    /// Resume is where the roster legitimately differs from the
    /// recording, and the report is never swallowed: the names ride the
    /// response under ``missingToolsMetaKey``.
    ///
    /// - Parameter report: The restore's configuration report.
    /// - Returns: The `_meta` value, or `nil`.
    private static func missingToolsMeta(
        of report: SessionConfigurationRestorationReport
    ) -> FoundationModelsACP.JSONValue? {
        guard !report.missingTools.isEmpty else {
            return nil
        }
        return .object([
            missingToolsMetaKey: .array(
                report.missingTools.map { .string($0.toolName) })
        ])
    }
}

extension SessionComposition {
    /// The composition of a replay-only resume: the resolved configuration
    /// and recording root, no instructions, an empty surface, and no
    /// command source. Nothing in it reads or makes the session directory.
    ///
    /// - Parameter context: The resolved per-cwd configuration.
    /// - Returns: The replay-only composition.
    static func replayOnly(from context: LoadedSessionContext) -> SessionComposition {
        SessionComposition(
            configuration: context.loaded.configuration,
            instructions: "",
            surface: .makeEmpty(),
            commandProviders: [],
            userLayerRoot: context.userLayerRoot,
            transcriptRoot: context.transcriptRoot,
            isReplayOnly: true)
    }
}
