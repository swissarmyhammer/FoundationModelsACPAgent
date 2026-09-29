import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter
import Logging

/// Why one prompt stopped, in this agent's own vocabulary
/// (plan.md §8.2). Router's error enums are internal, so the prompt
/// catches `any Error` and classifies it into this intent first;
/// ``PromptExecution/stopReason(for:)`` then maps each intent to the wire
/// value, totally.
enum PromptStop: Equatable, Sendable {
    /// The prompt completed.
    case completed

    /// A guardrail refused the prompt.
    case refusal

    /// The prompt was cancelled.
    case cancelled

    /// The token budget ended the prompt.
    case budgetExhausted

    /// The tool-loop cap ended the prompt. No producer exists yet: neither
    /// Router nor the SDK caps tool loops today. The arm keeps the
    /// §8.2 mapping total for the task that adds the cap.
    case toolLoopCapped

    /// The prompt completed, but it generated nothing: no text, no
    /// reasoning, no tool call, and a usage report of zero output
    /// tokens. A bare `end_turn` would hide that, so the arm maps to
    /// the `_no_output` extension value (§8.2's `_` rule; task
    /// ^pez780d).
    case noOutput

    /// The prompt completed, but its last submission stopped at the
    /// output token ceiling of the model: Router's `FinishReason` of
    /// that submission is `maxTokens`. The answer, the reasoning or the tool
    /// call is cut. A bare `end_turn` would hide that, and `max_tokens`
    /// is the overflow of the INPUT context, which is a different
    /// budget. So the arm maps to the `_truncated` extension value
    /// (§8.2's `_` rule; task ^bw9qt1z).
    case truncated

    /// The prompt completed, but the output of its last submission ended
    /// inside the reasoning, below the output token ceiling: Router's
    /// `FinishReason` of that submission is `endedInsideReasoning`. The
    /// model or the engine stopped the output, not the ceiling, and the
    /// answer can be empty. A bare `end_turn` would show a cut prompt as a
    /// finished one, and `_truncated` would name the wrong cause. So the arm
    /// maps to the `_ended_in_reasoning` extension value (§8.2's `_` rule;
    /// task ^k51h6bb).
    case endedInReasoning

    /// The prompt completed, but Router stopped its last submission because
    /// the submission repeated itself and no recovery was left: Router's
    /// `FinishReason` of that submission is `repeatedLines`. The arm maps to
    /// the `_repeated` extension value (§8.2's `_` rule; task ^k51h6bb).
    case repeated

    /// The prompt stopped waiting on a generation that made nothing: the
    /// model call produced no fragment at all for the whole
    /// ``PromptExecution/stalledGenerationBound``, so the prompt ended it
    /// rather than hang. The arm carries Router's own report, which
    /// names the times, and maps to the `_stalled` extension value
    /// (§8.2's `_` rule; task ^s0bw5cv).
    case stalled(GenerationStall)

    /// The prompt failed for a reason outside the mapped intents.
    case failed(message: String)
}

/// What the first recorded activity writes (plan.md §9): the
/// `sessions.jsonl` index and the record to append, deferred from
/// `session/new` by the zero-prompt rule.
struct FirstActivity: Sendable {
    /// The index of the session's recording root.
    let index: SessionIndex

    /// The record to append, with the generated one-line title.
    let record: SessionIndexRecord
}

/// The execution of one prompt: one ACP `session/prompt`, from the `{}`
/// response to its one `idle` terminator (plan.md §8.1–§8.3).
///
/// The prompt runs after the `{}` response went out, on the request's own
/// dispatch task through `afterRespondingToCurrentRequest`. It sends the
/// `user_message` echo, writes the first-activity index record, drives
/// the session's event stream, and ends with one `idle` state update.
struct PromptExecution: Sendable {
    /// The wire value an unmapped prompt failure stops with, under the
    /// `_`-prefix extension rule (plan.md §18).
    static let unmappedStopReasonValue = "_error"

