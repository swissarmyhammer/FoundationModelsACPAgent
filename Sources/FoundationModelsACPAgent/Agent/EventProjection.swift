import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter
import Logging

/// Reads the stored raw output of a settled run, keyed by the run's
/// `commandID` — which is its `completionToken` and its `toolCallId`
/// (plan.md §11.8). The production reader is the host-owned
/// `ShellOutputChunkStream.snapshot(for:)`; a prompt with no shell mount
/// reads nothing.
typealias ShellSnapshotProvider = @Sendable (_ commandID: String) -> ShellOutputSnapshot?

/// One file change, in this package's own vocabulary (plan.md §11.6).
///
/// The projection owns this mirror of Multitool's `FileChange`, which
/// `EventProjection.projectedChange(for:)` maps into. A move and a copy
/// carry both endpoints, which is what makes the §11.6 path-direction
/// mapping total: ACP's `path` is post-operation, so the source becomes
/// `oldPath` and the destination becomes `path` for those two kinds
/// only. Each endpoint is an `AbsolutePath`, so a record the wire
/// cannot carry is refused at the mapping instead of on the wire.
enum ProjectedFileChange: Equatable, Sendable {
    /// A file that did not exist was created at `path`.
    case add(path: AbsolutePath)

    /// The file at `path` was removed.
    case delete(path: AbsolutePath)

    /// The file at `path` was rewritten in place.
    case modify(path: AbsolutePath)

    /// The file at `source` was renamed to `destination`.
    case move(source: AbsolutePath, destination: AbsolutePath)

    /// The file at `source` was duplicated to `destination`.
    case copy(source: AbsolutePath, destination: AbsolutePath)
}

/// The one mapping from Router's event stream to the wire
/// (plan.md §8.4–§8.5, §11.6).
///
/// One value projects one prompt: `project(_:)` maps each
/// `SessionEvent` case, and `reportUsage()` closes the prompt with its
/// one summed `usage_update`. The live shell bytes have no
/// `SessionEvent` source, so their mapping rides ``TerminalStream``
/// over the host-owned `ShellOutputChunkStream` (§11.8); this
/// projection's settlement carries the matching `Terminal` reference.
struct EventProjection {
    // MARK: - The wire constants

    /// The extensible status a `.lost` outcome reports (plan.md §8.4).
    /// `.lost` never flattens into `failed`: "we do not know if this
    /// ran" is not the claim "this ran and failed".
    static let lostStatusWireValue = "_lost"

    /// The extensible status a terminal event with no outcome reports.
    /// The outcome rule is a doc comment upstream, not a type
    /// guarantee, so the projection survives the gap (plan.md §8.4).
    static let unknownOutcomeStatusWireValue = "_unknown"

    /// The prefix the §18 extension rule puts on a custom wire value.
    private static let extensionValuePrefix = "_"

    /// The text that rides with the `_lost` status, for clients that
    /// ignore custom status values (plan.md §8.4).
    private static let lostNoteText = "we do not know if this ran"

    /// The text that names the timeout on a `timedOut` settlement.
    private static let timedOutNoteText = "the run timed out"

    /// The text of a `stopped` settlement: the kill is authoritative.
    private static let stoppedNoteText = "the run was stopped; the work is dead"

    /// The text of a `cancelled` settlement (plan.md §8.4, §8.6): the
    /// request is advisory past a process boundary, so the honest claim
    /// is that we stopped listening, not that the work stopped.
    private static let cancelledNoteText = "we stopped listening; the work can continue"

    /// The text of a terminal event that carries no outcome.
    private static let missingOutcomeNoteText = "the run ended with no recorded outcome"

    // MARK: - The prompt's wiring

    /// The id of the session this projection reports for, in the logs.
    let sessionId: SessionId

    /// The prompt-state owner: `submissionStarted` maps through it (§8.2).
    let promptState: PromptStateOwner

    /// The sink every update of this projection goes to.
    let send: SessionUpdateSink

    /// The model reference the session generates with. The log line of a
    /// wait for a place in the model queue names it, so a person who reads
    /// the log learns which model was busy.
    let modelName: String

    /// The reader of a settled run's stored output, for the §11.6
    /// convergence replace. The default finds no run.
    var shellSnapshot: ShellSnapshotProvider = { _ in nil }

    /// The handler of a live elicitation request (plan.md §16), or `nil`
    /// when no relay is wired — a synthetic projection drive. The
    /// production wiring supplies ``ElicitationRelay/relay(_:on:promptState:)``
    /// bound to the prompt's session and owner.
    var relayElicitation: ElicitationEventHandler?

    // MARK: - The prompt's mutable state

    /// The one agent message id of the current message, made at the
    /// first text delta (§8.3: a new id starts a new message).
    private var agentMessageId: MessageId?

