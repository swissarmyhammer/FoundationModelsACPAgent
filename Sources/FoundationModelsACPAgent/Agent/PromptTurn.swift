import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsRouter

/// Why one prompt turn stopped, in this agent's own vocabulary
/// (plan.md §8.2). Router's error enums are internal, so the turn
/// catches `any Error` and classifies it into this intent first;
/// ``PromptTurn/stopReason(for:)`` then maps each intent to the wire
/// value, totally.
enum TurnStop: Equatable, Sendable {
    /// The turn completed.
    case completed

    /// A guardrail refused the turn.
    case refusal

    /// The turn was cancelled.
    case cancelled

    /// The token budget ended the turn.
    case budgetExhausted

    /// The tool-loop cap ended the turn. No producer exists yet: neither
    /// Router nor the SDK caps tool loops today. The arm keeps the
    /// §8.2 mapping total for the task that adds the cap.
    case toolLoopCapped

    /// The turn failed for a reason outside the mapped intents.
    case failed(message: String)
}

/// What the first recorded activity writes (plan.md §9): the
/// `sessions.jsonl` index and the record to append, deferred from
/// `session/new` by the zero-turn rule.
struct FirstActivity: Sendable {
    /// The index of the session's recording root.
    let index: SessionIndex

    /// The record to append, with the generated one-line title.
    let record: SessionIndexRecord
}

/// One prompt turn (plan.md §8.1–§8.3).
///
/// The turn runs after the `{}` response went out, on the request's own
/// dispatch task through `afterRespondingToCurrentRequest`. It sends the
/// `user_message` echo, writes the first-activity index record, drives
/// the session's event stream, and ends with one `idle` state update.
struct PromptTurn: Sendable {
    /// The wire value an unmapped turn failure stops with, under the
    /// `_`-prefix extension rule (plan.md §18).
    static let unmappedStopReasonValue = "_error"

    /// The id of the session this turn runs in.
    let sessionId: SessionId

    /// The prompt's content blocks, echoed as the `user_message`.
    let promptBlocks: [ContentBlock]

    /// The turn-state owner of the session.
    let turnState: TurnStateOwner

    /// The sink every update of this turn goes to.
    let send: SessionUpdateSink

    /// The first-activity index write, or `nil` when the record exists.
    let firstActivity: FirstActivity?

    /// The mutable projection state of one turn drive.
    private struct TurnProjection {
        /// The one agent message id of the turn, made at the first text
        /// delta (§8.3: a new id starts a new message).
        var agentMessageId: MessageId?

        /// The one agent thought id of the turn.
        var thoughtMessageId: MessageId?

        /// The prompt tokens summed across every `turnEnded` (§8.1).
        var tokensIn = 0

        /// The completion tokens summed across every `turnEnded`.
        var tokensOut = 0

        /// The newest context fill. `nan` means "no stamp": send no
        /// meter for the turn (§8.4).
        var contextFill = Double.nan

        /// Why the turn stopped.
        var stop = TurnStop.completed
    }

    /// Runs the turn: the echo, the first-activity record, and the
    /// session's event stream to completion (plan.md §8.1).
    ///
    /// - Parameter session: The Router session that generates the turn.
    func run(session: any RoutedSession) async {
        await send(
            .userMessage(
                UserMessage(messageId: Self.makeMessageId(), content: .value(promptBlocks))))
        await recordFirstActivity()
        await drive(
            events: session.streamEvents(
                to: Self.promptText(from: promptBlocks), maxTokens: nil))
    }

    /// Drives one event stream to completion and closes the turn: each
    /// event is projected, the summed usage is reported one time, and
    /// exactly one `idle` goes out — keyed on stream completion, never
    /// on a `turnEnded` count (plan.md §8.1). A `CancellationError` is
    /// classified here; it never escapes (§8.2).
    ///
    /// - Parameter events: The turn's event stream.
    /// - Returns: The stop reason the idle update carried.
    @discardableResult
    func drive<Events: AsyncSequence>(
        events: Events
    ) async -> StopReason where Events.Element == SessionEvent {
        var projection = TurnProjection()
        do {
            for try await event in events {
                await handle(event, projection: &projection)
            }
        } catch {
            projection.stop = Self.classify(error)
        }
        // A cancelled turn does not always throw (§8.6): model work that
        // never checks for cancellation runs to completion. The recorded
        // request still ends the turn as cancelled.
        if await turnState.cancelRequested {
            projection.stop = .cancelled
        }
        await sendUsage(projection)
        let reason = Self.stopReason(for: projection.stop)
        await turnState.turnDidEnd(reason: reason)
        return reason
    }