    /// The wire value a completed prompt that generated nothing stops
    /// with, under the same `_`-prefix extension rule (task ^pez780d).
    static let noOutputStopReasonValue = "_no_output"

    /// The wire value a prompt whose last generation reached the output
    /// token ceiling stops with, under the same `_`-prefix extension rule
    /// (task ^bw9qt1z).
    static let truncatedStopReasonValue = "_truncated"

    /// The wire value a prompt whose last generation ended inside the
    /// reasoning, below the ceiling, stops with, under the same `_`-prefix
    /// extension rule (task ^k51h6bb).
    static let endedInReasoningStopReasonValue = "_ended_in_reasoning"

    /// The wire value a prompt whose last generation Router stopped for
    /// repetition stops with, under the same `_`-prefix extension rule
    /// (task ^k51h6bb).
    static let repeatedStopReasonValue = "_repeated"

    /// The wire value a prompt that ended a stalled generation stops with,
    /// under the same `_`-prefix extension rule (task ^s0bw5cv).
    static let stalledStopReasonValue = "_stalled"

    /// The seconds ``stalledGenerationBound`` is built from.
    private static let stalledGenerationBoundSeconds = 1800

    /// How long a generation may run with no fragment at all before the
    /// prompt stops waiting on it (task ^s0bw5cv).
    ///
    /// Router bounds no decode. A model the loader cannot drive reports
    /// a stall on each interval and never ends, so without this bound
    /// the prompt holds the session for as long as the process lives.
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
    /// ``GenerationStall/visibility`` counts the fragments of the whole
    /// model call, and a tool call is not a fragment. So
    /// ``endsPrompt(_:sawOutput:)`` holds one honest signal, `sawOutput`,
    /// and the bound must stand clear of the window before the first
    /// output rather than measure the decode. The 2026-09-08 run showed
    /// this: the Router watch of that date also counted the tool bodies,
    /// and it reported `0 fragments` at 1780 seconds in flight while
    /// `runCode` and shell calls were completing.
    ///
    /// The bound compares with ``GenerationStall/timeWithoutProgress``
    /// only. The Router counts that time only while a generation call of
    /// the submission holds its place in the model queue (Router task
    /// ^ake8sax). A wait for a place in the queue and a tool body between
    /// two generation calls do not count, thus a submission that waits
    /// behind other sessions never reaches the bound.
    /// ``GenerationStall/timeInFlight`` includes the wait and the tool
    /// bodies, so no stop decision reads it.
    ///
    /// Thirty minutes stands well past the measured 555 seconds and well
    /// under the 3120 seconds of the model that made nothing, so the
    /// guard still ends a generation this loader cannot drive.
    static let stalledGenerationBound: Duration = .seconds(stalledGenerationBoundSeconds)

    /// The id of the session this prompt runs in.
    let sessionId: SessionId

    /// The prompt's content blocks, echoed as the `user_message`.
    let promptBlocks: [ContentBlock]

    /// The prompt-state owner of the session.
    let promptState: PromptStateOwner

    /// The sink every update of this prompt goes to.
    let send: SessionUpdateSink

    /// The first-activity index write, or `nil` when the record exists.
    let firstActivity: FirstActivity?

    /// The model reference the prompt's session generates with.
    ///
    /// The stalled-generation report names it (task ^s0bw5cv), so a
    /// person who reads the log learns which model made nothing. The log
    /// line of a wait for a place in the model queue names it too. It is
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
    /// bound to the prompt's session and owner.
    var relayElicitation: ElicitationEventHandler?

    /// Runs the prompt: the echo, the first-activity record, and the
    /// session's event stream to completion (plan.md §8.1). A plain
    /// prompt folds through `PromptContent` (§12); an expanded command
    /// keeps its override text (§14.3). The echo always carries the
    /// original blocks verbatim.
    ///
    /// - Parameter session: The Router session that generates the answer.
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

