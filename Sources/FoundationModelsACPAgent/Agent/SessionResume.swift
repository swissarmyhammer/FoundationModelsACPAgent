import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import os

/// The logger of the resume surface: the cwd pre-check, the restore
/// reports, and the replay.
private let resumeLogger = Logger(
    subsystem: RoutedACPAgent.implementation.name, category: "SessionResume")

/// The replay cursor of one resume (plan.md §7.4): an inclusive position
/// in the recorded history. `start` is the first variant; a resume from a
/// message id adds a case here and a starting rule in
/// ``SessionReplay/updates(of:from:)`` — the replay path never hardcodes
/// replay-everything.
enum ReplayCursor: Equatable, Sendable {
    /// Replay the whole recorded history.
    case start
}

/// The replay mapping (plan.md §7.4, §8.3): recorded transcript events to
/// whole-message upserts keyed by the recorded ids.
///
/// Replay reads the FULL recorded history — the conversation the user
/// had — never the compaction view the live session rebuilds from. A fold
/// checkpoint is not a message, so it is skipped.
enum SessionReplay {
    /// The schema name of the structured segment a fold checkpoint
    /// carries. Router keeps `CompactionSegment` package-internal and
    /// documents this schema name as the checkpoint's on-disk identity
    /// (`CompactionSegment.swift`), so the skip matches it by name.
    static let compactionSegmentSchemaName = "FoundationModelsRouter.CompactionSegment"

    /// The text that stands in for an attachment segment that carries
    /// neither a label nor a URL.
    private static let attachmentFallbackText = "attachment"

    /// The whole-message upserts of one recorded history, at or after
    /// `cursor` — the cursor is inclusive (plan.md §7.4).
    ///
    /// - Parameters:
    ///   - events: The session's recorded events, in merged order.
    ///   - cursor: Where the replay begins.
    /// - Returns: The upserts, in recorded order.
    static func updates(of events: [TranscriptEvent], from cursor: ReplayCursor) -> [SessionUpdate] {
        eventsAtOrAfter(cursor, in: events).compactMap(update(for:))
    }

    /// The recorded events at or after `cursor`, inclusive.
    ///
    /// - Parameters:
    ///   - cursor: Where the replay begins.
    ///   - events: The session's recorded events, in merged order.
    /// - Returns: The events replay walks.
    private static func eventsAtOrAfter(
        _ cursor: ReplayCursor, in events: [TranscriptEvent]
    ) -> [TranscriptEvent] {
        switch cursor {
        case .start:
            return events
        }
    }

    /// The one upsert of one recorded event, or `nil` for an event that
    /// is not a message: the router-only kinds, the tool entries, and a
    /// fold checkpoint (plan.md §7.4).
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: The upsert, or `nil`.
    static func update(for event: TranscriptEvent) -> SessionUpdate? {
        guard !isFoldCheckpoint(event) else {
            return nil
        }
        switch event.kind {
        case .prompt:
            return .userMessage(
                UserMessage(messageId: messageId(of: event), content: .value(contentBlocks(of: event))))
        case .response:
            return .agentMessage(
                AgentMessage(messageId: messageId(of: event), content: .value(contentBlocks(of: event))))
        case .reasoning:
            return .agentThought(
                AgentThought(messageId: messageId(of: event), content: .value(contentBlocks(of: event))))
        case .session, .instructions, .toolCalls, .toolOutput, .embedding, .divergence,
            .toolCall, .unknown:
            return nil
        }
    }

    /// Whether `event` is a fold checkpoint (plan.md §7.4, §8.5): a
    /// recorded entry that carries the ``compactionSegmentSchemaName``
    /// structured segment. Checkpoints are not messages and are not sent.
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: `true` for a checkpoint.
    static func isFoldCheckpoint(_ event: TranscriptEvent) -> Bool {
        (event.entry?.segments ?? []).contains { segment in
            if case .structure(_, let schemaName, _) = segment {
                return schemaName == compactionSegmentSchemaName
            }
            return false
        }
    }

    /// The stable wire id of one recorded message (plan.md §8.3): the
    /// recorded first segment id — the identity the transcript itself
    /// holds — or, for an entry with no segments, the session id and the
    /// recorded sequence number. Both are stable on disk, so a repeated
    /// replay sends the same ids and a client converges through the
    /// replace row instead of duplicating.
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: The message id.
    static func messageId(of event: TranscriptEvent) -> MessageId {
        if let id = firstSegmentId(of: event) {
            return MessageId(rawValue: id)
        }
        return MessageId(rawValue: "\(event.sessionId.description)-\(event.seq)")
    }

    /// The id of the recorded entry's first segment, or `nil`.
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: The segment id, or `nil`.
    private static func firstSegmentId(of event: TranscriptEvent) -> String? {
        guard let segment = event.entry?.segments?.first else {
            return nil
        }
        switch segment {
        case .text(let id, _):
            return id
        case .structure(let id, _, _):
            return id
        case .attachment(let id, _, _):
            return id
        case .custom(let id, _, _, _):
            return id
        case .unknown(let id, _):
            return id
        @unknown default:
            return nil
        }
    }

    /// The content blocks of one recorded message: one block per recorded
    /// segment, or one text block from the event's flattened body when
    /// the recording predates structural payloads.
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: The blocks, in segment order.
    static func contentBlocks(of event: TranscriptEvent) -> [ContentBlock] {
        if let segments = event.entry?.segments {
            return segments.map(contentBlock(for:))
        }
        guard let text = event.text else {
            return []
        }
        return [textBlock(text)]
    }

