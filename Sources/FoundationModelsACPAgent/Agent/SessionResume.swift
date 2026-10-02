import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The replay cursor of one resume (plan.md §7.4): an inclusive position
/// in the retained history. `start` is the first variant; a resume from a
/// message id adds a case here and a starting rule in
/// `SessionMergeEngine.replayUpdates(from:)` — the replay path never
/// hardcodes replay-everything.
enum ReplayCursor: Equatable, Sendable {
    /// Replay the whole retained history.
    case start
}

extension RequestError {
    /// The cwd-mismatch refusal (plan.md §7.4): the request `cwd` MUST
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

    /// The unknown replay-cursor refusal (plan.md §7.4): a cursor type
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
    /// response's `_meta` (plan.md §7.4).
    static let missingToolsMetaKey = "missingTools"

    /// Resumes one recorded root session (plan.md §7.4, §10.1).
    ///
    /// The order is deliberate: the cwd equality pre-check runs through
    /// the synchronous `recordedWorkingDirectory` BEFORE any composition
    /// or restore, so a mismatch or an unknown id never builds a session
    /// only to throw it away. Then this package's side is reassembled
    /// from the recorded cwd — the config layer, the instructions, the
    /// tools, the confinement — and Router restores the session itself
    /// with the freshly assembled instructions and roster. The client's
    /// `additionalDirectories` and `mcpServers` are authoritative on each
    /// reconnect. Replay of the retained history, when asked for, goes out
    /// before the response returns (``retainedHistory(kept:directory:sessionId:)``).
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
    ///   a deleted session included (§10.1); the cwd-mismatch and
    ///   unknown-cursor refusals; `RequestError.busySession` while a prompt
    ///   runs; or whatever the composition or the restore throws.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await RequestTracing.withEnteredRequestSpan(
            ACPAgentTelemetry.SpanName.sessionResume, method: ACPMethod.sessionResume,
            sessionId: params.sessionId, meta: params.meta, logger: ACPAgentTelemetry.logger(.sessionResume)
        ) { _ in
            try await restoreSession(params)
        }
    }

    /// Restores one recorded root session: the work of
    /// ``resumeSession(_:)``.
    ///
    /// - Parameter params: The resume request.
    /// - Returns: The response that ``resumeSession(_:)`` names.
    /// - Throws: The errors that ``resumeSession(_:)`` names.
    private func restoreSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try requireInitialized(before: ACPMethod.sessionResume)
        let workingDirectory = try SessionSetup.validatedWorkingDirectory(
            path: params.cwd.rawValue, field: .cwd)
        guard let rootId = ULID(ulidString: params.sessionId.rawValue) else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        if sessions[params.sessionId]?.availability == .busy {
            throw RequestError.busySession(id: params.sessionId)
        }
        let replayCursor = try Self.replayCursor(of: params)

        let context = try loadSessionContext(workingDirectory: workingDirectory)
        try requireRecordedWorkingDirectory(
            of: rootId,
            sessionId: params.sessionId,
            toMatch: workingDirectory,
            transcriptRoot: context.transcriptRoot)

        // A non-empty list is the complete new root set; omitted or empty
        // means no additional roots. Former roots are never inherited.
        let additionalRoots = try SessionSetup.additionalRoots(
            fromPaths: (params.additionalDirectories ?? []).map(\.rawValue))

        // The replaced entry's surface is released before the new one is
        // composed, never after: its code context indexes the same working
        // directory the new composition is about to open a fresh code
        // context over, and two open index databases on the same path
        // race for the same SQLite write lock (plan.md §7.4, §11.6). The
        // retained history of the entry goes over to the resumed session.
        let keptHistory = sessions[params.sessionId]?.history
        await releaseReplacedSession(params.sessionId)

        let composition = try await composeSession(
            from: context,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: params.mcpServers ?? [])
        let restored = try await restoreRecordedSession(
            rootId, sessionId: params.sessionId, composition: composition)
        let history = retainedHistory(
            kept: keptHistory, directory: restored.session.recordingDirectory, sessionId: params.sessionId)

        let activation = try await activateSession(
            restored.session,
            composition: composition,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            indexRecorded: recordResumedRootSet(
                sessionId: params.sessionId,
                transcriptRoot: composition.transcriptRoot,
                workingDirectory: workingDirectory,
                additionalRoots: additionalRoots),
            history: history)

        try await replayHistory(history, from: replayCursor, sessionId: params.sessionId)

        let response = ResumeSessionResponse(
            availableCommands: activation.availableCommands,
            configOptions: activation.configOptions,
            meta: Self.missingToolsMeta(of: restored.configurationReport))
        sessions[params.sessionId]?.history.seed(from: response)
        return response
    }

    // MARK: - The pre-checks

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

    /// The cwd equality pre-check (plan.md §7.4): reads the recorded
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

    /// Restores the recorded root session with the freshly assembled
    /// instructions and the composed roster (plan.md §7.4). Router
    /// matches the roster by recorded name; every recorded name with no
    /// supplied instance lands in the returned report.
    ///
    /// A restore that throws releases what the composed surface holds —
    /// the surface never mounts, so nothing else would.
    ///
    /// - Parameters:
    ///   - rootId: The recorded root session's id.
    ///   - sessionId: The wire session id, for the refusals and the log.
    ///   - composition: The freshly composed session inputs.
    /// - Returns: The restored session and its reports.
    /// - Throws: `RequestError.unknownSession` when the recording is
    ///   gone, or whatever the restore throws.
    private func restoreRecordedSession(
        _ rootId: ULID, sessionId: SessionId, composition: SessionComposition
    ) async throws -> RestoredSession {
        do {
            let restored = try await residentProfile.standard.restoreSession(
                id: rootId,
                recordingRoot: composition.transcriptRoot,
                instructions: composition.instructions,
                tools: composition.surface.tools,
                toolOutputProtection: SkillOutputProtection.rule)
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

    // MARK: - The persisted root set (plan.md §7.4, §9)

    /// Persists the resumed root set to the `sessions.jsonl` index: the
    /// session's newest record is appended again with the complete new
    /// ordered `additionalDirectories` list, so the listing reflects the
    /// latest activation.
    ///
    /// A session with no record yet — recorded activity without an index
    /// line — appends nothing here; the first prompt writes the record
    /// with its title, per §9's deferral. A failed index read or write is
    /// logged and treated the same way, so a damaged index never blocks a
    /// resume.
    ///
    /// - Parameters:
    ///   - sessionId: The resumed session.
    ///   - transcriptRoot: The recording root whose index to update.
    ///   - workingDirectory: The session working directory.
    ///   - additionalRoots: The complete new root set, in wire order.
    /// - Returns: Whether the index records the session, for the table
    ///   entry's `indexRecorded`.
    private func recordResumedRootSet(
        sessionId: SessionId,
        transcriptRoot: URL,
        workingDirectory: URL,
        additionalRoots: [URL]
    ) -> Bool {
        let index = SessionIndex(root: transcriptRoot)
        do {
            let existing = try index.read().records
                .last { $0.sessionId == sessionId.rawValue }
            guard let existing else {
                return false
            }
            try index.append(
                SessionIndexRecord(
                    sessionId: sessionId.rawValue,
                    cwd: workingDirectory.path,
                    title: existing.title,
                    updatedAt: Date(),
                    additionalDirectories: additionalRoots.map(\.path)))
            return true
        } catch {
            ACPAgentTelemetry.logger(.sessionResume).error(
                "The root-set update of sessions.jsonl failed.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
            return false
        }
    }

    // MARK: - Replay (plan.md §7.4, §8.3)

    /// Replays the retained history of the session (ACP
    /// schema-v2.0.0-alpha.7), before the resume response returns: each
    /// message that the client saw live, as one whole-message upsert with
    /// the id it had live, and never the `*_chunk` forms, so a client that
    /// saw the live chunk stream converges through §8.3's replace row. The
    /// Router journal is never a source of the replay: a compaction changes
    /// only the model context, and the history keeps every message.
    ///
    /// - Parameters:
    ///   - history: The retained history of the session.
    ///   - cursor: Where the replay begins, or `nil` for no replay.
    ///   - sessionId: The session the updates belong to.
    /// - Throws: An internal error when no connection is bound.
    private func replayHistory(
        _ history: SessionMergeEngine, from cursor: ReplayCursor?, sessionId: SessionId
    ) async throws {
        guard let cursor else {
            return
        }
        guard let connection = boundConnection else {
            throw RequestError.internalError(
                detail: "the agent has no bound connection to notify through")
        }
        for update in history.replayUpdates(from: cursor) {
            await connection.post(update, in: sessionId)
        }
    }

    // MARK: - The missing-tool report (plan.md §7.4)

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
