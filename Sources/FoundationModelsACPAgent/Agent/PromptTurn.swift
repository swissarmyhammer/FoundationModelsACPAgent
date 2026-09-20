import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsMultitool
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

    /// The turn completed, but it generated nothing: no text, no
    /// reasoning, no tool call, and a usage report of zero output
    /// tokens. A bare `end_turn` would hide that, so the arm maps to
    /// the `_no_output` extension value (§8.2's `_` rule; task
    /// ^pez780d).
    case noOutput

    /// The turn completed, but the generate call that ended it stopped at
    /// the output token ceiling of the model: Router's `FinishReason` of
    /// that call is `maxTokens`. The answer, the reasoning or the tool
    /// call is cut. A bare `end_turn` would hide that, and `max_tokens`
    /// is the overflow of the INPUT context, which is a different
    /// budget. So the arm maps to the `_truncated` extension value
    /// (§8.2's `_` rule; task ^bw9qt1z).
    case truncated

    /// The turn stopped waiting on a generation that made nothing: the
    /// model call produced no fragment at all for the whole
    /// ``PromptTurn/stalledGenerationBound``, so the turn ended it
    /// rather than hang. The arm carries Router's own report, which
    /// names the times, and maps to the `_stalled` extension value
    /// (§8.2's `_` rule; task ^s0bw5cv).
    case stalled(GenerationStall)

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

    /// The wire value a completed turn that generated nothing stops
    /// with, under the same `_`-prefix extension rule (task ^pez780d).
    static let noOutputStopReasonValue = "_no_output"

    /// The wire value a turn whose last generation reached the output
    /// token ceiling stops with, under the same `_`-prefix extension rule
    /// (task ^bw9qt1z).
    static let truncatedStopReasonValue = "_truncated"

    /// The wire value a turn that ended a stalled generation stops with,
    /// under the same `_`-prefix extension rule (task ^s0bw5cv).
    static let stalledStopReasonValue = "_stalled"

    /// The seconds ``stalledGenerationBound`` is built from.
    private static let stalledGenerationBoundSeconds = 1800

    /// How long a generation may run with no fragment at all before the
    /// turn stops waiting on it (task ^s0bw5cv).
    ///
    /// Router bounds no decode. A model the loader cannot drive reports
    /// a stall on each interval and never ends, so without this bound
    /// the turn holds the session for as long as the process lives.
    /// Measured on 2026-09-08, one such generation stayed in flight
    /// 3120 seconds and made zero fragments, and the person who asked
    /// for the answer read nothing at all.
    ///
    /// The bound is thirty minutes, and it was two minutes until task
    /// ^ec8hn3z measured what two minutes costs. Two facts set it.
    ///
    /// A real build task reaches its first observable output long after
    /// two minutes. Measured on 2026-09-08 with
    /// `mlx-community/Qwen3.8-27B-mxfp4`, the tier-4 `greet` prompt made
    /// its FIRST tool call 555 seconds after the prompt, and then wrote
    /// the three files, ran pytest green and printed the expected line.
    /// Under the two-minute bound the same prompt ended with `_stalled`
    /// every time.
    ///
    /// A zero fragment count is no evidence that the model made nothing.
    /// Through that whole successful turn Router kept reporting `0
    /// fragments`, at 1780 seconds in flight, while `runCode` and shell
    /// calls were completing. So ``endsTurn(_:sawOutput:)`` holds one
    /// honest signal, `sawOutput`, and the bound must stand clear of the
    /// window before the first output rather than measure the decode.
    ///
    /// Thirty minutes stands well past the measured 555 seconds and well
    /// under the 3120 seconds of the model that made nothing, so the
    /// guard still ends a generation this loader cannot drive.
    static let stalledGenerationBound: Duration = .seconds(stalledGenerationBoundSeconds)

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

    /// The model reference the turn's session generates with.
    ///
    /// The stalled-generation report names it (task ^s0bw5cv), so a
    /// person who reads the log learns which model made nothing. It is
    /// the same string `/status` shows for the selected slot.
    let modelName: String

    /// The expanded command text that replaces the blocks' text as the
    /// model prompt, or `nil` for a plain prompt (plan.md §14.3). The
    /// echo always carries the original blocks verbatim.
    var modelPrompt: String?

    /// The reader of a settled run's stored output, handed to the
    /// projection for the §11.6 convergence replace. The default finds
    /// no run; the catalog wiring supplies the host-owned stream's
    /// `snapshot(for:)`.
    var shellSnapshot: ShellSnapshotProvider = { _ in nil }

    /// The resolver of the prompt's resource links (plan.md §12). The
    /// default holds no read verb and refuses every link with a reason;
    /// the scheduling wiring supplies the session surface's verb.
    var contentResolver = ResourceLinkResolver(readVerb: nil)

    /// The handler of a live elicitation request (plan.md §16), or `nil`
    /// when no relay is wired — a synthetic projection drive. The
    /// scheduling wiring supplies the session's ``ElicitationRelay``
    /// bound to the turn's session and owner.
    var relayElicitation: ElicitationEventHandler?

    /// Runs the turn: the echo, the first-activity record, and the
    /// session's event stream to completion (plan.md §8.1). A plain
    /// prompt folds through `PromptContent` (§12); an expanded command
    /// keeps its override text (§14.3). The echo always carries the
    /// original blocks verbatim.
    ///
    /// - Parameter session: The Router session that generates the turn.
    func run(session: any RoutedSession) async {
        await send(
            .userMessage(
                UserMessage(
                    messageId: EventProjection.makeMessageId(), content: .value(promptBlocks))))
        await recordFirstActivity()
        let prompt: String
        if let modelPrompt {
            prompt = modelPrompt
        } else {
            prompt = await PromptContent.modelPrompt(
                from: promptBlocks, resolver: contentResolver)
        }
        await drive(events: session.streamEvents(to: prompt, maxTokens: nil))
    }

    /// Drives one event stream to completion and closes the turn: each
    /// event is projected, the summed usage is reported one time, and
    /// exactly one `idle` goes out — keyed on stream completion, never
    /// on a `turnEnded` count (plan.md §8.1). A `CancellationError` is
    /// classified here; it never escapes (§8.2).
    ///
    /// The loop also carries the stalled-generation guard of task
    /// ^s0bw5cv. Leaving `events` cancels Router's turn, which is that
    /// surface's own contract, so the guard needs no second call.
    ///
    /// - Parameter events: The turn's event stream.
    /// - Returns: The stop reason the idle update carried.
    @discardableResult
    func drive<Events: AsyncSequence>(
        events: Events
    ) async -> StopReason where Events.Element == SessionEvent {
        var projection = EventProjection(
            sessionId: sessionId,
            turnState: turnState,
            send: send,
            shellSnapshot: shellSnapshot,
            relayElicitation: relayElicitation)
        var stop = TurnStop.completed
        do {
            for try await event in events {
                await projection.project(event)
                guard case .generationStalled(let stall) = event,
                    Self.endsTurn(stall, sawOutput: projection.sawOutput)
                else {
                    continue
                }
                stop = .stalled(stall)
                report(stall)
                break
            }
        } catch {
            stop = Self.classify(error)
        }
        // A cancelled turn does not always throw (§8.6): model work that
        // never checks for cancellation runs to completion. The recorded
        // request still ends the turn as cancelled.
        if await turnState.cancelRequested {
            stop = .cancelled
        }
        // A completed live turn that streamed no output and whose usage
        // report says zero generated tokens must not read as a normal
        // `end_turn` (task ^pez780d): the intermittent live-model defect
        // ends exactly this shape of turn, and a bare `end_turn` would
        // hide it. The honest `_no_output` extension value reports it.
        if stop == .completed, projection.generatedNothing {
            stop = .noOutput
        }
        // A completed turn whose LAST generate call stopped at the output
        // token ceiling is cut, not finished (task ^bw9qt1z). A turn of
        // 8192 reasoning tokens and no answer ended as `end_turn` before
        // Router gave the finish reason.
        if stop == .completed, projection.endedAtTokenCeiling {
            stop = .truncated
        }
        await projection.reportUsage()
        let reason = Self.stopReason(for: stop)
        await turnState.turnDidEnd(reason: reason)
        return reason
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
        case .noOutput: .unknown(noOutputStopReasonValue)
        case .truncated: .unknown(truncatedStopReasonValue)
        case .stalled: .unknown(stalledStopReasonValue)
        case .failed: .unknown(unmappedStopReasonValue)
        }
    }

    // MARK: - The stalled-generation guard (task ^s0bw5cv)

    /// Whether the turn stops waiting on the generation `stall` reports.
    ///
    /// Two facts must hold together. The report names a model call that
    /// has made no fragment at all for the whole
    /// ``stalledGenerationBound``, and the turn has made no observable
    /// output either. A stall on a call that already streamed is a slow
    /// decode, and a stall on a fresh call raised while a tool runs is
    /// a slow tool; neither is a model this loader cannot drive, and
    /// Router's report-only behaviour stands for both.
    ///
    /// A `wholeAnswer` visibility never ends the turn. Such a call
    /// streams nothing by design, so a long one reads exactly like a
    /// hung one, and the drive loop reads a fragment stream in any
    /// case.
    ///
    /// - Parameters:
    ///   - stall: The report Router made.
    ///   - sawOutput: Whether the turn has made observable output.
    /// - Returns: Whether the turn ends on this report.
    static func endsTurn(_ stall: GenerationStall, sawOutput: Bool) -> Bool {
        guard case .fragments(let observed) = stall.visibility, observed == 0 else {
            return false
        }
        guard !sawOutput else { return false }
        return stall.timeWithoutProgress >= stalledGenerationBound
    }

    /// Records the stall the turn stopped on, naming the model and the
    /// reason.
    ///
    /// The wire carries the ``stalledStopReasonValue`` stop reason and
    /// nothing else: plan.md §8.4 gives a stall report no wire message,
    /// and the terminator of the turn is what a client reads.
    ///
    /// - Parameter stall: The report the turn stopped on.
    private func report(_ stall: GenerationStall) {
        // Copies for the log line: the logger's message is an escaping
        // autoclosure, which must not capture the turn itself.
        let sessionIdValue = sessionId.rawValue
        let model = modelName
        let reported = stall.description
        let reason = Self.stalledStopReasonValue
        turnLogger.error(
            "session \(sessionIdValue, privacy: .public): model \(model, privacy: .public) \(reported, privacy: .public); the turn ends with \(reason, privacy: .public)"
        )
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

    /// The plain text of the request: the text blocks joined by
    /// newlines. The session title derives from it (plan.md §4.6); the
    /// model prompt goes through `PromptContent.modelPrompt` instead,
    /// which also folds resource links and embedded resources (§12).
    ///
    /// - Parameter blocks: The request's content blocks.
    /// - Returns: The text.
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
    ///   `closedSession` (§10.1), `busySession` (§7.1), or a command
    ///   refusal (§14.3).
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

        // A leading /name goes through the registry before anything
        // touches the session (plan.md §14.3). It never reaches the
        // model as a prompt.
        if let command = CommandDispatch.parseCommand(blocks: params.prompt) {
            return try await dispatchCommand(
                command, params: params, entry: entry, connection: connection)
        }

        let (owner, send) = beginTurn(params: params, connection: connection)
        return scheduleModelTurn(
            overridePrompt: nil,
            params: params, entry: entry, connection: connection, owner: owner, send: send)
    }

    /// Marks the session busy for one turn: builds the update sink over
    /// `connection` and installs a fresh turn-state owner as the
    /// session's active turn.
    ///
    /// - Parameters:
    ///   - params: The prompt request.
    ///   - connection: The bound connection the sink posts through.
    /// - Returns: The installed owner and the sink.
    func beginTurn(
        params: PromptRequest, connection: AgentSideConnection
    ) -> (owner: TurnStateOwner, send: SessionUpdateSink) {
        let sessionId = params.sessionId
        let send: SessionUpdateSink = { update in
            await connection.post(update, in: sessionId)
        }
        let owner = TurnStateOwner(send: send)
        sessions[sessionId]?.activeTurn = owner
        return (owner, send)
    }

    /// Defers one model turn to run after the `{}` response through
    /// `afterRespondingToCurrentRequest`, and returns `{}` at once.
    /// Never a detached task that races the response (plan.md §8.1).
    ///
    /// - Parameters:
    ///   - overridePrompt: The expanded command text that replaces the
    ///     blocks' text as the model prompt, or `nil` for a plain
    ///     prompt (§14.3).
    ///   - params: The prompt request.
    ///   - entry: The session's table entry.
    ///   - connection: The bound connection the turn registers with.
    ///   - owner: The turn-state owner ``beginTurn(params:connection:)``
    ///     installed.
    ///   - send: The sink every update of the turn goes to.
    /// - Returns: The empty acceptance.
    func scheduleModelTurn(
        overridePrompt: String?,
        params: PromptRequest,
        entry: ActiveSession,
        connection: AgentSideConnection,
        owner: TurnStateOwner,
        send: @escaping SessionUpdateSink
    ) -> PromptResponse {
        let sessionId = params.sessionId
        // The reader of a settled run's stored output (plan.md §11.8):
        // the same host-owned stream the terminal projection consumes.
        let shellOutput = entry.surface.shellOutput
        let session = entry.session
        // The elicitation relay of this turn (plan.md §16): it holds the
        // capabilities `initialize` read, and `session/cancel` and
        // `session/close` reach it through the session's table entry. A
        // missing negotiation reads as "supports nothing", the same rule
        // `initialize` applies to an unparsable capabilities object.
        let relay = ElicitationRelay(
            sessionId: sessionId,
            capabilities: negotiatedClientCapabilities
                ?? NegotiatedClientCapabilities(reading: ClientCapabilities()),
            connection: connection)
        sessions[sessionId]?.activeElicitationRelay = relay
        let turn = PromptTurn(
            sessionId: sessionId,
            promptBlocks: params.prompt,
            turnState: owner,
            send: send,
            firstActivity: makeFirstActivity(for: sessionId, entry: entry, blocks: params.prompt),
            modelName: ConfigOptions.handle(for: entry.selectedSlot, of: residentProfile)
                .chosen.stringValue,
            modelPrompt: overridePrompt,
            shellSnapshot: { commandID in shellOutput?.snapshot(for: commandID) },
            contentResolver: ResourceLinkResolver(readVerb: entry.surface.filesReadVerb),
            relayElicitation: { event in
                await relay.relay(event, on: session, turnState: owner)
            })
        connection.afterRespondingToCurrentRequest {
            await turn.run(session: session)
            await self.turnFinished(sessionId: sessionId)
        }
        return PromptResponse()
    }

    /// Stops the session's running turn (plan.md §8.6): records the
    /// request on the turn owner, answers every pending elicitation with
    /// `cancel` — the suspended tool must resume before the `idle`
    /// terminator, and Router's mailbox does not resume on task
    /// cancellation — then cancels Router's turn in flight. A
    /// notification has no response, so an unknown id or an idle
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
        await entry.activeElicitationRelay?.cancelPendingElicitations()
        let result = await entry.session.cancelCurrentTurn()
        turnLogger.info(
            "session \(params.sessionId.rawValue, privacy: .public): cancelCurrentTurn -> \(String(describing: result), privacy: .public)"
        )
    }

    /// Marks the session closed. The session-close task (plan.md §10.1)
    /// flips this after its sweep; the prompt refusal reads it.
    ///
    /// It also finishes the session's host-owned shell output stream
    /// (plan.md §11.8): a host that stops listening must call
    /// `finish()`, and the finish ends the terminal projection's
    /// consumer loop.
    ///
    /// - Parameter sessionId: The session to mark.
    func markSessionClosed(_ sessionId: SessionId) {
        sessions[sessionId]?.isClosed = true
        sessions[sessionId]?.surface.shellOutput?.finish()
    }

    /// Clears the finished turn, so the session accepts a new prompt.
    /// Runs after the turn's `idle` went out, so a second turn's
    /// `running` can never pass the first turn's terminator. It then
    /// reconciles the config-option state (plan.md §15): a turn that ran
    /// on a model the announced options do not show pushes one
    /// `config_option_update`, after the turn's terminator.
    ///
    /// - Parameter sessionId: The session whose turn finished.
    func turnFinished(sessionId: SessionId) async {
        sessions[sessionId]?.activeTurn = nil
        // The relay goes with the turn: a pending round trip holds the
        // drive loop, so a finished turn has none left.
        sessions[sessionId]?.activeElicitationRelay = nil
        await reconcileConfigOptions(for: sessionId)
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