    // MARK: - The event projection (plan.md §8.4, this task's slice)

    /// Projects one event. This task maps the text stream, the state
    /// transitions, and the usage; the §8.4 projection task maps the
    /// tool events, which pass the default arm here.
    ///
    /// - Parameters:
    ///   - event: The event to project.
    ///   - projection: The turn's mutable projection state.
    private func handle(_ event: SessionEvent, projection: inout TurnProjection) async {
        switch event {
        case .turnStarted:
            await turnState.turnDidStart()
        case .textDelta(let text):
            let messageId = projection.agentMessageId ?? Self.makeMessageId()
            projection.agentMessageId = messageId
            await send(
                .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .textReset:
            // "Discard the text collected so far" cannot ride as a chunk:
            // send the whole-message form, which replaces everything
            // accumulated (§8.3). With no message yet there is nothing
            // to discard.
            guard let messageId = projection.agentMessageId else { return }
            await send(.agentMessage(AgentMessage(messageId: messageId, content: .value([]))))
        case .reasoningDelta(let text):
            let messageId = projection.thoughtMessageId ?? Self.makeMessageId()
            projection.thoughtMessageId = messageId
            await send(
                .agentThoughtChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .turnEnded(let usage):
            // One event per inner generate call, not per turn: sum, and
            // never send `idle` from here (§8.1).
            projection.tokensIn += usage.tokensIn
            projection.tokensOut += usage.tokensOut
            projection.contextFill = usage.contextFill
        default:
            // `SessionEvent` requires a default arm by its own contract.
            // The tool, compaction, and diagnostic events map in the
            // §8.4 projection task.
            turnLogger.debug(
                "session \(sessionId.rawValue, privacy: .public): unprojected event \(String(describing: event), privacy: .public)"
            )
        }
    }

    /// Sends the one `usage_update` of the turn, from the summed usage.
    /// A `nan` context fill means "no stamp": no meter goes on the wire
    /// (plan.md §8.4).
    ///
    /// - Parameter projection: The turn's final projection state.
    private func sendUsage(_ projection: TurnProjection) async {
        let used = projection.tokensIn + projection.tokensOut
        guard used > 0, projection.contextFill.isFinite, projection.contextFill > 0 else {
            return
        }
        // `contextFill` is used divided by size, so the size is derived.
        let size = Int((Double(used) / projection.contextFill).rounded())
        await send(.usageUpdate(UsageUpdate(size: max(size, used), used: used)))
    }

    // MARK: - The first activity (plan.md §9)

    /// Appends the `sessions.jsonl` record and announces the title with
    /// `session_info_update`. A write failure is logged; it does not end
    /// the turn.
    private func recordFirstActivity() async {
        guard let firstActivity else { return }
        do {
            try firstActivity.index.append(firstActivity.record)
        } catch {
            turnLogger.error(
                "session \(sessionId.rawValue, privacy: .public): sessions.jsonl append failed: \(error, privacy: .public)"
            )
        }
        await send(
            .sessionInfoUpdate(
                SessionInfoUpdate(
                    title: .value(firstActivity.record.title),
                    updatedAt: .value(Self.rfc3339(firstActivity.record.updatedAt)))))
    }

    // MARK: - The stop-reason mapping (plan.md §8.2)

    /// Maps a turn-stop intent to the wire stop reason. Total: every
    /// intent has a wire value, and an unmapped failure degrades to the
    /// ``unmappedStopReasonValue`` extension value, never to an error.
    ///
    /// - Parameter stop: Why the turn stopped.
    /// - Returns: The wire stop reason.
    static func stopReason(for stop: TurnStop) -> StopReason {
        switch stop {
        case .completed: .endTurn
        case .refusal: .refusal
        case .cancelled: .cancelled
        case .budgetExhausted: .maxTokens
        case .toolLoopCapped: .maxTurnRequests
        case .failed: .unknown(unmappedStopReasonValue)
        }
    }

    /// Classifies a turn error by intent. Router's error enums are
    /// internal, so the readable types are Swift's `CancellationError`
    /// and the SDK's public `LanguageModelError` — the same vocabulary
    /// Router's own overflow recovery matches; everything else degrades
    /// to `failed`.
    ///
    /// - Parameter error: The error the turn's stream finished with.
    /// - Returns: The intent.
    static func classify(_ error: any Error) -> TurnStop {
        if error is CancellationError {
            return .cancelled
        }
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .guardrailViolation, .refusal:
                return .refusal
            case .contextSizeExceeded:
                return .budgetExhausted
            default:
                return .failed(message: String(describing: modelError))
            }
        }
        return .failed(message: String(describing: error))
    }

