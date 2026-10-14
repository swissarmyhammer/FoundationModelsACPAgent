import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter
import Logging
import Tracing

/// Why one prompt stopped, in this agent's own vocabulary.
/// Router's error enums are internal, so the prompt
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
    /// stop-reason mapping total for the task that adds the cap.
    case toolLoopCapped

    /// The prompt completed, but it generated nothing: no text, no
    /// reasoning, no tool call, and a usage report of zero output
    /// tokens. A bare `end_turn` would hide that, so the arm maps to
    /// the `_no_output` extension value (the ACP `_` extension rule; task
    /// ^pez780d).
    case noOutput

    /// The prompt completed, but its last submission stopped at the
    /// output token ceiling of the model: Router's `FinishReason` of
    /// that submission is `maxTokens`. The answer, the reasoning or the tool
    /// call is cut. A bare `end_turn` would hide that, and `max_tokens`
    /// is the overflow of the INPUT context, which is a different
    /// budget. So the arm maps to the `_truncated` extension value
    /// (the ACP `_` extension rule; task ^bw9qt1z).
    case truncated

    /// The prompt completed, but the output of its last submission ended
    /// inside the reasoning, below the output token ceiling: Router's
    /// `FinishReason` of that submission is `endedInsideReasoning`. The
    /// model or the engine stopped the output, not the ceiling, and the
    /// answer can be empty. A bare `end_turn` would show a cut prompt as a
    /// finished one, and `_truncated` would name the wrong cause. So the arm
    /// maps to the `_ended_in_reasoning` extension value (the ACP `_` extension rule;
    /// task ^k51h6bb).
    case endedInReasoning

    /// The prompt completed, but Router stopped its last submission because
    /// the submission repeated itself and no recovery was left: Router's
    /// `FinishReason` of that submission is `repeatedLines`. The arm maps to
    /// the `_repeated` extension value (the ACP `_` extension rule; task ^k51h6bb).
    case repeated

    /// The prompt completed, but Router stopped its last submission because
    /// one pass reasoned past the reasoning token limit of the repetition
    /// detection, and no recovery was left: Router's `FinishReason` of that
    /// submission is `reasoningTokenLimit`. The model reasoned and did not
    /// act. The output token ceiling did not stop it, so `_truncated` would
    /// name the wrong cause. The arm maps to the `_reasoning_limit`
    /// extension value (the ACP `_` extension rule; task ^7fsfw7y).
    case reasoningLimit

    /// The prompt stopped waiting on a generation that made nothing: the
    /// model call produced no fragment at all for the whole
    /// ``PromptExecution/stalledGenerationBound``, so the prompt ended it
    /// rather than hang. The arm carries Router's own report, which
    /// names the times, and maps to the `_stalled` extension value
    /// (the ACP `_` extension rule; task ^s0bw5cv).
    case stalled(GenerationStall)

    /// The prompt failed for a reason outside the mapped intents.
    case failed(message: String)
}

/// What the first recorded activity writes: the
/// `sessions.jsonl` index and the record to append, deferred from
/// `session/new` by the zero-prompt rule.
struct FirstActivity: Sendable {
    /// The index of the session's recording root.
    let index: SessionIndex

    /// The record to append, with the generated one-line title.
    let record: SessionIndexRecord
}

/// The input side of one prompt: one ACP `session/prompt`, from the
/// response that names the user message to the mail of the prompt.
///
/// The prompt runs after the response went out, on the request's own
/// dispatch task through `afterRespondingToCurrentRequest`. The
/// `user_message` echo goes out before it, through the same response hooks
/// (``RoutedACPAgent/insertUserMessage(_:through:)``). The prompt writes the
/// first-activity index record, opens itself in the ``SessionProjector`` of
/// the session, and mails its text into the Router session. The projector
/// sends the events and the one `idle` state update of the prompt.
struct PromptExecution: Sendable {
    /// The wire value a completed prompt that generated nothing stops
    /// with, under the `_`-prefix extension rule of ACP: a value that starts
    /// with `_` is implementation-specific, and a bare value is reserved for
    /// ACP (task ^pez780d).
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