    /// Drives one event stream to completion and closes the prompt: each
    /// event is projected, the summed usage is reported one time, and
    /// exactly one `idle` goes out — keyed on stream completion, never
    /// on a `submissionEnded` count (plan.md §8.1). A `CancellationError` is
    /// classified here; it never escapes (§8.2).
    ///
    /// The loop also carries the stalled-generation guard of task
    /// ^s0bw5cv. Leaving `events` cancels the Router stream, which is that
    /// surface's own contract, so the guard needs no second call.
    ///
    /// - Parameter events: The prompt's event stream.
    /// - Returns: The stop reason the idle update carried.
    @discardableResult
    func drive<Events: AsyncSequence>(
        events: Events
    ) async -> StopReason where Events.Element == SessionEvent {
        var projection = EventProjection(
            sessionId: sessionId,
            promptState: promptState,
            send: send,
            modelName: modelName,
            shellSnapshot: shellSnapshot,
            relayElicitation: relayElicitation)
        var stop = PromptStop.completed
        do {
            for try await event in events {
                await projection.project(event)
                guard case .generationStalled(let stall) = event,
                    Self.endsPrompt(stall, sawOutput: projection.sawOutput)
                else {
                    continue
                }
                stop = .stalled(stall)
                report(stall)
                break
            }
        } catch {
            stop = Self.classify(error)
            if case .failed = stop {
                report(failure: error)
            }
        }
        // A cancelled prompt does not always throw (§8.6): model work that
        // never checks for cancellation runs to completion. The recorded
        // request still ends the prompt as cancelled.
        if await promptState.cancelRequested {
            stop = .cancelled
        }
        // A completed live prompt that streamed no output and whose usage
        // report says zero generated tokens must not read as a normal
        // `end_turn` (task ^pez780d): the intermittent live-model defect
        // ends exactly this shape of prompt, and a bare `end_turn` would
        // hide it. The honest `_no_output` extension value reports it.
        if stop == .completed, projection.generatedNothing {
            stop = .noOutput
        }
        // A completed prompt whose LAST submission did not end by itself is
        // cut, not finished (tasks ^bw9qt1z and ^k51h6bb). A prompt of 8192
        // reasoning tokens and no answer ended as `end_turn` before Router
        // gave the finish reason.
        if stop == .completed, let cut = Self.cutStop(for: projection.lastFinishReason) {
            stop = cut
            report(cut: cut, usage: projection.usageMetadata)
        }
        await projection.reportUsage()
        let reason = Self.stopReason(for: stop)
        await promptState.promptDidEnd(reason: reason)
        return reason
    }

    // MARK: - The first activity (plan.md §9)