    // MARK: - Helpers

    /// Makes one agent-owned message id (plan.md §8.3): a fresh ULID, in
    /// the id vocabulary the session ids already use.
    static func makeMessageId() -> MessageId {
        MessageId(rawValue: ULID.generate().description)
    }

    /// The model prompt of the request: the text blocks joined by
    /// newlines. The remaining block kinds are the content task's slice
    /// (plan.md §12); the echo still carries every block verbatim.
    ///
    /// - Parameter blocks: The request's content blocks.
    /// - Returns: The prompt text.
    static func promptText(from blocks: [ContentBlock]) -> String {
        blocks.compactMap { block in
            if case .text(let content) = block {
                return content.text
            }
            return nil
        }.joined(separator: "\n")
    }

    /// The generated session title (plan.md §4.6): the first user prompt
    /// cut to a single line.
    ///
    /// - Parameter text: The first prompt's text.
    /// - Returns: The first non-empty line, trimmed; empty when the
    ///   prompt has no text.
    static func oneLineTitle(from text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    /// Formats a date as RFC 3339, the wire form of `updatedAt`
    /// (plan.md §9).
    ///
    /// - Parameter date: The date to format.
    /// - Returns: The RFC 3339 string.
    static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

extension RequestError {
    /// The reason a closed session's refusal reports (plan.md §10.1): a
    /// closed session is resumable, not promptable.
    private static let closedSessionReason = "closed; resume it first"

    /// The reason a busy session's refusal reports (plan.md §7.1).
    private static let busySessionReason = "a prompt turn is in flight; one prompt for each session at a time"

    /// The unknown-id refusal (plan.md §10.1): JSON-RPC invalid params
    /// with the id in `data`, so a client bug is visible, never a silent
    /// `idle` for nothing.
    ///
    /// - Parameter id: The unknown session id.
    /// - Returns: The typed invalid-params error.
    static func unknownSession(id: SessionId) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object(["sessionId": .string(id.rawValue)]))
    }

    /// The closed-session refusal (plan.md §10.1): invalid params with
    /// the resume hint in `data`.
    ///
    /// - Parameter id: The closed session's id.
    /// - Returns: The typed invalid-params error.
    static func closedSession(id: SessionId) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object([
                "sessionId": .string(id.rawValue),
                "reason": .string(closedSessionReason),
            ]))
    }

    /// The busy-session refusal (plan.md §7.1): a prompt during a
    /// running turn is a client error, not a queue entry.
    ///
    /// - Parameter id: The busy session's id.
    /// - Returns: The typed invalid-request error.
    static func busySession(id: SessionId) -> RequestError {
        RequestError(
            code: .invalidRequest,
            message: RequestError.invalidRequest.message,
            data: .object([
                "sessionId": .string(id.rawValue),
                "reason": .string(busySessionReason),
            ]))
    }
}