    /// The one agent thought id of the current reasoning message.
    private var thoughtMessageId: MessageId?

    /// The prompt tokens summed across every `submissionEnded` (§8.1).
    private var tokensIn = 0

    /// The completion tokens summed across every `submissionEnded`.
    private var tokensOut = 0

    /// The finish reason of the last submission of the prompt, or `nil`
    /// before the first `submissionEnded`.
    ///
    /// `PromptExecution.drive` reads it to report the honest stop reason of
    /// a prompt whose last submission did not end by itself (tasks ^bw9qt1z,
    /// ^k51h6bb and ^7fsfw7y): the text, the reasoning or the tool call of
    /// that generation is cut, so the prompt must not read as a normal
    /// `end_turn`.
    private(set) var lastFinishReason: FinishReason?

    /// The numbers behind a stop reason, as log metadata, for the record of a
    /// prompt that ended cut or empty.
    ///
    /// A `_truncated`, `_ended_in_reasoning`, `_repeated` or
    /// `_reasoning_limit` prompt says how the last submission stopped, and
    /// nothing more. The reader then cannot
    /// tell a model that reasoned too long in one round from a context that
    /// filled up. These three numbers name the difference: the tokens the
    /// whole prompt fed and generated, and how full the context was at the
    /// last report.
    var usageMetadata: Logger.Metadata {
        let fill = contextFill.isNaN ? "unknown" : String(format: "%.3f", contextFill)
        return [
            ACPAgentTelemetry.LogMetadataKey.tokensIn: "\(tokensIn)",
            ACPAgentTelemetry.LogMetadataKey.tokensOut: "\(tokensOut)",
            ACPAgentTelemetry.LogMetadataKey.contextFill: "\(fill)",
        ]
    }

    /// The newest context fill. `nan` means "no stamp": send no meter
    /// for the prompt (§8.4).
    private var contextFill = Double.nan

    /// Whether the prompt produced observable output: a text delta, a
    /// reasoning delta, a tool call or status, an invocation record,
    /// an attachment report, a relayed elicitation, or a run
    /// settlement (task ^pez780d).
    ///
    /// `PromptExecution.drive` reads it beside a stall report as well: a
    /// prompt that already produced something is not waiting on a model
    /// that cannot generate (task ^s0bw5cv).
    private(set) var sawOutput = false

    /// Whether at least one `submissionEnded` usage report arrived
    /// (task ^pez780d).
    private var sawUsageReport = false

    /// Whether an `answered` event sends its reply as one agent message
    /// (task ^64pav2a). `PromptExecution.drive` sets it for the session
    /// events that come after the caller answer. An answer that mail
    /// starts gives its reply whole and streams no text delta, so the
    /// reply is the only carrier of its text. The caller stream streams its
    /// text, so its `answered` sends nothing.
    var projectsWholeReplies = false

    /// Whether a text delta arrived since the last end of an answer. An
    /// answer that streamed its text does not send its reply again.
    private var streamedTextInAnswer = false

    /// Whether the prompt generated nothing: no observable output, while
    /// at least one `submissionEnded` arrived and the summed output tokens
    /// are zero. `PromptExecution.drive` reads it to report the honest
    /// `_no_output` stop reason instead of a bare `end_turn`
    /// (plan.md §8.2's `_` rule; task ^pez780d).
    var generatedNothing: Bool {
        !sawOutput && sawUsageReport && tokensOut == 0
    }