    /// One content block for one recorded segment. Text carries through;
    /// every other segment kind renders its most useful text form, the
    /// same degradations ``EventProjection`` applies to a tool output.
    ///
    /// - Parameter segment: The segment to render.
    /// - Returns: The content block.
    private static func contentBlock(for segment: SegmentPayload) -> ContentBlock {
        switch segment {
        case .text(_, let content):
            return textBlock(content)
        case .structure(_, _, let contentJSON):
            return textBlock(contentJSON)
        case .attachment(_, let label, let url):
            return textBlock(label ?? url ?? attachmentFallbackText)
        case .custom(_, _, let contentJSON, let description):
            return textBlock(description ?? contentJSON)
        case .unknown(_, let description):
            return textBlock(description)
        @unknown default:
            return textBlock(String(describing: segment))
        }
    }

    /// Wraps `text` as one plain text content block.
    ///
    /// - Parameter text: The text of the block.
    /// - Returns: The block.
    private static func textBlock(_ text: String) -> ContentBlock {
        .text(TextContent(text: text))
    }
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
    /// reconnect. Replay, when asked for, goes out before the response
    /// returns.
    ///
    /// - Parameter params: The resume request.
    /// - Returns: The response: the `configOptions` list, and a `_meta`
    ///   `missingTools` report when the restore could not re-apply every
    ///   recorded tool name.
    /// - Throws: The order rule's invalid-request error;
    ///   `RequestError.unknownSession` for an id no recording holds —
    ///   a deleted session included (§10.1); the cwd-mismatch and
    ///   unknown-cursor refusals; `RequestError.busySession` while a turn
    ///   runs; or whatever the composition or the restore throws.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try requireInitialized(before: ACPMethod.sessionResume)
        let workingDirectory = try SessionSetup.validatedWorkingDirectory(
            path: params.cwd.rawValue)
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
        let additionalRoots = (params.additionalDirectories ?? []).map { path in
            URL(fileURLWithPath: path.rawValue, isDirectory: true)
        }
        let composition = try await composeSession(
            from: context,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: params.mcpServers ?? [])
        let restored = try await restoreRecordedSession(
            rootId, sessionId: params.sessionId, composition: composition)

        await releaseReplacedSession(params.sessionId)
        let activation = try await activateSession(
            restored.session,
            composition: composition,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            indexRecorded: recordResumedRootSet(
                sessionId: params.sessionId,
                transcriptRoot: composition.transcriptRoot,
                workingDirectory: workingDirectory,
                additionalRoots: additionalRoots))

        try await replayHistory(
            from: replayCursor,
            sessionId: params.sessionId,
            rootId: rootId,
            context: context,
            workingDirectory: workingDirectory)

        return ResumeSessionResponse(
            configOptions: activation.configOptions,
            meta: Self.missingToolsMeta(of: restored.configurationReport))
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
            resumeLogger.warning(
                "session \(sessionId.rawValue, privacy: .public): resume cwd \(requestedPath, privacy: .public) does not equal the recorded \(recordedPath, privacy: .public); refused"
            )
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
                tools: composition.surface.tools)
            logRestoreReports(of: restored, sessionId: sessionId)
            return restored
        } catch {
            composition.surface.shellOutput?.finish()
            await composition.surface.serverPool.shutdownAll()
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
            resumeLogger.notice(
                "session \(sessionId.rawValue, privacy: .public): recorded tool \(missing.toolName, privacy: .public) has no supplied instance"
            )
        }
        for mismatch in restored.contextMismatches {
            resumeLogger.notice(
                "session \(mismatch.session.description, privacy: .public): recorded context \(mismatch.recorded, privacy: .public) resolved as \(mismatch.resolved, privacy: .public)"
            )
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
        existing.surface.shellOutput?.finish()
        await existing.surface.serverPool.shutdownAll()
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
            resumeLogger.error(
                "session \(sessionId.rawValue, privacy: .public): sessions.jsonl root-set update failed: \(error, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Replay (plan.md §7.4, §8.3)

    /// Replays the recorded history as whole-message upserts, before the
    /// resume response returns. The upserts carry the recorded ids and
    /// never the `*_chunk` forms, so a client that saw the live chunk
    /// stream converges through §8.3's replace row.
    ///
    /// - Parameters:
    ///   - cursor: Where the replay begins, or `nil` for no replay.
    ///   - sessionId: The session the updates belong to.
    ///   - rootId: The recorded root session's id.
    ///   - context: The resolved per-cwd configuration.
    ///   - workingDirectory: The session working directory.
    /// - Throws: An internal error when no connection is bound, or
    ///   whatever the store read throws.
    private func replayHistory(
        from cursor: ReplayCursor?,
        sessionId: SessionId,
        rootId: ULID,
        context: LoadedSessionContext,
        workingDirectory: URL
    ) async throws {
        guard let cursor else {
            return
        }
        guard let connection = boundConnection else {
            throw RequestError.internalError(
                detail: "the agent has no bound connection to notify through")
        }
        let store = TranscriptStore(
            location: context.loaded.configuration.transcripts.location,
            name: name,
            userDirectory: context.userLayerRoot)
        let events = try store.transcript(for: rootId, inProject: workingDirectory)
        for update in SessionReplay.updates(of: events, from: cursor) {
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