    /// Appends the `sessions.jsonl` record and announces the title with
    /// `session_info_update`. A write failure is logged; it does not end
    /// the prompt.
    private func recordFirstActivity() async {
        guard let firstActivity else { return }
        do {
            try firstActivity.index.append(firstActivity.record)
        } catch {
            ACPAgentTelemetry.logger(.promptExecution).error(
                "The append to sessions.jsonl failed.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
        }
        await send(
            .sessionInfoUpdate(
                SessionInfoUpdate(
                    title: .value(firstActivity.record.title),
                    updatedAt: .value(Self.rfc3339(firstActivity.record.updatedAt)))))
    }

    // MARK: - The stop-reason mapping (plan.md §8.2)

    /// Maps a prompt-stop intent to the wire stop reason. Total: every
    /// intent has a wire value, and an unmapped failure degrades to the
    /// ``unmappedStopReasonValue`` extension value, never to an error.
    ///
    /// - Parameter stop: Why the prompt stopped.
    /// - Returns: The wire stop reason.
    static func stopReason(for stop: PromptStop) -> StopReason {
        switch stop {
        case .completed: .endTurn
        case .refusal: .refusal
        case .cancelled: .cancelled
        case .budgetExhausted: .maxTokens
        case .toolLoopCapped: .maxTurnRequests
        case .noOutput: .unknown(noOutputStopReasonValue)
        case .truncated: .unknown(truncatedStopReasonValue)
        case .endedInReasoning: .unknown(endedInReasoningStopReasonValue)
        case .repeated: .unknown(repeatedStopReasonValue)
        case .stalled: .unknown(stalledStopReasonValue)
        case .failed: .unknown(unmappedStopReasonValue)
        }
    }

    /// The stop of a completed prompt whose last submission ended with
    /// `finishReason`, or `nil` when that submission ended by itself.
    ///
    /// The switch is total and declares no `default`, so a finish reason
    /// that Router adds later stops the build here until somebody decides
    /// its stop reason.
    ///
    /// - Parameter finishReason: The finish reason of the last submission,
    ///   or `nil` when no submission reported one.
    /// - Returns: The cut stop, or `nil` for a prompt that stays `completed`.
    static func cutStop(for finishReason: FinishReason?) -> PromptStop? {
        guard let finishReason else { return nil }
        switch finishReason {
        case .completed: return nil
        case .maxTokens: return .truncated
        case .endedInsideReasoning: return .endedInReasoning
        case .repeatedLines: return .repeated
        }
    }

    // MARK: - The stalled-generation guard (task ^s0bw5cv)

    /// Whether the prompt stops waiting on the generation `stall` reports.
    ///
    /// Two facts must hold together. The report names a model call that
    /// has made no fragment at all, with a
    /// ``GenerationStall/timeWithoutProgress`` of the whole
    /// ``stalledGenerationBound`` or more, and the prompt has made no
    /// observable output either. A stall on a call that already streamed
    /// is a slow decode. A stall after a tool call is not a model that
    /// cannot generate, because the tool call is output. Router's
    /// report-only behaviour stands for both.
    ///
    /// A wait for a place in the model queue never ends the prompt. The
    /// Router does not count the wait in `timeWithoutProgress` (Router
    /// task ^ake8sax), and it tells the wait with `submissionQueued`,
    /// which ``EventProjection`` writes as a log line. This guard does
    /// not read ``GenerationStall/timeInFlight``, because that time
    /// includes the wait.
    ///
    /// A `wholeAnswer` visibility never ends the prompt. Such a call
    /// streams nothing by design, so a long one reads exactly like a
    /// hung one, and the drive loop reads a fragment stream in any
    /// case.
    ///
    /// - Parameters:
    ///   - stall: The report Router made.
    ///   - sawOutput: Whether the prompt has made observable output.
    /// - Returns: Whether the prompt ends on this report.
    static func endsPrompt(_ stall: GenerationStall, sawOutput: Bool) -> Bool {
        guard case .fragments(let observed) = stall.visibility, observed == 0 else {
            return false
        }
        guard !sawOutput else { return false }
        return stall.timeWithoutProgress >= stalledGenerationBound
    }

    /// Records the stall the prompt stopped on, naming the model and the
    /// reason.
    ///
    /// The wire carries the ``stalledStopReasonValue`` stop reason and
    /// nothing else: plan.md §8.4 gives a stall report no wire message,
    /// and the terminator of the prompt is what a client reads.
    ///
    /// - Parameter stall: The report the prompt stopped on.
    private func report(_ stall: GenerationStall) {
        var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
        metadata[ACPAgentTelemetry.LogMetadataKey.routerReport] = "\(stall.description)"
        metadata[ACPAgentTelemetry.LogMetadataKey.stopReason] = "\(Self.stalledStopReasonValue)"
        ACPAgentTelemetry.logger(.promptExecution).error(
            "A generation made no output for the stall bound. The prompt ends.", metadata: metadata)
    }

    /// Records the numbers of a prompt whose last submission did not end by
    /// itself. The wire carries the extension stop reason alone
    /// (``truncatedStopReasonValue``, ``endedInReasoningStopReasonValue`` or
    /// ``repeatedStopReasonValue``), thus this record is the one place that
    /// says how full the context was and how many tokens the prompt spent.
    ///
    /// - Parameters:
    ///   - cut: The stop ``cutStop(for:)`` gave.
    ///   - usage: The metadata ``EventProjection/usageMetadata`` makes.
    private func report(cut: PromptStop, usage: Logger.Metadata) {
        var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
            .merging(usage) { current, _ in current }
        metadata[ACPAgentTelemetry.LogMetadataKey.stopReason] = "\(Self.stopReason(for: cut).wireValue)"
        ACPAgentTelemetry.logger(.promptExecution).error(
            "The last submission of the prompt did not end by itself.", metadata: metadata)
    }

    /// Records the error a prompt failed on. The wire carries the
    /// ``unmappedStopReasonValue`` stop reason alone, thus this record is the
    /// one place that names the cause. The record holds the type of the
    /// error and not its message, because a message can hold content.
    ///
    /// - Parameter error: The error the prompt's stream finished with.
    private func report(failure error: any Error) {
        var metadata = ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.modelRef] = "\(modelName)"
        ACPAgentTelemetry.logger(.promptExecution).error("The prompt failed.", metadata: metadata)
    }