    /// The metadata of a record about one run of this prompt: the session id
    /// and the tool call id of the run.
    ///
    /// - Parameter runId: The correlation id of the run, which is its tool
    ///   call id.
    /// - Returns: The metadata.
    private func runMetadata(_ runId: String) -> Logger.Metadata {
        var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.toolCallId] = "\(runId)"
        return metadata
    }

    /// The metadata of a record about one Router event that the projection
    /// does not send: the session id and the case of the event. The payload
    /// of the event is not in the record, because it can hold content.
    ///
    /// - Parameter event: The event.
    /// - Returns: The metadata.
    private func eventMetadata(_ event: SessionEvent) -> Logger.Metadata {
        var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.eventKind] = "\(ACPAgentTelemetry.caseName(of: event))"
        return metadata
    }

    // MARK: - The SessionEvent cases (§8.4)

    /// Projects one event to the wire.
    ///
    /// The switch lists every case and keeps an `@unknown default`
    /// arm: `SessionEvent` has no library evolution, and its own
    /// contract tells a consumer to absorb a new case rather than
    /// break.
    ///
    /// A prompt can make more than one Router submission: a tool call, a
    /// retry after an overflow, or a continuation starts a new one. The
    /// first `submissionStarted` sends `running`. Each `submissionEnded`
    /// adds its usage to the one sum of the prompt.
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: SessionEvent) async {
        switch event {
        case .submissionStarted:
            await promptState.promptDidStart()
        case .textDelta(let text):
            sawOutput = true
            streamedTextInAnswer = true
            let messageId = agentMessageId ?? Self.makeMessageId()
            agentMessageId = messageId
            await send(
                .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .textReset:
            // "Discard the text collected so far" cannot ride as a
            // chunk: send the whole-message form, which replaces
            // everything accumulated (§8.3). With no message yet there
            // is nothing to discard.
            guard let messageId = agentMessageId else { return }
            await send(.agentMessage(AgentMessage(messageId: messageId, content: .value([]))))
        case .reasoningDelta(let text):
            sawOutput = true
            let messageId = thoughtMessageId ?? Self.makeMessageId()
            thoughtMessageId = messageId
            await send(
                .agentThoughtChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .toolCall(let id, let name, let argumentsJSON):
            sawOutput = true
            await projectToolCall(id: id, name: name, argumentsJSON: argumentsJSON)
        case .toolStatus(let id, let status, let summary, let output):
            sawOutput = true
            await projectToolStatus(id: id, status: status, summary: summary, output: output)
        case .toolInvocation(let record):
            sawOutput = true
            // A correlation record only, never a wire message: its
            // `correlationID` is the run's completion token, a
            // different identity space from `Transcript.ToolCall.id`.
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The prompt recorded a tool invocation.", metadata: runMetadata(record.correlationID))
        case .entryRecorded(let id, let kind):
            closeMessage(recordedEntryId: id, kind: kind)
        case .compactionStarted(let start):
            await compactionReporter.reportAutomaticStart(start)
        case .compaction(let result):
            await compactionReporter.reportAutomaticCompaction(result)
        case .compactionFailed(let failure):
            await compactionReporter.reportAutomaticFailure(failure)
        case .discoveryPrimingFailed(let failure):
            var metadata = ACPAgentTelemetry.errorMetadata(failure, sessionId: sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.errorCase] = "\(ACPAgentTelemetry.caseName(of: failure))"
            ACPAgentTelemetry.logger(.promptExecution).error(
                "The discovery priming failed. The answer generates with no seed.", metadata: metadata)
        case .generationStalled(let stall):
            // A report, not a bound (§8.4): the generation continues.
            var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
            metadata[ACPAgentTelemetry.LogMetadataKey.routerReport] = "\(stall.description)"
            ACPAgentTelemetry.logger(.promptExecution).notice(
                "A generation made no progress for one stall interval.", metadata: metadata)
        case .runSettled(let operationEvent):
            sawOutput = true
            await projectSettlement(of: operationEvent)
        case .toolCallReport(let report):
            // The "at least one attachment" rule is a doc comment
            // upstream, not a type guarantee: an empty report sends
            // nothing, because an empty content replace would erase
            // the call's content.
            guard !report.attachments.isEmpty else {
                ACPAgentTelemetry.logger(.promptExecution).warning(
                    "A tool call report had no attachments. Nothing goes to the wire.",
                    metadata: runMetadata(report.correlationID))
                return
            }
            sawOutput = true
            await projectToolCallReport(report)
        case .elicitationRequested(let operationEvent):
            // The relay runs the round trip inline (plan.md §16): the
            // asking tool is suspended in Router's mailbox until the
            // answer is delivered, so holding this drive loop holds
            // nothing the prompt could otherwise do.
            guard let relayElicitation else {
                ACPAgentTelemetry.logger(.promptExecution).notice(
                    "A run requested an elicitation, but no relay is wired. The agent only logs the request.",
                    metadata: runMetadata(operationEvent.correlationID))
                return
            }
            sawOutput = true
            await relayElicitation(operationEvent)
        case .submissionEnded(let end):
            // One event per submission, not per prompt: sum, and never
            // send `idle` from here (§8.1). The LAST submission is the
            // one that ends the prompt, so its finish reason wins over
            // each earlier one.
            lastFinishReason = end.finishReason
            guard let usage = end.usage else { return }
            sawUsageReport = true
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
        case .generationCall:
            // The usage of one generation call alone. The
            // `submissionEnded` sum above already counts these tokens,
            // so no wire update goes out.
            break
        case .submissionQueued:
            // A log line, not a wire message (§8.4).
            reportQueueWait()
        case .repetitionStopped(let stop):
            // A log line, not a wire message (§8.4): the stop reason of
            // the prompt carries the end, and the next submission of a
            // recovery carries the text.
            reportRouterStop(
                stop, message: "Router stopped a generate call, because the call repeated itself.")
        case .reasoningStopped(let stop):
            // A log line, not a wire message (§8.4), as for a repetition
            // stop (task ^7fsfw7y).
            reportRouterStop(
                stop, message: "Router stopped a pass, because the pass reasoned and did not act.")
        case .answered(let answer):
            await projectReply(of: answer)
        case .answerFailed, .mailDeliveryPaused:
            // Router bookkeeping with no ACP counterpart: the drive of the
            // prompt reads the end of an answer for the stop reason.
            streamedTextInAnswer = false
            reportUnsentEvent(event)
        @unknown default:
            // `SessionEvent` requires a default arm by its own
            // contract: a new case degrades to a log line, never to a
            // broken stream.
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The projection does not know a Router event.", metadata: eventMetadata(event))
        }
    }

    /// Sends the reply of `answer` as one agent message when the reply is
    /// the only carrier of the answer text (``projectsWholeReplies``, task
    /// ^64pav2a). An answer that streamed its text, and an empty reply,
    /// send nothing. The usage of `answer` is the total of the chain, and
    /// the `submissionEnded` sum already counts it, so the projection does
    /// not add it again.
    ///
    /// - Parameter answer: The final answer of one chain of submissions.
    private mutating func projectReply(of answer: SessionAnswer) async {
        let streamedText = streamedTextInAnswer
        streamedTextInAnswer = false
        guard projectsWholeReplies, !streamedText, !answer.reply.isEmpty else {
            reportUnsentEvent(.answered(answer))
            return
        }
        sawOutput = true
        await send(
            .agentMessageChunk(
                ContentChunk(content: .text(TextContent(text: answer.reply)), messageId: Self.makeMessageId())))
    }

    /// Records a Router event that the projection does not send. The record
    /// is a `debug`, because the event is bookkeeping with no ACP
    /// counterpart.
    ///
    /// - Parameter event: The event.
    private func reportUnsentEvent(_ event: SessionEvent) {
        ACPAgentTelemetry.logger(.promptExecution).debug(
            "The projection sends nothing for a Router event.", metadata: eventMetadata(event))
    }

    /// Records that a submission of the prompt waits for a place in the
    /// model queue, because the model runs a submission of another session.
    ///
    /// plan.md §8.4 gives the wait no wire message. The wait is not a
    /// stall: the Router stall watch does not count it (Router task
    /// ^ake8sax), so it never ends the prompt with `_stalled`. The record is
    /// a `notice` and not a `debug`, because a person who reads the log of
    /// a slow prompt must learn that the prompt waited, and for which
    /// model.
    private func reportQueueWait() {
        ACPAgentTelemetry.logger(.promptExecution).notice(
            "A submission waits for a place in the model queue, because the model runs a submission of another session.",
            metadata: ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName))
    }

    /// Records that Router stopped a generation of the prompt: a generate
    /// call that repeated itself (``RepetitionStop``, task ^k51h6bb), or a
    /// pass that reasoned and did not act (``ReasoningStop``, task ^7fsfw7y).
    ///
    /// plan.md §8.4 gives the stop no wire message. The record is a `notice`
    /// and not a `debug`, because a person who reads the log of a slow or
    /// cut prompt must learn that Router stopped a generation, with the
    /// numbers of the stop and the settings in force. A repetition stop
    /// gives its line counts. A reasoning stop gives its reasoning tokens,
    /// the limit, the finish reason of the pass and the recovery. When no
    /// recovery is left, the prompt ends with the `_repeated` or the
    /// `_reasoning_limit` stop reason, and this record is the one place that
    /// gives those numbers.
    ///
    /// - Parameters:
    ///   - stop: The report Router made. Its description holds counts and
    ///     settings only, never content.
    ///   - message: The message of the record, which names the kind of stop.
    private func reportRouterStop(_ stop: some CustomStringConvertible, message: Logger.Message) {
        var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
        metadata[ACPAgentTelemetry.LogMetadataKey.routerReport] = "\(stop.description)"
        ACPAgentTelemetry.logger(.promptExecution).notice(message, metadata: metadata)
    }

    /// Sends the one `usage_update` of the prompt, from the summed
    /// usage. A `nan` context fill means "no stamp": no meter goes on
    /// the wire (plan.md §8.4).
    func reportUsage() async {
        let used = tokensIn + tokensOut
        guard used > 0, contextFill.isFinite, contextFill > 0 else {
            return
        }
        // `contextFill` is used divided by size, so the size is derived.
        let size = Int((Double(used) / contextFill).rounded())
        await send(.usageUpdate(UsageUpdate(size: max(size, used), used: used)))
    }

    // MARK: - The tool-call upsert (§11.6)

    /// Sends the creating `tool_call_update`: v2 has no create
    /// variant, so the first update with an unseen `toolCallId` is the
    /// creation. It carries the tool name twice: as the `name` for a
    /// program (ACP schema-v2.0.0-alpha.7), and as the title for a
    /// person. It says `in_progress` — the call already runs, and
    /// `pending` is the default a creating update must not leave in place.
    ///
    /// - Parameters:
    ///   - id: Apple's `Transcript.ToolCall.id`, passed through
    ///     unchanged.
    ///   - name: The tool name; the creation's name and title.
    ///   - argumentsJSON: The call's arguments, the structured
    ///     per-call record `rawInput` parses from.
    private func projectToolCall(id: String, name: String, argumentsJSON: String) async {
        let rawInput: PatchField<FoundationModelsACP.JSONValue>
        if let value = Self.jsonValue(from: argumentsJSON) {
            rawInput = .value(value)
        } else {
            var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.toolCallId] = "\(id)"
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "The arguments of a tool call did not parse as JSON.", metadata: metadata)
            rawInput = .unchanged
        }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: id),
                    name: .value(name),
                    rawInput: rawInput,
                    status: .value(.inProgress),
                    title: .value(name))))
    }

    /// Sends the lifecycle `tool_call_update` of one SDK tool call:
    /// the status maps from Router's three-case vocabulary, and the
    /// answering output segments replace the call's content.
    ///
    /// - Parameters:
    ///   - id: Apple's `Transcript.ToolCall.id`.
    ///   - status: Router's status, derived from the transcript diff.
    ///   - summary: Router's one-line result summary, or `nil`.
    ///   - output: The segments of the answering `.toolOutput` entry,
    ///     or `nil` before completion.
    private func projectToolStatus(
        id: String,
        status: FoundationModelsRouter.ToolCallStatus,
        summary: String?,
        output: [SegmentPayload]?
    ) async {
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: id),
                    content: Self.contentPatch(summary: summary, output: output),
                    rawOutput: Self.rawOutputPatch(from: output),
                    status: .value(Self.wireStatus(for: status)))))
    }

    /// Closes the message the recorded entry ended (§8.3, §8.4): the
    /// next delta of that kind starts a new message id.
    ///
    /// - Parameters:
    ///   - recordedEntryId: The recorded `Transcript.Entry.id`, for
    ///     the log line only.
    ///   - kind: The kind of the recorded entry.
    private mutating func closeMessage(recordedEntryId: String, kind: RecordedEntryKind) {
        switch kind {
        case .response:
            agentMessageId = nil
        case .reasoning:
            thoughtMessageId = nil
        case .toolCalls:
            break
        @unknown default:
            var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.entryId] = "\(recordedEntryId)"
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The projection sends nothing for a recorded entry of an unmapped kind.", metadata: metadata)
        }
    }

    // MARK: - Compaction (§8.5)

    /// The reporter of the automatic compactions of the prompt
    /// (``CompactionReporter``). Router reports each automatic compaction
    /// with `compactionStarted`, then `compaction` or `compactionFailed`
    /// with the same id. The reporter sends the `in_progress` update, then
    /// the terminal update, keyed by that id, and the `usage_update` of a
    /// completed compaction. It sends them through ``send``, the history
    /// sink, thus the retained history keeps the final status. No message
    /// update clears or rewrites anything: a compaction changes only the
    /// model context.
    private var compactionReporter: CompactionReporter {
        CompactionReporter(sessionId: sessionId, send: send)
    }

    // MARK: - The settlement (§8.4, §11.6)

    /// Sends the terminal `tool_call_update` of a settled run. The `op`
    /// rides as the title and the tool as the `name`, because a settlement
    /// can be the creation of the wire call of a run.
    ///
    /// The envelope is read defensively: the "outcome is non-nil if
    /// and only if the kind is `.completed`" rule is a doc comment
    /// upstream, not a type guarantee. A non-terminal event settles
    /// nothing — an outcome riding on it is ignored — and a terminal
    /// event with no outcome reports the unknown status.
    ///
    /// A run the shell store knows replaces the call's content with
    /// its `Terminal` reference and the capture's honesty notes
    /// (§11.8): the bytes ride the terminal stream, never coerced to
    /// text, and a reconnecting client takes the
    /// `TerminalUpdate.output` replacement instead.
    ///
    /// - Parameter operationEvent: The run's operation event.
    private func projectSettlement(of operationEvent: OperationEvent) async {
        guard operationEvent.kind == .completed else {
            if operationEvent.outcome != nil {
                ACPAgentTelemetry.logger(.promptExecution).warning(
                    "A run carried an outcome on an event that is not terminal. The projection ignores the outcome.",
                    metadata: runMetadata(operationEvent.correlationID))
            }
            return
        }
        let status: FoundationModelsACP.ToolCallStatus
        if let outcome = operationEvent.outcome {
            status = Self.wireStatus(for: outcome)
        } else {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A run completed with no outcome.", metadata: runMetadata(operationEvent.correlationID))
            status = .unknown(Self.unknownOutcomeStatusWireValue)
        }
        var items = Self.contents(
            of: shellSnapshot(operationEvent.correlationID),
            run: operationEvent.correlationID)
        if let note = Self.note(for: operationEvent.outcome) {
            items.append(Self.textItem(note))
        }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: operationEvent.correlationID),
                    content: items.isEmpty ? .unchanged : .value(items),
                    name: .value(operationEvent.tool),
                    status: .value(status),
                    title: .value(operationEvent.op))))
    }

    // MARK: - The attachment report (§8.4, §11.6)

    /// Sends the attachment `tool_call_update` of one closed call: the
    /// update keys on the run's `correlationID` — its
    /// `completionToken`, its `toolCallId` — carries each attached
    /// document as one content item in call order, and puts the parsed
    /// documents in `rawOutput`. The `op` rides as the title and the
    /// tool as the `name`, because this update can be the creation of the
    /// wire call.
    ///
    /// The update claims no status: the report records what the call
    /// attached, not how the call ended, and the terminal claim
    /// belongs to `toolStatus` and `runSettled`.
    ///
    /// It fills `locations` from the one attachment shape that carries
    /// a path contract: the `FileChangeSet` envelope a mutating files
    /// verb attaches (`schemaName` ``FoundationModelsMultitool/FileChangeSet/operationEventDetailKey``).
    /// The paths come from the structured record, never from a rendered
    /// string (§11.5), and replace the array as a whole (§11.6). Every
    /// other attachment is an opaque document with no path contract, so
    /// a report of such documents alone leaves `locations` unchanged
    /// rather than erasing it.
    ///
    /// - Parameter report: The report of the call's attachments.
    private func projectToolCallReport(_ report: ToolCallReport) async {
        let documents = report.attachments.map(\.contentJSON)
        let changes = Self.fileChanges(in: report.attachments)
        let locations = changes.compactMap { change in
            Self.projectedChange(for: change).map(Self.location(for:))
        }
        if locations.count < changes.count {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A run recorded a file change that the wire cannot carry. The change has no location on the wire.",
                metadata: runMetadata(report.correlationID))
        }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: report.correlationID),
                    content: .value(documents.map(Self.textItem)),
                    locations: locations.isEmpty ? .unchanged : .value(locations),
                    name: .value(report.tool),
                    rawOutput: Self.rawOutputPatch(fromDocuments: documents),
                    title: .value(report.op))))
    }

    // MARK: - The status functions (§8.4)

    /// The one total `OperationOutcome` to `ToolCallStatus` function.
    ///
    /// Router holds no such mapping; this package owns it, once, for
    /// every event-posting capability. A new upstream outcome degrades
    /// the display through the `_` rule, never the stream.
    ///
    /// - Parameter outcome: How the run ended.
    /// - Returns: The wire status.
    static func wireStatus(for outcome: OperationOutcome) -> FoundationModelsACP.ToolCallStatus {
        switch outcome {
        case .succeeded:
            .completed
        case .failed, .timedOut:
            // `timedOut` is a failure, not a cancellation: nobody
            // asked for the stop. The settlement text names it.
            .failed
        case .stopped, .cancelled:
            .cancelled
        case .lost:
            // Never `failed`: "we do not know if this ran" is not the
            // claim "this ran and failed".
            .unknown(lostStatusWireValue)
        case .other(let raw):
            .unknown(extensionValue(raw))
        @unknown default:
            .unknown(extensionValue(outcome.rawValue))
        }
    }

    /// Maps Router's three-case tool-call status to the wire.
    ///
    /// - Parameter status: The diff-derived status.
    /// - Returns: The wire status.
    static func wireStatus(
        for status: FoundationModelsRouter.ToolCallStatus
    ) -> FoundationModelsACP.ToolCallStatus {
        switch status {
        case .running: .inProgress
        case .completed: .completed
        case .failed: .failed
        }
    }

    /// The text that rides with a settlement, or `nil` when the
    /// status alone says everything (§8.4's text column).
    ///
    /// - Parameter outcome: How the run ended, or `nil` for a
    ///   terminal event that carried no outcome.
    /// - Returns: The note, or `nil`.
    private static func note(for outcome: OperationOutcome?) -> String? {
        guard let outcome else { return missingOutcomeNoteText }
        switch outcome {
        case .succeeded, .failed:
            // The status says it; a failure's detail stays with the
            // emitting tool's own dialect, which this mapping never
            // parses.
            return nil
        case .timedOut:
            return timedOutNoteText
        case .stopped:
            return stoppedNoteText
        case .cancelled:
            return cancelledNoteText
        case .lost:
            return lostNoteText
        case .other(let raw):
            return "the run ended with the outcome '\(raw)'"
        @unknown default:
            return "the run ended with the outcome '\(outcome.rawValue)'"
        }
    }

    /// Puts `raw` under the §18 extension rule: a custom wire value
    /// starts with `_`, and a value that already does stays as it is.
    ///
    /// - Parameter raw: The raw outcome value.
    /// - Returns: The extension wire value.
    private static func extensionValue(_ raw: String) -> String {
        raw.hasPrefix(extensionValuePrefix) ? raw : extensionValuePrefix + raw
    }

    // MARK: - The file-change path mappings (§11.6)

    /// The recorded file changes an attachment report carries, in call
    /// order.
    ///
    /// The one attachment shape with a path contract is the
    /// `FileChangeSet` envelope a mutating files verb attaches. Every
    /// other document contributes nothing: the schema name is matched
    /// against the upstream constant, and the envelope decode returns
    /// `nil` for text that is not a change set, so a document that only
    /// looks like one is refused as well.
    ///
    /// - Parameter attachments: The records the report carries.
    /// - Returns: The recorded changes.
    private static func fileChanges(
        in attachments: [ToolCallAttachment]
    ) -> [FoundationModelsMultitool.FileChange] {
        attachments.flatMap { attachment -> [FoundationModelsMultitool.FileChange] in
            guard attachment.schemaName == FileChangeSet.operationEventDetailKey,
                let set = FileChangeSet(operationEventDetail: attachment.contentJSON)
            else { return [] }
            return set.changes
        }
    }

    /// Maps one recorded file change into this package's vocabulary.
    ///
    /// Returns `nil` for a record the vocabulary cannot carry: a path
    /// the wire refuses because it is not absolute, or a move or a copy
    /// with no destination. The projection reports what the record
    /// says and never invents a path.
    ///
    /// - Parameter change: The recorded change.
    /// - Returns: The projected change, or `nil`.
    private static func projectedChange(
        for change: FoundationModelsMultitool.FileChange
    ) -> ProjectedFileChange? {
        guard let path = AbsolutePath(absolute: change.path) else { return nil }
        let destination = change.destinationPath.flatMap(AbsolutePath.init(absolute:))
        switch change.kind {
        case .add:
            return .add(path: path)
        case .delete:
            return .delete(path: path)
        case .modify:
            return .modify(path: path)
        case .move:
            guard let destination else { return nil }
            return .move(source: path, destination: destination)
        case .copy:
            guard let destination else { return nil }
            return .copy(source: path, destination: destination)
        }
    }

    /// Maps one file change to the location the call touched.
    ///
    /// The path is post-operation, the direction `diffChange(for:)`
    /// puts in the wire change's `path`: a move and a copy report the
    /// destination, so a rename points at the name the file carries
    /// now and never at one that is gone. Every other kind reports its
    /// one path.
    ///
    /// - Parameter change: The change to map.
    /// - Returns: The wire location.
    private static func location(for change: ProjectedFileChange) -> ToolCallLocation {
        switch change {
        case .add(let path), .delete(let path), .modify(let path):
            ToolCallLocation(path: path)
        case .move(_, let destination), .copy(_, let destination):
            ToolCallLocation(path: destination)
        }
    }

    /// Maps one file change to ACP's diff vocabulary. For a move and a
    /// copy the source becomes `oldPath` and the destination becomes
    /// `path` — ACP's `path` is absolute and post-operation. For the
    /// other kinds the one path maps without change.
    ///
    /// - Parameter change: The change to map.
    /// - Returns: The wire change.
    static func diffChange(for change: ProjectedFileChange) -> DiffChange {
        switch change {
        case .add(let path):
            DiffChange(operation: .add(DiffPathChange(path: path)))
        case .delete(let path):
            DiffChange(operation: .delete(DiffPathChange(path: path)))
        case .modify(let path):
            DiffChange(operation: .modify(DiffPathChange(path: path)))
        case .move(let source, let destination):
            DiffChange(operation: .move(DiffPathPairChange(oldPath: source, path: destination)))
        case .copy(let source, let destination):
            DiffChange(operation: .copy(DiffPathPairChange(oldPath: source, path: destination)))
        }
    }

    // MARK: - Helpers

    /// Makes one agent-owned message id (plan.md §8.3): a fresh ULID,
    /// in the id vocabulary the session ids already use.
    static func makeMessageId() -> MessageId {
        MessageId(rawValue: ULID.generate().description)
    }

    /// Wraps `text` as one plain tool-call content item.
    ///
    /// - Parameter text: The text of the item.
    /// - Returns: The content item.
    private static func textItem(_ text: String) -> ToolCallContent {
        .content(Content(content: .text(TextContent(text: text))))
    }

    /// The content replace of a `toolStatus` event: the summary first,
    /// then one item per output segment. `nil` on both sides leaves
    /// the content unchanged.
    ///
    /// - Parameters:
    ///   - summary: Router's one-line result summary, or `nil`.
    ///   - output: The answering output segments, or `nil`.
    /// - Returns: The content patch.
    private static func contentPatch(
        summary: String?, output: [SegmentPayload]?
    ) -> PatchField<[ToolCallContent]> {
        guard summary != nil || output != nil else { return .unchanged }
        var items: [ToolCallContent] = []
        if let summary {
            items.append(textItem(summary))
        }
        for payload in output ?? [] {
            items.append(contentItem(for: payload))
        }
        return .value(items)
    }

    /// One content item for one output segment. Text carries through;
    /// every other segment kind renders its most useful text form.
    ///
    /// - Parameter payload: The segment to render.
    /// - Returns: The content item.
    private static func contentItem(for payload: SegmentPayload) -> ToolCallContent {
        switch payload {
        case .text(_, let content):
            textItem(content)
        case .structure(_, _, let contentJSON):
            textItem(contentJSON)
        case .attachment(_, let label, let url):
            textItem(label ?? url ?? "attachment")
        case .custom(_, _, let contentJSON, let description):
            textItem(description ?? contentJSON)
        case .unknown(_, let description):
            textItem(description)
        @unknown default:
            textItem(String(describing: payload))
        }
    }

    /// The `rawOutput` patch of a `toolStatus` event, from the
    /// structured segments — never from a rendered string (§11.6).
    ///
    /// - Parameter output: The answering output segments, or `nil`.
    /// - Returns: The raw-output patch.
    private static func rawOutputPatch(from output: [SegmentPayload]?) -> PatchField<FoundationModelsACP.JSONValue> {
        rawOutputPatch(
            fromDocuments: (output ?? []).compactMap { payload -> String? in
                guard case .structure(_, _, let contentJSON) = payload else { return nil }
                return contentJSON
            })
    }

    /// The `rawOutput` patch of a set of JSON documents: one parsed
    /// document is the value itself; several become an array; none —
    /// text that does not parse included — leaves the field unchanged.
    ///
    /// - Parameter documents: The JSON documents.
    /// - Returns: The raw-output patch.
    private static func rawOutputPatch(
        fromDocuments documents: [String]
    ) -> PatchField<FoundationModelsACP.JSONValue> {
        let values = documents.compactMap { jsonValue(from: $0) }
        guard let first = values.first else { return .unchanged }
        return values.count == 1 ? .value(first) : .value(.array(values))
    }

    /// The settlement content of a stored run (§11.8): the `Terminal`
    /// reference first — the bytes ride the terminal stream, never a
    /// coerced text copy — then the honesty notes of each stored
    /// stream. An absent snapshot contributes nothing.
    ///
    /// - Parameters:
    ///   - snapshot: The stored raw output, or `nil`.
    ///   - commandID: The run's completion token; its `terminalId`.
    /// - Returns: The content items.
    private static func contents(
        of snapshot: ShellOutputSnapshot?, run commandID: String
    ) -> [ToolCallContent] {
        guard let snapshot else { return [] }
        return [TerminalStream.terminalItem(for: commandID)]
            + notes(for: snapshot.stdout, stream: .stdout)
            + notes(for: snapshot.stderr, stream: .stderr)
    }

    /// The honesty notes of one stored stream: the text says when the
    /// store dropped bytes to stay under its cap, and when the capture
    /// saw binary content — a partial or binary record must never read
    /// as a complete text one.
    ///
    /// - Parameters:
    ///   - output: The stored raw output of the stream.
    ///   - stream: Which of the two streams it is.
    /// - Returns: The note items; empty for a complete text capture.
    private static func notes(
        for output: ShellRawOutput, stream: ShellOutputStream
    ) -> [ToolCallContent] {
        var items: [ToolCallContent] = []
        if output.truncated {
            items.append(textItem("the stored \(streamName(for: stream)) output is truncated"))
        }
        if output.binaryDetected {
            items.append(
                textItem("the stored \(streamName(for: stream)) output carries binary content"))
        }
        return items
    }

    /// The display name of one shell output stream.
    ///
    /// - Parameter stream: The stream to name.
    /// - Returns: The name.
    private static func streamName(for stream: ShellOutputStream) -> String {
        switch stream {
        case .stdout: "stdout"
        case .stderr: "stderr"
        }
    }

    /// Parses a JSON string into a wire value, or `nil` when the text
    /// is not JSON.
    ///
    /// - Parameter json: The JSON text.
    /// - Returns: The value, or `nil`.
    private static func jsonValue(from json: String) -> FoundationModelsACP.JSONValue? {
        try? JSONDecoder().decode(FoundationModelsACP.JSONValue.self, from: Data(json.utf8))
    }
}