extension RoutedACPAgent {
    /// Accepts one prompt turn (plan.md §8.1): validates the session,
    /// marks it busy, defers the turn to run after the `{}` response
    /// through `afterRespondingToCurrentRequest`, and returns `{}` at
    /// once. Never a detached task that races the response.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The empty acceptance.
    /// - Throws: The order rule's error, `unknownSession` (§10.1),
    ///   `closedSession` (§10.1), or `busySession` (§7.1).
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try requireInitialized(before: ACPMethod.sessionPrompt)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        switch entry.availability {
        case .closed:
            throw RequestError.closedSession(id: params.sessionId)
        case .busy:
            throw RequestError.busySession(id: params.sessionId)
        case .idle:
            break
        }
        guard let connection = boundConnection else {
            throw RequestError.internalError(
                detail: "the agent has no bound connection to notify through")
        }

        let sessionId = params.sessionId
        let send: SessionUpdateSink = { update in
            await connection.post(update, in: sessionId)
        }
        let owner = TurnStateOwner(send: send)
        sessions[sessionId]?.activeTurn = owner
        let turn = PromptTurn(
            sessionId: sessionId,
            promptBlocks: params.prompt,
            turnState: owner,
            send: send,
            firstActivity: makeFirstActivity(for: sessionId, entry: entry, blocks: params.prompt))
        let session = entry.session
        connection.afterRespondingToCurrentRequest {
            await turn.run(session: session)
            await self.turnFinished(sessionId: sessionId)
        }
        return PromptResponse()
    }

    /// Stops the session's running turn (plan.md §8.6): records the
    /// request on the turn owner, then cancels Router's turn in flight.
    /// A notification has no response, so an unknown id or an idle
    /// session is logged and ignored (plan.md §10.1).
    ///
    /// - Parameter params: The cancellation notification.
    public func sessionCancel(_ params: CancelSessionNotification) async {
        guard let entry = sessions[params.sessionId], let turn = entry.activeTurn else {
            turnLogger.notice(
                "session/cancel for session \(params.sessionId.rawValue, privacy: .public) with no running turn; ignored"
            )
            return
        }
        await turn.noteCancelRequested()
        let result = await entry.session.cancelCurrentTurn()
        turnLogger.info(
            "session \(params.sessionId.rawValue, privacy: .public): cancelCurrentTurn -> \(String(describing: result), privacy: .public)"
        )
    }

    /// Marks the session closed. The session-close task (plan.md §10.1)
    /// flips this after its sweep; the prompt refusal reads it.
    ///
    /// - Parameter sessionId: The session to mark.
    func markSessionClosed(_ sessionId: SessionId) {
        sessions[sessionId]?.isClosed = true
    }

    /// Clears the finished turn, so the session accepts a new prompt.
    /// Runs after the turn's `idle` went out, so a second turn's
    /// `running` can never pass the first turn's terminator.
    ///
    /// - Parameter sessionId: The session whose turn finished.
    func turnFinished(sessionId: SessionId) {
        sessions[sessionId]?.activeTurn = nil
    }

    /// The first-activity index write, or `nil` when the session already
    /// has its record (plan.md §9). Marks the record written at
    /// acceptance, so one session appends at most one record.
    ///
    /// - Parameters:
    ///   - sessionId: The session being prompted.
    ///   - entry: The session's table entry.
    ///   - blocks: The prompt's content blocks, for the title.
    /// - Returns: The write, or `nil`.
    private func makeFirstActivity(
        for sessionId: SessionId, entry: ActiveSession, blocks: [ContentBlock]
    ) -> FirstActivity? {
        guard !entry.indexRecorded else { return nil }
        sessions[sessionId]?.indexRecorded = true
        let record = SessionIndexRecord(
            sessionId: sessionId.rawValue,
            cwd: entry.workingDirectory.path,
            title: PromptTurn.oneLineTitle(from: PromptTurn.promptText(from: blocks)),
            updatedAt: Date(),
            additionalDirectories: entry.additionalRoots.map(\.path))
        return FirstActivity(
            index: SessionIndex(root: entry.transcriptDirectory.deletingLastPathComponent()),
            record: record)
    }
}