    /// The wire value a prompt whose last generation Router stopped at the
    /// reasoning token limit stops with, under the same `_`-prefix extension
    /// rule (task ^7fsfw7y).
    static let reasoningLimitStopReasonValue = "_reasoning_limit"

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

    /// The prompt's content blocks. A plain prompt folds them into the
    /// model prompt; the `user_message` echo carries them verbatim.
    let promptBlocks: [ContentBlock]

    /// The prompt-state owner of the prompt.
    let promptState: PromptStateOwner

    /// The sink of the first-activity update of this prompt.
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
    /// model prompt, or `nil` for a plain prompt. The
    /// echo always carries the original blocks verbatim.
    var modelPrompt: String?

    /// The resolver of the prompt's resource links. The
    /// default holds no read verb and refuses every link with a reason;
    /// the scheduling wiring supplies the session surface's verb.
    var contentResolver = ResourceLinkResolver(readVerb: nil)

    /// Runs the prompt: the first-activity record, `running`, the open of
    /// the prompt in the projector, and the mail of the prompt, in this
    /// order (elicitation-plan task 49). A plain prompt folds through
    /// `PromptContent`; an expanded command keeps its override text. The
    /// `user_message` echo went out before this work, and it always carries
    /// the original blocks verbatim.
    ///
    /// The prompt opens in the ``SessionProjector`` before its mail goes into
    /// the session, so each event of the mail finds the prompt. The
    /// projector ends the prompt at the terminal event of the mail: the stop
    /// reason, the `idle`, and then `onEnd`. The call returns after the
    /// mail, not at the end of the prompt.
    ///
    /// The mail is a stream message, so the answer streams its text. A
    /// `mail(_:)` that throws, for example on a session that closed, ends the
    /// prompt with the error (``SessionProjector/refuseMail(_:error:)``).
    ///
    /// - Parameters:
    ///   - mailId: The id of the mail of the prompt, which is also the
    ///     `messageId` of the user message.
    ///   - session: The Router session that generates the answer.
    ///   - projector: The projector of the ACP session.
    ///   - onEnd: The work to run after the end of the prompt.
    func run(
        mailId: MailID = MailID(), session: any RoutedSession, projector: SessionProjector,
        onEnd: @escaping @Sendable (StopReason) async -> Void
    ) async {
        await recordFirstActivity()
        await promptState.promptDidStart()
        let prompt: String
        if let modelPrompt {
            prompt = modelPrompt
        } else {
            prompt = await PromptContent.modelPrompt(
                from: promptBlocks, resolver: contentResolver)
        }
        let mail = Mail(
            id: mailId, sender: .user,
            body: .userMessage(prompt: prompt, options: UserMessageOptions(mode: .stream)))
        projector.open(
            SessionProjector.Prompt(
                mailId: mail.id, sourceId: session.id,
                awaitAnswer: { id in try await session.awaitAnswer(of: id) },
                owner: promptState, modelName: modelName, onEnd: onEnd))
        // A `session/cancel` or a close before this point already sent
        // `cancelAll()`, which cannot reach a mail that is not queued yet.
        guard await !promptState.cancelRequested else {
            projector.cancelUnsentMail(mail.id)
            return
        }
        do {
            _ = try session.mail(mail)
        } catch {
            projector.refuseMail(mail.id, error: error)
        }
    }

    // MARK: - The first activity

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

    // MARK: - The stop-reason mapping