    /// Classifies a prompt error by intent. Router's error enums are
    /// internal, so the readable types are Swift's `CancellationError`
    /// and the SDK's public `LanguageModelError` — the same vocabulary
    /// Router's own overflow recovery matches; everything else degrades
    /// to `failed`.
    ///
    /// - Parameter error: The error the prompt's stream finished with.
    /// - Returns: The intent.
    static func classify(_ error: any Error) -> PromptStop {
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
    private static let busySessionReason = "a prompt is in flight; one prompt for each session at a time"

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
    /// running prompt is a client error, not a queue entry.
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
    /// Accepts one prompt (plan.md §8.1): validates the session,
    /// marks it busy, defers the prompt to run after the `{}` response
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

        let (owner, send) = beginPrompt(params: params, connection: connection)
        return scheduleModelPrompt(
            overridePrompt: nil,
            params: params, entry: entry, connection: connection, owner: owner, send: send)
    }

    /// Marks the session busy for one prompt: builds the update sink over
    /// `connection` and installs a fresh prompt-state owner as the
    /// session's active prompt.
    ///
    /// - Parameters:
    ///   - params: The prompt request.
    ///   - connection: The bound connection the sink posts through.
    /// - Returns: The installed owner and the sink.
    func beginPrompt(
        params: PromptRequest, connection: AgentSideConnection
    ) -> (owner: PromptStateOwner, send: SessionUpdateSink) {
        let sessionId = params.sessionId
        let send: SessionUpdateSink = { update in
            await connection.post(update, in: sessionId)
        }
        let owner = PromptStateOwner(send: send)
        sessions[sessionId]?.activePrompt = owner
        return (owner, send)
    }

    /// Defers one model prompt to run after the `{}` response through
    /// `afterRespondingToCurrentRequest`, and returns `{}` at once.
    /// Never a detached task that races the response (plan.md §8.1).
    ///
    /// - Parameters:
    ///   - overridePrompt: The expanded command text that replaces the
    ///     blocks' text as the model prompt, or `nil` for a plain
    ///     prompt (§14.3).
    ///   - params: The prompt request.
    ///   - entry: The session's table entry.
    ///   - connection: The bound connection the prompt registers with.
    ///   - owner: The prompt-state owner ``beginPrompt(params:connection:)``
    ///     installed.
    ///   - send: The sink every update of the prompt goes to.
    /// - Returns: The empty acceptance.
    func scheduleModelPrompt(
        overridePrompt: String?,
        params: PromptRequest,
        entry: ActiveSession,
        connection: AgentSideConnection,
        owner: PromptStateOwner,
        send: @escaping SessionUpdateSink
    ) -> PromptResponse {
        let sessionId = params.sessionId
        // The reader of a settled run's stored output (plan.md §11.8):
        // the same host-owned stream the terminal projection consumes.
        let shellOutput = entry.surface.shellOutput
        let session = entry.session
        // The elicitation relay of this prompt (plan.md §16): it holds the
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
        let execution = PromptExecution(
            sessionId: sessionId,
            promptBlocks: params.prompt,
            promptState: owner,
            send: send,
            firstActivity: makeFirstActivity(for: sessionId, entry: entry, blocks: params.prompt),
            modelName: ConfigOptions.handle(for: entry.selectedSlot, of: residentProfile)
                .chosen.stringValue,
            modelPrompt: overridePrompt,
            shellSnapshot: { commandID in shellOutput?.snapshot(for: commandID) },
            contentResolver: ResourceLinkResolver(readVerb: entry.surface.filesReadVerb),
            relayElicitation: { event in
                await relay.relay(event, on: session, promptState: owner)
            })
        connection.afterRespondingToCurrentRequest {
            await execution.run(session: session)
            await self.promptFinished(sessionId: sessionId)
        }
        return PromptResponse()
    }