    /// Maps a prompt-stop intent to the wire stop reason. Total: every
    /// intent has a wire value. A failure maps to the ACP `error` stop
    /// reason, and ``idleState(for:)`` gives it the `error` object.
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
        case .reasoningLimit: .unknown(reasoningLimitStopReasonValue)
        case .stalled: .unknown(stalledStopReasonValue)
        case .failed: .error
        }
    }

    /// The `idle` state update that ends a prompt that stopped with `stop`:
    /// the stop reason, and the `error` object of a failed prompt.
    ///
    /// - Parameter stop: Why the prompt stopped.
    /// - Returns: The idle state update.
    static func idleState(for stop: PromptStop) -> IdleStateUpdate {
        IdleStateUpdate(error: idleError(for: stop), stopReason: stopReason(for: stop))
    }

    /// The `error` object of the `idle` of a prompt that stopped with `stop`,
    /// or `nil` when the prompt did not fail.
    ///
    /// A failure is an internal error of the agent: the user message went in,
    /// and the work after it failed. The message is the failure text.
    ///
    /// - Parameter stop: Why the prompt stopped.
    /// - Returns: The error object, or `nil`.
    private static func idleError(for stop: PromptStop) -> ACPError? {
        guard case .failed(let message) = stop else {
            return nil
        }
        return ACPError(code: .internalError, message: message)
    }

    /// The status that each tool call that did not finish gets at the end of
    /// a prompt that stopped with `stop`, or `nil` when the stop leaves the
    /// tool calls as they are.
    ///
    /// A failed prompt fails each open tool call, and a cancelled prompt
    /// cancels each open tool call, before its `idle` (the ACP v2 prompt
    /// lifecycle). The switch declares no `default`, so a new stop stops the
    /// build here until somebody decides its status.
    ///
    /// - Parameter stop: Why the prompt stopped.
    /// - Returns: The closing status, or `nil`.
    static func closingStatus(for stop: PromptStop) -> FoundationModelsACP.ToolCallStatus? {
        switch stop {
        case .failed: .failed
        case .cancelled: .cancelled
        case .completed, .refusal, .budgetExhausted, .toolLoopCapped, .noOutput, .truncated, .endedInReasoning,
            .repeated, .reasoningLimit, .stalled:
            nil
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
        case .reasoningTokenLimit: return .reasoningLimit
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
    /// which ``ACPEventTranslator`` writes as a log line. This guard does
    /// not read ``GenerationStall/timeInFlight``, because that time
    /// includes the wait.
    ///
    /// A `wholeAnswer` visibility never ends the prompt. Such a call
    /// streams nothing by design, so a long one reads exactly like a
    /// hung one.
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
    /// nothing else: a stall report has no wire message,
    /// and the terminator of the prompt is what a client reads.
    ///
    /// - Parameters:
    ///   - stall: The report the prompt stopped on.
    ///   - sessionId: The ACP session of the prompt.
    ///   - modelName: The model reference of the prompt.
    static func report(_ stall: GenerationStall, sessionId: SessionId, modelName: String) {
        var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
        metadata[ACPAgentTelemetry.LogMetadataKey.routerReport] = "\(stall.description)"
        metadata[ACPAgentTelemetry.LogMetadataKey.stopReason] = "\(Self.stalledStopReasonValue)"
        ACPAgentTelemetry.logger(.promptExecution).error(
            "A generation made no output for the stall bound. The prompt ends.", metadata: metadata)
    }

    /// Records the cause and the numbers of a prompt whose last submission
    /// did not end by itself. The wire carries the extension stop reason
    /// alone (``truncatedStopReasonValue``, ``endedInReasoningStopReasonValue``,
    /// ``repeatedStopReasonValue`` or ``reasoningLimitStopReasonValue``),
    /// thus this record is the one place that says how full the context was,
    /// how many tokens the prompt spent, how many Router stops and
    /// recoveries ran, the reasoning tokens and the limit of the last
    /// reasoning stop, and how many files the prompt changed (task
    /// ^dcmsxpw).
    ///
    /// - Parameters:
    ///   - cut: The stop ``cutStop(for:)`` gave.
    ///   - cutMetadata: The metadata ``PromptTally/cutMetadata`` makes.
    ///   - changedFileCount: The number of files that the files verbs of the
    ///     prompt changed.
    ///   - sessionId: The ACP session of the prompt.
    ///   - modelName: The model reference of the prompt.
    static func report(
        cut: PromptStop, metadata cutMetadata: Logger.Metadata, changedFileCount: Int, sessionId: SessionId,
        modelName: String
    ) {
        var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
            .merging(cutMetadata) { current, _ in current }
        metadata[ACPAgentTelemetry.LogMetadataKey.stopReason] = "\(Self.stopReason(for: cut).wireValue)"
        ACPAgentTelemetry.logger(.promptExecution).error(
            Self.cutMessage(for: cut, changedFileCount: changedFileCount), metadata: metadata)
    }

    /// The message of the record of a cut prompt: the cause of the stop, and
    /// whether the files verbs of the prompt changed a file (task ^dcmsxpw).
    ///
    /// A shell command that writes a file records no change set, so the
    /// message names the files verbs and not the whole prompt.
    ///
    /// - Parameters:
    ///   - cut: The stop ``cutStop(for:)`` gave.
    ///   - changedFileCount: The number of files that the files verbs of the
    ///     prompt changed.
    /// - Returns: The message.
    static func cutMessage(for cut: PromptStop, changedFileCount: Int) -> Logger.Message {
        let cause: String
        switch cut {
        case .truncated:
            cause = "The last submission of the prompt stopped at the output token ceiling."
        case .endedInReasoning:
            cause = "The last submission of the prompt ended inside its reasoning."
        case .repeated:
            cause = "Router stopped the last submission of the prompt, because it repeated itself and no recovery was left."
        case .reasoningLimit:
            cause = "Router stopped the last pass of the prompt at the reasoning token limit, because it reasoned and did not act and no recovery was left."
        case .completed, .refusal, .cancelled, .budgetExhausted, .toolLoopCapped, .noOutput, .stalled, .failed:
            cause = "The last submission of the prompt did not end by itself."
        }
        let files: String
        switch changedFileCount {
        case 0: files = "The files verbs of the prompt changed no file."
        case 1: files = "The files verbs of the prompt changed 1 file."
        default: files = "The files verbs of the prompt changed \(changedFileCount) files."
        }
        return "\(cause) \(files)"
    }

    /// Records the error a prompt failed on. The wire gives the error text to
    /// the client in the `error` object of the `idle`. The record holds the
    /// type of the error and not its message, because a message can hold
    /// content, and the log goes to the telemetry backend.
    ///
    /// - Parameters:
    ///   - error: The error of the failed answer of the prompt.
    ///   - sessionId: The ACP session of the prompt.
    ///   - modelName: The model reference of the prompt.
    static func report(failure error: any Error, sessionId: SessionId, modelName: String) {
        var metadata = ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.modelRef] = "\(modelName)"
        ACPAgentTelemetry.logger(.promptExecution).error("The prompt failed.", metadata: metadata)
    }

    /// Classifies a prompt error by intent. Router's error enums are
    /// internal, so the readable types are the abort errors
    /// (``isAbort(_:)``) and the SDK's public `LanguageModelError` — the same
    /// vocabulary Router's own overflow recovery matches; everything else
    /// degrades to `failed`.
    ///
    /// - Parameter error: The error the prompt's stream finished with.
    /// - Returns: The intent.
    static func classify(_ error: any Error) -> PromptStop {
        if isAbort(error) {
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

    /// Whether `error` tells that the work was aborted, and did not fail.
    ///
    /// Router and Swift concurrency throw `CancellationError`. Foundation
    /// throws `URLError.cancelled` for a cancelled URL load, and
    /// `CocoaError.userCancelled` for an operation that the user stopped. The
    /// ACP prompt lifecycle reports each of them as `cancelled`, never as an
    /// error.
    ///
    /// - Parameter error: The error to read.
    /// - Returns: Whether the error is an abort.
    static func isAbort(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if let cocoaError = error as? CocoaError {
            return cocoaError.code == .userCancelled
        }
        return false
    }

    // MARK: - Helpers

    /// The plain text of the request: the text blocks joined by
    /// newlines. The session title derives from it; the
    /// model prompt goes through `PromptContent.modelPrompt` instead,
    /// which also folds resource links and embedded resources.
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

    /// The generated session title: the first user prompt
    /// cut to a single line. `session/list` needs a title, and it is
    /// not derivable later, so the agent makes and keeps one.
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

    /// Formats a date as RFC 3339, the wire form of `updatedAt`.
    ///
    /// - Parameter date: The date to format.
    /// - Returns: The RFC 3339 string.
    static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

extension RequestError {
    /// The reason a closed session's refusal reports: a
    /// closed session is resumable, not promptable.
    private static let closedSessionReason = "closed; resume it first"

    /// The reason a replay-only session's refusal reports: the agent never
    /// makes a session directory, so the session cannot run a prompt.
    private static let missingWorkingDirectoryReason = "the working directory of this session does not exist"

    /// The unknown-id refusal: JSON-RPC invalid params
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

    /// The closed-session refusal: invalid params with
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

    /// The missing-working-directory refusal: a prompt on a replay-only
    /// session. Invalid params, with the id and the reason in `data`.
    ///
    /// - Parameter id: The replay-only session's id.
    /// - Returns: The typed invalid-params error.
    static func missingSessionWorkingDirectory(id: SessionId) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object([
                "sessionId": .string(id.rawValue),
                "reason": .string(missingWorkingDirectoryReason),
            ]))
    }
}

extension RoutedACPAgent {
    /// Accepts one prompt: validates the session, inserts the user message,
    /// defers the prompt to run after the response through
    /// `afterRespondingToCurrentRequest`, and returns at once a response
    /// that names the user message (ACP schema-v2.0.0-alpha.7). Never a
    /// detached task that races the response.
    ///
    /// A prompt is mail to the Router session (elicitation-plan task 3). A
    /// prompt that arrives while another prompt is in flight is accepted:
    /// its mail waits in the mail queue of the session. The `messageId` of
    /// a model prompt is its `MailID`.
    ///
    /// The prompt runs in one server span, from the request in to the stop
    /// reason out, and it writes one "enter" record when it starts
    /// (``RequestTracing``). The work after the response runs in the
    /// context of the span, so each Router submission span of the prompt is
    /// a child of it. The span ends with the prompt stop reason after that
    /// work, or with the error when the prompt is refused.
    ///
    /// The prompt also adds one to the `prompts` counter and records its
    /// duration (``PromptMeasurement``), with the stop reason, or with
    /// `error` when the prompt is refused.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The response that names the user message.
    /// - Throws: The order rule's error, `unknownSession`,
    ///   `closedSession`, `missingSessionWorkingDirectory` for a replay-only
    ///   session, or a command refusal.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let measurement = PromptMeasurement()
        let span = RequestTracing.startRequestSpan(
            ACPAgentTelemetry.SpanName.prompt, method: ACPMethod.sessionPrompt,
            sessionId: params.sessionId, meta: params.meta, logger: ACPAgentTelemetry.logger(.promptExecution))
        do {
            let (response, owner) = try await ServiceContext.withValue(span.context) {
                try await acceptPrompt(params)
            }
            endTelemetryAfterPrompt(span: span, measurement: measurement, owner: owner)
            return response
        } catch {
            RequestTracing.endRequestSpan(span, throwing: error)
            measurement.record(stopReason: nil)
            throw error
        }
    }

    /// Ends the span and the measurement of an accepted prompt after the
    /// work of the prompt.
    ///
    /// The prompt registered its work with `afterRespondingToCurrentRequest`
    /// during the acceptance, and the connection runs the registered work in
    /// order. Thus the work that this method registers runs after the work
    /// of the prompt. A model prompt ends later, in the ``SessionProjector``,
    /// so the work waits for the end of the prompt
    /// (``PromptStateOwner/waitForPromptEnd()``), and then it reads the stop
    /// reason from the prompt-state owner. An accepted prompt always has a
    /// bound connection.
    ///
    /// - Parameters:
    ///   - span: The span of the prompt.
    ///   - measurement: The measurement of the prompt.
    ///   - owner: The prompt-state owner of the prompt.
    private func endTelemetryAfterPrompt(span: any Span, measurement: PromptMeasurement, owner: PromptStateOwner) {
        boundConnection?.afterRespondingToCurrentRequest {
            await owner.waitForPromptEnd()
            let stopReason = await owner.stopReason
            RequestTracing.endPromptSpan(span, stopReason: stopReason)
            measurement.record(stopReason: stopReason)
        }
    }

    /// Accepts one prompt: the work of ``prompt(_:)`` before the response.
    ///
    /// The checks that can refuse the prompt run before the response: a
    /// closed session gives an error before the insertion of the user
    /// message, which ACP permits (task ^he1rmw6, decision G3).
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The response that names the user message, and the
    ///   prompt-state owner of the prompt.
    /// - Throws: The errors that ``prompt(_:)`` names.
    private func acceptPrompt(_ params: PromptRequest) async throws -> (PromptResponse, PromptStateOwner) {
        try requireInitialized(before: ACPMethod.sessionPrompt)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        guard entry.availability != .closed else {
            throw RequestError.closedSession(id: params.sessionId)
        }
        // A replay-only session has no tool surface, because its working
        // directory does not exist, so no prompt and no command runs in it.
        guard !entry.isReplayOnly else {
            throw RequestError.missingSessionWorkingDirectory(id: params.sessionId)
        }
        guard let connection = boundConnection else {
            throw RequestError.internalError(
                detail: "the agent has no bound connection to notify through")
        }

        // A leading /name goes through the registry before anything
        // touches the session. It never reaches the
        // model as a prompt.
        if let command = CommandDispatch.parseCommand(blocks: params.prompt) {
            return try await dispatchCommand(
                command, params: params, entry: entry, connection: connection)
        }

        let owner = beginPrompt(params: params)
        let response = scheduleModelPrompt(
            overridePrompt: nil,
            params: params, entry: entry, connection: connection, owner: owner,
            send: historySink(for: params.sessionId, connection: connection))
        return (response, owner)
    }

    /// Registers one prompt in flight: installs a fresh prompt-state owner
    /// over the state ledger of the session in the list of open prompts.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The installed owner.
    func beginPrompt(params: PromptRequest) -> PromptStateOwner {
        let sessionId = params.sessionId
        guard let ledger = sessions[sessionId]?.stateLedger else {
            // A `session/delete` can remove the entry while a `.rendered`
            // command renders. The prompt still gets an owner, over a
            // ledger of its own.
            return PromptStateOwner(send: boundHistorySink(for: sessionId))
        }
        let owner = PromptStateOwner(ledger: ledger)
        sessions[sessionId]?.openPrompts.append(owner)
        return owner
    }

    /// Inserts the user message of one model prompt, defers the prompt to
    /// run after the response through `afterRespondingToCurrentRequest`, and
    /// returns at once a response that names the user message. Never a
    /// detached task that races the response.
    ///
    /// The prompt keeps the fixed order of elicitation-plan task 49, all in
    /// the hooks that run after the response: (1) the `session/prompt`
    /// response, (2) the `user_message` echo, (3) `running`, (4) the mail of
    /// the prompt. The `messageId` of the response and of the echo is the
    /// `MailID` of the mail, so the headless CLI finds the `idle` of its own
    /// prompt (task 43).
    ///
    /// - Parameters:
    ///   - overridePrompt: The expanded command text that replaces the
    ///     blocks' text as the model prompt, or `nil` for a plain
    ///     prompt.
    ///   - params: The prompt request.
    ///   - entry: The session's table entry.
    ///   - connection: The bound connection the prompt registers with.
    ///   - owner: The prompt-state owner ``beginPrompt(params:)`` installed.
    ///   - send: The sink of the first-activity update of the prompt.
    /// - Returns: The response that names the user message.
    func scheduleModelPrompt(
        overridePrompt: String?,
        params: PromptRequest,
        entry: ActiveSession,
        connection: AgentSideConnection,
        owner: PromptStateOwner,
        send: @escaping SessionUpdateSink
    ) -> PromptResponse {
        let sessionId = params.sessionId
        let mailId = MailID()
        let messageId = insertUserMessage(
            params, messageId: MessageId(rawValue: mailId.description), through: connection)
        // The session of the selected slot when the prompt is accepted: a
        // later model slot switch does not move this prompt.
        let session = entry.session
        let projector = entry.projector
        let execution = PromptExecution(
            sessionId: sessionId,
            promptBlocks: params.prompt,
            promptState: owner,
            send: send,
            firstActivity: makeFirstActivity(for: sessionId, entry: entry, blocks: params.prompt),
            modelName: ConfigOptions.handle(for: entry.selectedSlot, of: residentProfile)
                .chosen.stringValue,
            modelPrompt: overridePrompt,
            contentResolver: ResourceLinkResolver(readVerb: entry.surface.filesReadVerb))
        // The prompt span context goes with the work, so each Router
        // submission span of the prompt is a child of the prompt span.
        connection.afterRespondingInCurrentServiceContext {
            await execution.run(mailId: mailId, session: session, projector: projector) { _ in
                await self.promptFinished(owner, sessionId: sessionId)
            }
        }
        return PromptResponse(messageId: messageId)
    }

    /// Stops the work of one session: records the request on each open
    /// prompt, answers every pending elicitation with `cancel` — the
    /// suspended tool must resume — then cancels the work of the Router
    /// session with `cancelAll()`: the queued mail, the model work in
    /// flight, and the background runs. A submission that waits for a place
    /// in the model queue is in flight too, and the cancel reaches it: the
    /// Router removes it from the queue at once, so the `idle(cancelled)`
    /// terminator does not wait for the submission of another session. A
    /// notification has no response, so an unknown or a closed session is
    /// logged and ignored.
    ///
    /// The notification runs in one server span (``RequestTracing``).
    ///
    /// - Parameter params: The cancellation notification.
    public func sessionCancel(_ params: CancelSessionNotification) async {
        await RequestTracing.withRequestSpan(
            ACPAgentTelemetry.SpanName.cancel, method: ACPMethod.sessionCancel, sessionId: params.sessionId,
            meta: params.meta
        ) { _ in
            await cancelRunningPrompt(params)
        }
    }

    /// Cancels the work of one session and its open prompts: the work of
    /// ``sessionCancel(_:)``. Each open prompt ends with the `cancelled` stop
    /// reason no later than the `signalDone` of the `cancelAll()` signal, so
    /// the cancel ends with `idle` and `cancelled` (an ACP rule).
    ///
    /// - Parameter params: The cancellation notification.
    private func cancelRunningPrompt(_ params: CancelSessionNotification) async {
        guard let entry = sessions[params.sessionId], !entry.isClosed else {
            ACPAgentTelemetry.logger(.promptExecution).notice(
                "A session/cancel found no open session. The agent ignores it.",
                metadata: ACPAgentTelemetry.sessionMetadata(params.sessionId))
            return
        }
        for owner in entry.openPrompts {
            await owner.noteCancelRequested()
        }
        await entry.projector.relay?.cancelPendingElicitations()
        // `cancelAll()` stops all the work of the session, also with no
        // prompt open: queued mail, the answer in flight, and the background
        // runs (elicitation-plan task 3). With no prompt open, no state
        // update goes out (task ^9xs24pn, decisions Q2 and G6).
        let signal = entry.session.cancelAll()
        if !entry.openPrompts.isEmpty {
            entry.projector.cancelSent(signal)
        }
        var metadata = ACPAgentTelemetry.sessionMetadata(params.sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.cancelSignalId] = "\(signal)"
        ACPAgentTelemetry.logger(.promptExecution).info("The session cancelled its work.", metadata: metadata)
    }

    /// Marks the session closed. The session-close task
    /// flips this after its sweep; the prompt refusal reads it.
    ///
    /// It also finishes the session's host-owned shell output stream:
    /// a host that stops listening must call
    /// `finish()`, and the finish ends the terminal projection's
    /// consumer loop.
    ///
    /// A closed session is no longer open, so the mark records the
    /// `active_sessions` gauge again.
    ///
    /// - Parameter sessionId: The session to mark.
    func markSessionClosed(_ sessionId: SessionId) {
        sessions[sessionId]?.isClosed = true
        sessions[sessionId]?.surface.shellOutput?.finish()
        recordActiveSessions()
    }

    /// Clears one finished prompt from the list of open prompts. Runs after
    /// the prompt ended. The ``SessionProjector`` runs it for a model
    /// prompt, and the command dispatch runs it for an `.action` command.
    /// It first writes the retained history of the session
    /// (``writeHistory(of:)``), so a new process can resume the session with
    /// the messages of this prompt. When no prompt is open any more, it then
    /// reconciles the config-option state: a prompt that ran on a model the
    /// announced options do not show pushes one `config_option_update`,
    /// after the terminator.
    ///
    /// - Parameters:
    ///   - owner: The prompt-state owner of the finished prompt.
    ///   - sessionId: The session whose prompt finished.
    func promptFinished(_ owner: PromptStateOwner, sessionId: SessionId) async {
        writeHistory(of: sessionId)
        sessions[sessionId]?.openPrompts.removeAll { $0 === owner }
        guard sessions[sessionId]?.openPrompts.isEmpty ?? false else {
            return
        }
        await reconcileConfigOptions(for: sessionId)
    }

    /// The first-activity index write, or `nil` when the session already
    /// has its record. A session with zero prompts is not listed, so the
    /// record waits for the first prompt. Marks the record written at
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