    /// Stops the session's running prompt (plan.md §8.6): records the
    /// request on the prompt owner, answers every pending elicitation with
    /// `cancel` — the suspended tool must resume before the `idle`
    /// terminator, and Router's mailbox does not resume on task
    /// cancellation — then cancels the work of the Router session: the
    /// model work in flight and a caller message that waits. A submission
    /// that waits for a place in the model queue is in flight too, and
    /// the cancel reaches it: the Router removes it from the queue at
    /// once, so the `idle(cancelled)` terminator does not wait for the
    /// submission of another session. A notification has no response, so
    /// an unknown id or an idle session is logged and ignored (plan.md
    /// §10.1).
    ///
    /// - Parameter params: The cancellation notification.
    public func sessionCancel(_ params: CancelSessionNotification) async {
        guard let entry = sessions[params.sessionId], let promptState = entry.activePrompt else {
            ACPAgentTelemetry.logger(.promptExecution).notice(
                "A session/cancel found no running prompt. The agent ignores it.",
                metadata: ACPAgentTelemetry.sessionMetadata(params.sessionId))
            return
        }
        await promptState.noteCancelRequested()
        await entry.activeElicitationRelay?.cancelPendingElicitations()
        let result = await entry.session.cancel()
        var metadata = ACPAgentTelemetry.sessionMetadata(params.sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.cancelResult] = "\(Self.cancelResultName(result))"
        ACPAgentTelemetry.logger(.promptExecution).info("The session cancelled its work.", metadata: metadata)
    }

    /// The name of a cancel result, for the log record of a cancel.
    ///
    /// The switch declares no `default`, so a result that Router adds later
    /// stops the build here until somebody names it.
    ///
    /// - Parameter result: What the cancel of the Router session found.
    /// - Returns: The name of the case.
    static func cancelResultName(_ result: CancellationResult) -> String {
        switch result {
        case .requested: "requested"
        case .nothingToCancel: "nothingToCancel"
        }
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

    /// Clears the finished prompt, so the session accepts a new prompt.
    /// Runs after the prompt's `idle` went out, so a second prompt's
    /// `running` can never pass the first prompt's terminator. It then
    /// reconciles the config-option state (plan.md §15): a prompt that ran
    /// on a model the announced options do not show pushes one
    /// `config_option_update`, after the prompt's terminator.
    ///
    /// - Parameter sessionId: The session whose prompt finished.
    func promptFinished(sessionId: SessionId) async {
        sessions[sessionId]?.activePrompt = nil
        // The relay goes with the prompt: a pending round trip holds the
        // drive loop, so a finished prompt has none left.
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
            title: PromptExecution.oneLineTitle(from: PromptExecution.promptText(from: blocks)),
            updatedAt: Date(),
            additionalDirectories: entry.additionalRoots.map(\.path))
        return FirstActivity(
            index: SessionIndex(root: entry.transcriptDirectory.deletingLastPathComponent()),
            record: record)
    }
}
