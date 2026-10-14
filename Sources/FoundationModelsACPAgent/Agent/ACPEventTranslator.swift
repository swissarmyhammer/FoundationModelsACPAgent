import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import Logging

/// Reads the stored raw output of a settled run, keyed by the run's
/// `commandID`, which is its `completionToken`.
/// The production reader is the host-owned
/// `ShellOutputChunkStream.snapshot(for:)`; a prompt with no shell mount
/// reads nothing.
typealias ShellSnapshotProvider = @Sendable (_ commandID: String) -> ShellOutputSnapshot?

/// One file change, in this package's own vocabulary.
///
/// The translator owns this mirror of Multitool's `FileChange`, which
/// `ACPEventTranslator.projectedChange(for:)` maps into. A move and a copy
/// carry both endpoints, which is what makes the path-direction
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

/// The one mapping from Router's event stream to the wire.
///
/// One value translates the events of one session for the life of the
/// session (``SessionProjector``): `project(_:)` maps each `SessionEvent`
/// case. The live shell bytes have no `SessionEvent` source, so their
/// mapping rides ``TerminalStream`` over the host-owned
/// `ShellOutputChunkStream`; this translator's settlement carries the
/// matching `Terminal` reference.
struct ACPEventTranslator {
    // MARK: - The wire constants

    /// The extensible status a `.lost` outcome reports.
    /// `.lost` never flattens into `failed`: "we do not know if this
    /// ran" is not the claim "this ran and failed".
    static let lostStatusWireValue = "_lost"

    /// The extensible status a terminal event with no outcome reports.
    /// The outcome rule is a doc comment upstream, not a type
    /// guarantee, so the translator survives the gap: it logs the event
    /// and picks a safe status, and it does not crash.
    static let unknownOutcomeStatusWireValue = "_unknown"

    /// The prefix the ACP extension rule puts on a custom wire value.
    /// A bare unknown value is reserved for a future ACP variant.
    private static let extensionValuePrefix = "_"

    /// The text that rides with the `_lost` status, for clients that
    /// ignore custom status values.
    private static let lostNoteText = "we do not know if this ran"

    /// The text that names the timeout on a `timedOut` settlement.
    private static let timedOutNoteText = "the run timed out"

    /// The text of a `stopped` settlement: the kill is authoritative.
    private static let stoppedNoteText = "the run was stopped; the work is dead"

    /// The text of a `cancelled` settlement: the
    /// request is advisory past a process boundary, so the honest claim
    /// is that we stopped listening, not that the work stopped.
    private static let cancelledNoteText = "we stopped listening; the work can continue"

    /// The text of a terminal event that carries no outcome.
    private static let missingOutcomeNoteText = "the run ended with no recorded outcome"

    // MARK: - The wiring

    /// The id of the session this translator reports for, in the logs.
    let sessionId: SessionId

    /// The sink every update of this translator goes to. The
    /// ``SessionProjector`` sets the record of the tool calls of an open
    /// prompt in front of the history sink.
    var send: SessionUpdateSink

    /// The model reference the session generates with. The log line of a
    /// wait for a place in the model queue names it, so a person who reads
    /// the log learns which model was busy. A model slot switch changes it
    /// at the next prompt.
    var modelName: String

    /// The reader of a settled run's stored output, for the convergence
    /// replace: the settlement carries the complete content, so a client
    /// that missed a chunk still ends correct. The default finds no run.
    var shellSnapshot: ShellSnapshotProvider = { _ in nil }

    /// The handler of a live elicitation request, or `nil`
    /// when no relay is wired — a synthetic translation. The
    /// ``SessionProjector`` supplies a handler that starts the round trip of
    /// the ``ElicitationRelay`` in its own task, so the translation does not
    /// wait for the user (elicitation-plan task 5).
    var relayElicitation: ElicitationEventHandler?

    /// The SDK tool-call id of each run that Router joined, keyed by the
    /// completion token of the run (tasks ^e1yq4gh and ^9xk3xf4). The session
    /// owns the table, and its ``TerminalStream`` reads the same table, so the
    /// `Terminal` announce of a shell run goes on the same wire id as the run
    /// updates of this translator.
    ///
    /// Router sends the joined id on the `toolInvocation(record, toolCallID:)`
    /// event of the open record, before each other event of the run. The
    /// progress, the display events, the attachment report and the settlement
    /// of a run carry only the completion token, so each one finds its wire id
    /// here (``runCallId(_:)``). The SDK `toolCall` and `toolStatus` events
    /// carry the same SDK id, so the client sees one tool call for each run.
    /// An entry stays after the close record, because the attachment report
    /// and the settlement of a background run come after the close record.
    ///
    /// Known limit: Router joins a record to the first open SDK call that has
    /// the same tool name, because the record does not hold the arguments.
    /// When one round calls one tool two times and the SDK runs the two calls
    /// at the same time, each run can get the id of the other call. The
    /// translator cannot see this, so it sends each run on the id that Router
    /// gave. The client still sees one tool call for each run, but the content
    /// of a run can show on the call that holds the arguments of the other run.
    let runCallJoins: RunCallJoinTable

    // MARK: - The mutable state

    /// The counts of the prompt that the event in translation belongs to.
    /// The ``SessionProjector`` sets it before each event and reads it after:
    /// the tally of the open prompt for an event of that prompt, and a
    /// scratch tally for each other event.
    var tally = PromptTally()

    /// The one agent message id of the current message, made at the
    /// first text delta (a new id starts a new message).
    private var agentMessageId: MessageId?

    /// The one agent thought id of the current reasoning message.
    private var thoughtMessageId: MessageId?

    /// The wire ids of the tool calls that have a title on the client (task
    /// ^w7hzpmq).
    ///
    /// A metadata event of a tool always sends its title, because the tool
    /// asked for it. The `op` of a run and the tool name of the SDK `toolCall`
    /// are default titles: only the first update that gives the call a title
    /// sends one (``titlePatch(for:defaultTitle:toolTitle:)``). Each later
    /// update omits `title`, so the progress, the attachment report and the
    /// settlement of a run do not write over the title of the tool. The SDK
    /// `toolCall` event comes after the SDK call returned, thus after the run
    /// events of the call, and it also omits `title` when the call has one.
    private var titledToolCallIds: Set<String> = []

    /// The wire ids of the tool calls whose run settlement sent the terminal
    /// status (task ^531r4r0).
    ///
    /// The SDK `toolCall` event comes after the SDK call returned, thus after
    /// the settlement of an inline run. Router derives the status of the
    /// `toolStatus` events from the transcript, and a call with an output
    /// reads `completed`, also when its run failed or was cancelled. The
    /// status of the settlement is the true end of the run. Thus after the
    /// settlement, the SDK updates of the call send no `status`
    /// (``sdkStatusPatch(for:status:)``). The settlement finds the wire id
    /// through ``runCallJoins``. A call that no run settled keeps the SDK
    /// statuses.
    private var settledToolCallIds: Set<String> = []

    /// Whether a text delta arrived since the last end of an answer. An
    /// answer that streamed its text does not send its reply again. An
    /// answer that mail starts can give its reply whole and stream no text
    /// delta, so its reply is then the only carrier of its text (task
    /// ^64pav2a).
    private var streamedTextInAnswer = false

    /// The metadata of a record about one run: the session id
    /// and the completion token of the run, under the tool-call id key. The
    /// Router records of the run use the same token.
    ///
    /// - Parameter runId: The correlation id of the run, which is its
    ///   completion token.
    /// - Returns: The metadata.
    private func runMetadata(_ runId: String) -> Logger.Metadata {
        var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.toolCallId] = "\(runId)"
        return metadata
    }

    /// The metadata of a record about one Router event that the translator
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

    /// Records the files that the change sets of `report` name, for the
    /// record of a cut prompt (task ^dcmsxpw). A move or a copy adds its
    /// source and its destination.
    ///
    /// - Parameter report: The report of the attachments of one call.
    private mutating func recordChangedFiles(in report: ToolCallReport) {
        for change in Self.fileChanges(in: report.attachments) {
            tally.changedFilePaths.insert(change.path)
            if let destination = change.destinationPath {
                tally.changedFilePaths.insert(destination)
            }
        }
    }

    // MARK: - The SessionEvent cases

    /// Projects one event to the wire.
    ///
    /// The switch lists every case and keeps an `@unknown default`
    /// arm: `SessionEvent` has no library evolution, and its own
    /// contract tells a consumer to absorb a new case rather than
    /// break.
    ///
    /// A prompt can make more than one Router submission: a tool call, a
    /// retry after an overflow, or a continuation starts a new one. Each
    /// `submissionEnded` adds its usage to ``tally``. The state updates of a
    /// prompt are the work of the ``SessionProjector``.
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: SessionEvent) async {
        switch event {
        case .textDelta(let text):
            tally.sawOutput = true
            streamedTextInAnswer = true
            let messageId = agentMessageId ?? Self.makeMessageId()
            agentMessageId = messageId
            await send(
                .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .textReset:
            // "Discard the text collected so far" cannot ride as a
            // chunk: send the whole-message form, which replaces
            // everything accumulated. With no message yet there
            // is nothing to discard.
            guard let messageId = agentMessageId else { return }
            await send(.agentMessage(AgentMessage(messageId: messageId, content: .value([]))))
        case .reasoningDelta(let text):
            tally.sawOutput = true
            let messageId = thoughtMessageId ?? Self.makeMessageId()
            thoughtMessageId = messageId
            await send(
                .agentThoughtChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .toolCall(let id, let name, let argumentsJSON):
            tally.sawOutput = true
            await projectToolCall(id: id, name: name, argumentsJSON: argumentsJSON)
        case .toolStatus(let id, let status, let summary, let output):
            tally.sawOutput = true
            await projectToolStatus(id: id, status: status, summary: summary, output: output)
        case .toolInvocation(let record, let toolCallID):
            tally.sawOutput = true
            // A correlation record only, never a wire message. It joins the
            // completion token of the run to the SDK tool-call id, and each
            // later update of the run goes on that id. A record that no SDK
            // call joined keeps the completion token as its wire id. The
            // first write for a run is final, and the close record carries
            // the id of its open record.
            runCallJoins.record(toolCallID: toolCallID, for: record.correlationID)
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The prompt recorded a tool invocation.", metadata: runMetadata(record.correlationID))
        case .entryRecorded(let id, let kind):
            closeMessage(recordedEntryId: id, kind: kind)
        case .compactionStarted(let start):
            await compactionReporter.reportStart(start)
        case .compaction(let result):
            await compactionReporter.reportCompaction(result)
        case .compactionFailed(let failure):
            await compactionReporter.reportFailure(failure)
        case .discoveryPrimingFailed(let failure):
            var metadata = ACPAgentTelemetry.errorMetadata(failure, sessionId: sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.errorCase] = "\(ACPAgentTelemetry.caseName(of: failure))"
            ACPAgentTelemetry.logger(.promptExecution).error(
                "The discovery priming failed. The answer generates with no seed.", metadata: metadata)
        case .generationStalled(let stall):
            // A report, not a bound: the generation continues.
            var metadata = ACPAgentTelemetry.modelMetadata(sessionId: sessionId, modelRef: modelName)
            metadata[ACPAgentTelemetry.LogMetadataKey.routerReport] = "\(stall.description)"
            ACPAgentTelemetry.logger(.promptExecution).notice(
                "A generation made no progress for one stall interval.", metadata: metadata)
        case .runSettled(let operationEvent):
            tally.sawOutput = true
            // A settled run that has no join entry gets "no join", so a
            // terminal announce that waits for the run stops waiting.
            runCallJoins.seal(operationEvent.correlationID)
            await projectSettlement(of: operationEvent)
        case .runProgress(let operationEvent):
            // A report of a run, not output of the model: it does not set
            // `sawOutput`, so it changes neither the `_no_output` stop
            // reason nor the stall guard of the prompt (task ^jwx92y8).
            await projectProgress(of: operationEvent)
        case .runMessage:
            // A message of a background run that the session injects for
            // the model, with no ACP counterpart: the answer that this
            // message starts carries the result to the client.
            reportUnsentEvent(event)
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
            tally.sawOutput = true
            recordChangedFiles(in: report)
            await projectToolCallReport(report)
        case .toolDisplay(let display):
            tally.sawOutput = true
            await projectDisplay(display)
        case .elicitationRequested(let operationEvent):
            // The handler starts the round trip in its own task: the
            // asking tool waits for the answer, and the other events of
            // the session still go out (elicitation-plan task 5).
            guard let relayElicitation else {
                ACPAgentTelemetry.logger(.promptExecution).notice(
                    "A run requested an elicitation, but no relay is wired. The agent only logs the request.",
                    metadata: runMetadata(operationEvent.correlationID))
                return
            }
            tally.sawOutput = true
            await relayElicitation(operationEvent)
        case .submissionEnded(let end):
            // One event per submission, not per prompt: sum, and never
            // send `idle` from here.
            tally.record(end)
        case .generationCall(let call):
            // The usage of one generation call alone. The
            // `submissionEnded` sum above already counts these tokens,
            // so no wire update goes out. The call gives the fills and the
            // window of the context (task ^1x5ksdv).
            tally.contextUsage.record(call)
        case .submissionQueued:
            // A log line, not a wire message.
            reportQueueWait()
        case .repetitionStopped(let stop):
            // A log line, not a wire message: the stop reason of
            // the prompt carries the end, and the next submission of a
            // recovery carries the text.
            tally.countRouterStop(recovery: stop.recovery)
            reportRouterStop(
                stop, message: "Router stopped a generate call, because the call repeated itself.")
        case .reasoningStopped(let stop):
            // A log line, not a wire message, as for a repetition
            // stop (task ^7fsfw7y).
            tally.countRouterStop(recovery: stop.recovery)
            tally.lastReasoningStop = stop
            reportRouterStop(
                stop, message: "Router stopped a pass, because the pass reasoned and did not act.")
        case .answered(let answer):
            await projectReply(of: answer)
        case .answerFailed, .mailDeliveryPaused:
            // Router bookkeeping with no ACP counterpart: the projector
            // reads the end of an answer for the stop reason.
            streamedTextInAnswer = false
            reportUnsentEvent(event)
        case .submissionStarted, .mailDelivered, .cancelled, .signalDone, .lost:
            // Mail and signal bookkeeping with no ACP counterpart.
            reportUnsentEvent(event)
        @unknown default:
            // `SessionEvent` requires a default arm by its own
            // contract: a new case degrades to a log line, never to a
            // broken stream.
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The translator does not know a Router event.", metadata: eventMetadata(event))
        }
    }

    /// Sends the reply of `answer` as one agent message when the reply is
    /// the only carrier of the answer text (task ^64pav2a). An answer that
    /// streamed its text, and an empty reply, send nothing. The usage of `answer` is the total of the chain, and
    /// the `submissionEnded` sum already counts it, so the translator does
    /// not add it again.
    ///
    /// - Parameter answer: The final answer of one chain of submissions.
    private mutating func projectReply(of answer: SessionAnswer) async {
        let streamedText = streamedTextInAnswer
        streamedTextInAnswer = false
        guard !streamedText, !answer.reply.isEmpty else {
            reportUnsentEvent(.answered(answer))
            return
        }
        tally.sawOutput = true
        await send(
            .agentMessageChunk(
                ContentChunk(content: .text(TextContent(text: answer.reply)), messageId: Self.makeMessageId())))
    }

    /// Records a Router event that the translator does not send. The record
    /// is a `debug`, because the event is bookkeeping with no ACP
    /// counterpart.
    ///
    /// - Parameter event: The event.
    private func reportUnsentEvent(_ event: SessionEvent) {
        ACPAgentTelemetry.logger(.promptExecution).debug(
            "The translator sends nothing for a Router event.", metadata: eventMetadata(event))
    }

    /// Records that a submission of the prompt waits for a place in the
    /// model queue, because the model runs a submission of another session.
    ///
    /// The wait has no wire message. The wait is not a
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
    /// The stop has no wire message. The record is a `notice`
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

    // MARK: - The tool-call upsert

    /// Sends the creating `tool_call_update`: v2 has no create
    /// variant, so the first update with an unseen `toolCallId` is the
    /// creation. It carries the tool name as the `name` for a program (ACP
    /// schema-v2.0.0-alpha.7). It carries the tool name as the title for a
    /// person only when the call has no title yet
    /// (``titlePatch(for:defaultTitle:toolTitle:)``): the run events of the
    /// call come first, and a title from a metadata event of the tool stays.
    /// It says `in_progress` — the call already runs, and `pending` is the
    /// default a creating update must not leave in place. When a run
    /// settlement already sent the terminal status of the call, it sends no
    /// status (``sdkStatusPatch(for:status:)``).
    ///
    /// - Parameters:
    ///   - id: Apple's `Transcript.ToolCall.id`, passed through
    ///     unchanged.
    ///   - name: The tool name; the creation's name and default title.
    ///   - argumentsJSON: The call's arguments, the structured
    ///     per-call record `rawInput` parses from.
    private mutating func projectToolCall(id: String, name: String, argumentsJSON: String) async {
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
        let toolCallId = ToolCallId(rawValue: id)
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: toolCallId,
                    name: .value(name),
                    rawInput: rawInput,
                    status: sdkStatusPatch(for: toolCallId, status: .inProgress),
                    title: titlePatch(for: toolCallId, defaultTitle: name))))
    }

    /// Sends the lifecycle `tool_call_update` of one SDK tool call:
    /// the status maps from Router's three-case vocabulary, and the
    /// answering output segments replace the call's content.
    ///
    /// When a run settlement already sent the terminal status of the call,
    /// the update sends no status (``sdkStatusPatch(for:status:)``). An
    /// update that then carries no content and no raw output tells the
    /// client nothing, so it does not go.
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
        let toolCallId = ToolCallId(rawValue: id)
        let update = ToolCallUpdate(
            toolCallId: toolCallId,
            content: Self.contentPatch(summary: summary, output: output),
            rawOutput: Self.rawOutputPatch(from: output),
            status: sdkStatusPatch(for: toolCallId, status: Self.wireStatus(for: status)))
        guard update.status != .unchanged || update.content != .unchanged || update.rawOutput != .unchanged
        else {
            return
        }
        await send(.toolCallUpdate(update))
    }

    /// The status patch of one SDK update of a tool call: `status`, or no
    /// change when a run settlement already sent the terminal status of the
    /// call (``settledToolCallIds``). Thus no SDK update writes over the
    /// terminal status of a settled run, and none sends `in_progress` for it.
    ///
    /// - Parameters:
    ///   - toolCallId: The wire id of the call.
    ///   - status: The status that the SDK event gives.
    /// - Returns: The status patch.
    private func sdkStatusPatch(
        for toolCallId: ToolCallId, status: FoundationModelsACP.ToolCallStatus
    ) -> PatchField<FoundationModelsACP.ToolCallStatus> {
        settledToolCallIds.contains(toolCallId.rawValue) ? .unchanged : .value(status)
    }

    /// Closes the message the recorded entry ended: the
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
                "The translator sends nothing for a recorded entry of an unmapped kind.", metadata: metadata)
        }
    }

    // MARK: - Compaction

    /// The reporter of the compactions of the session
    /// (``CompactionReporter``), automatic or requested. Router reports each
    /// compaction with `compactionStarted`, then `compaction` or
    /// `compactionFailed`, with the same id: the `SignalID` of the
    /// compaction. The reporter sends the `in_progress` update, then
    /// the terminal update, keyed by that id, and the `usage_update` of a
    /// completed compaction. It sends them through ``send``, the history
    /// sink, thus the retained history keeps the final status. No message
    /// update clears or rewrites anything: a compaction changes only the
    /// model context.
    private var compactionReporter: CompactionReporter {
        CompactionReporter(send: send)
    }

    // MARK: - The wire call of a run

    /// The wire id of the tool call of a run. Each update and each content
    /// chunk of a run keys on it.
    ///
    /// It is the SDK tool-call id that Router joined to the run
    /// (``runCallJoins``), so the run events and the SDK `toolCall` and
    /// `toolStatus` events update one wire call. When no SDK call joined the
    /// run, it is the `correlationID` of the run, which is its completion
    /// token.
    ///
    /// - Parameter correlationID: The correlation token of the run.
    /// - Returns: The tool call id.
    private func runCallId(_ correlationID: String) -> ToolCallId {
        runCallJoins.toolCallId(for: correlationID)
    }

    /// Builds one `tool_call_update` for the wire call of a run. This is the
    /// one place that gives the wire shape of the run updates: the progress
    /// text, the attachment report, the settlement and the display events of
    /// a tool all use it.
    ///
    /// The update keys on the wire id of the run (``runCallId(_:)``). The
    /// tool of the run rides as the `name`, because each of these updates can
    /// be the creation of the wire call. The title of the tool always rides
    /// as the title. The `op` rides as the title only when the call has no
    /// title yet (``titlePatch(for:defaultTitle:toolTitle:)``), so a later
    /// update does not write the `op` over the title of the tool. Each other
    /// field stays `.unchanged` unless the caller sets it.
    ///
    /// - Parameters:
    ///   - correlationID: The correlation token of the run.
    ///   - tool: The tool of the run, sent as the `name`.
    ///   - op: The op of the run, the default title of the call.
    ///   - toolTitle: The title that a metadata event of the tool gives the
    ///     call, or `nil` when the update gives no such title.
    ///   - content: The content patch of the call.
    ///   - kind: The kind patch of the call.
    ///   - locations: The locations patch of the call.
    ///   - rawInput: The raw input patch of the call.
    ///   - rawOutput: The raw output patch of the call.
    ///   - status: The status patch of the call.
    /// - Returns: The `tool_call_update` session update.
    private mutating func runCallUpdate(
        correlationID: String,
        tool: String,
        op: String,
        toolTitle: String? = nil,
        content: PatchField<[ToolCallContent]> = .unchanged,
        kind: PatchField<FoundationModelsACP.ToolKind> = .unchanged,
        locations: PatchField<[ToolCallLocation]> = .unchanged,
        rawInput: PatchField<FoundationModelsACP.JSONValue> = .unchanged,
        rawOutput: PatchField<FoundationModelsACP.JSONValue> = .unchanged,
        status: PatchField<FoundationModelsACP.ToolCallStatus> = .unchanged
    ) -> SessionUpdate {
        let toolCallId = runCallId(correlationID)
        return .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: toolCallId,
                content: content,
                kind: kind,
                locations: locations,
                name: .value(tool),
                rawInput: rawInput,
                rawOutput: rawOutput,
                status: status,
                title: titlePatch(for: toolCallId, defaultTitle: op, toolTitle: toolTitle)))
    }

    /// The title patch of one update of a tool call, and the record that the
    /// call has a title (``titledToolCallIds``).
    ///
    /// The title of the tool always rides, because the tool asked for it. The
    /// default title rides only on the first update that gives the call a
    /// title. A later update omits `title`, so the client keeps the title
    /// that it has.
    ///
    /// - Parameters:
    ///   - toolCallId: The wire id of the call.
    ///   - defaultTitle: The `op` of a run, or the tool name of an SDK call.
    ///   - toolTitle: The title that a metadata event of the tool gives the
    ///     call, or `nil` when the update gives no such title.
    /// - Returns: The title patch.
    private mutating func titlePatch(
        for toolCallId: ToolCallId, defaultTitle: String, toolTitle: String? = nil
    ) -> PatchField<String> {
        let isFirstTitle = titledToolCallIds.insert(toolCallId.rawValue).inserted
        if let toolTitle {
            return .value(toolTitle)
        }
        return isFirstTitle ? .value(defaultTitle) : .unchanged
    }

    // MARK: - The settlement

    /// Sends the terminal `tool_call_update` of a settled run. The tool rides
    /// as the `name`, and the `op` rides as the title when the call has no
    /// title yet, because a settlement can be the creation of the wire call
    /// of a run. A settlement does not write the `op` over a title that the
    /// call already has.
    ///
    /// The envelope is read defensively: the "outcome is non-nil if
    /// and only if the kind is `.completed`" rule is a doc comment
    /// upstream, not a type guarantee. A non-terminal event settles
    /// nothing — an outcome riding on it is ignored — and a terminal
    /// event with no outcome reports the unknown status.
    ///
    /// A run the shell store knows replaces the call's content with
    /// its `Terminal` reference and the capture's honesty notes:
    /// the bytes ride the terminal stream, never coerced to
    /// text, and a reconnecting client takes the
    /// `TerminalUpdate.output` replacement instead.
    ///
    /// - Parameter operationEvent: The run's operation event.
    private mutating func projectSettlement(of operationEvent: OperationEvent) async {
        guard operationEvent.kind == .completed else {
            if operationEvent.outcome != nil {
                ACPAgentTelemetry.logger(.promptExecution).warning(
                    "A run carried an outcome on an event that is not terminal. The translator ignores the outcome.",
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
        settledToolCallIds.insert(runCallId(operationEvent.correlationID).rawValue)
        await send(
            runCallUpdate(
                correlationID: operationEvent.correlationID,
                tool: operationEvent.tool,
                op: operationEvent.op,
                content: items.isEmpty ? .unchanged : .value(items),
                status: .value(status)))
    }

    // MARK: - The progress of a run

    /// Sends the progress that a run reported through
    /// `ToolContext.progress(_:plan:)` while it continues (task ^jwx92y8).
    ///
    /// A progress event with a plan sends one `plan_update` that holds the
    /// full list of the plan (``planUpdate(for:)``). The `detail` of that
    /// event is the text line for the model, so it does not go to the client.
    ///
    /// A progress event with no plan sends its `detail` as the content of
    /// the tool call of the run. The update keys on the wire id of the run
    /// (``runCallId(_:)``), as the attachment report and the settlement do.
    /// The tool of the event never selects the call: in code
    /// mode, a `tools.*` call posts under the tool name and the
    /// `correlationID` of the outer run. The tool rides as the `name`, and the
    /// `op` rides as the title when the call has no title yet, because this
    /// update can be the creation of the wire call. The update says
    /// `in_progress`, because the run is still open, and the settlement of
    /// the run later gives its terminal status.
    ///
    /// - Parameter operationEvent: The `.progress` event of the run.
    private mutating func projectProgress(of operationEvent: OperationEvent) async {
        if let plan = operationEvent.plan {
            await send(.planUpdate(Self.planUpdate(for: plan)))
            return
        }
        await send(
            runCallUpdate(
                correlationID: operationEvent.correlationID,
                tool: operationEvent.tool,
                op: operationEvent.op,
                content: .value([Self.textItem(operationEvent.detail)]),
                status: .value(.inProgress)))
    }

    /// Maps one plan of a run to the wire: one `plan_update` that holds the
    /// full list of entries, keyed by the id of the plan. The client replaces
    /// the plan that has the same `planId` with each update:
    /// `plan_update` replaces, and it does not patch.
    ///
    /// The priority and the status of each entry map by their raw values,
    /// which Extras gives as the ACP wire values. Thus the mapping is total:
    /// a value that this wire revision does not know stays as the `.unknown`
    /// case and is not lost.
    ///
    /// - Parameter plan: The plan that the run reported.
    /// - Returns: The wire update.
    static func planUpdate(for plan: PlanSnapshot) -> PlanUpdate {
        let entries = plan.entries.map { entry in
            PlanEntry(
                content: entry.content,
                priority: PlanEntryPriority(wireValue: entry.priority.rawValue),
                status: PlanEntryStatus(wireValue: entry.status.rawValue))
        }
        return PlanUpdate(plan: .items(PlanItems(entries: entries, planId: PlanId(rawValue: plan.id))))
    }

    // MARK: - The display events of a tool

    /// Sends one display event of a tool as the v2 prompt-lifecycle shape.
    ///
    /// Each shape keys on the wire id of the run (``runCallId(_:)``), as the
    /// progress, the attachment report and the settlement do:
    ///
    /// - A content chunk is one `tool_call_content_chunk`: the client adds
    ///   the item after the earlier items of the call.
    /// - A content replace is a `tool_call_update` that replaces the content
    ///   of the call with all the parts, in order.
    /// - A metadata event is a `tool_call_update` patch of `title`, `kind`,
    ///   `locations` and `rawInput`. A `nil` field means "no change", so the
    ///   patch omits it: a `null` on the wire clears the field. The title of
    ///   the tool stays on the client: no later update of the call sends the
    ///   `op` or the tool name over it.
    ///
    /// The translator sends each event at once, in the order Router gives.
    /// The settlement of the run comes after the display events of the run,
    /// so its content replace stays the last update of the call. This holds
    /// for a background run that settles in its settle period too: such a
    /// run withdraws its staged events, but not its display events.
    ///
    /// - Parameter display: The display event of the tool.
    private mutating func projectDisplay(_ display: ToolDisplayEvent) async {
        switch display.kind {
        case .contentChunk(let content):
            await send(
                .toolCallContentChunk(
                    ToolCallContentChunk(
                        content: displayItem(for: content, run: display.correlationID),
                        toolCallId: runCallId(display.correlationID))))
        case .contentReplace(let contents):
            await send(
                runCallUpdate(
                    correlationID: display.correlationID,
                    tool: display.tool,
                    op: display.op,
                    content: .value(contents.map { displayItem(for: $0, run: display.correlationID) })))
        case .metadata(let title, let kind, let locations, let rawInput):
            await send(
                runCallUpdate(
                    correlationID: display.correlationID,
                    tool: display.tool,
                    op: display.op,
                    toolTitle: title,
                    kind: kind.map { .value(FoundationModelsACP.ToolKind(wireValue: $0.rawValue)) } ?? .unchanged,
                    locations: locationsPatch(for: locations, run: display.correlationID),
                    rawInput: rawInputPatch(from: rawInput, run: display.correlationID)))
        }
    }

    /// Maps one display part of a tool to one tool-call content item.
    ///
    /// Text rides as text. A JSON document rides as its text, because the
    /// tool owns its shape and this package does not read it. A file change
    /// rides as a `diff` item with a ``WholeFilePatch``. The wire requires an
    /// absolute path in a diff, so a change at another path rides as a text
    /// item that holds the same patch: the client still shows the change,
    /// and the translator never invents a path.
    ///
    /// - Parameters:
    ///   - content: The display part.
    ///   - runId: The correlation id of the run, for the log record.
    /// - Returns: The content item.
    private func displayItem(for content: ToolDisplayContent, run runId: String) -> ToolCallContent {
        switch content {
        case .text(let text), .json(let text):
            return Self.textItem(text)
        case .diff(let path, let oldText, let newText):
            let patch = WholeFilePatch.text(path: path, oldText: oldText, newText: newText)
            guard let absolutePath = AbsolutePath(absolute: path) else {
                ACPAgentTelemetry.logger(.promptExecution).warning(
                    "A tool showed a file change at a path that is not absolute. The change rides as text.",
                    metadata: runMetadata(runId))
                return Self.textItem(patch)
            }
            let change = Self.diffChange(for: oldText == nil ? .add(path: absolutePath) : .modify(path: absolutePath))
            return .diff(
                Diff(changes: [change], patch: patch.isEmpty ? nil : DiffPatch(format: .gitPatch, text: patch)))
        }
    }

    /// The `locations` patch of a metadata event.
    ///
    /// `nil` leaves the locations unchanged. A location whose path is not
    /// absolute cannot ride on the wire, so the patch drops it. When the
    /// event gave locations and the wire can carry none of them, the patch
    /// leaves the locations unchanged: an empty array would clear them. An
    /// empty list from the tool clears them, because the tool asked for it.
    ///
    /// - Parameters:
    ///   - locations: The locations of the event, or `nil`.
    ///   - runId: The correlation id of the run, for the log record.
    /// - Returns: The locations patch.
    private func locationsPatch(
        for locations: [ToolDisplayEvent.Location]?, run runId: String
    ) -> PatchField<[ToolCallLocation]> {
        guard let locations else { return .unchanged }
        let carried = locations.compactMap { location in
            AbsolutePath(absolute: location.path).map { ToolCallLocation(path: $0, line: location.line) }
        }
        guard carried.count == locations.count else {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A tool named a location that is not absolute. The location is not on the wire.",
                metadata: runMetadata(runId))
            return carried.isEmpty ? .unchanged : .value(carried)
        }
        return .value(carried)
    }

    /// The `rawInput` patch of a metadata event: the parsed JSON of the
    /// input. `nil` leaves the raw input unchanged, and so does a text that
    /// is not JSON: the translator never invents a value from it.
    ///
    /// - Parameters:
    ///   - rawInput: The input of the call as a JSON text, or `nil`.
    ///   - runId: The correlation id of the run, for the log record.
    /// - Returns: The raw input patch.
    private func rawInputPatch(
        from rawInput: String?, run runId: String
    ) -> PatchField<FoundationModelsACP.JSONValue> {
        guard let rawInput else { return .unchanged }
        guard let value = Self.jsonValue(from: rawInput) else {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "The raw input of a tool did not parse as JSON. The raw input is not on the wire.",
                metadata: runMetadata(runId))
            return .unchanged
        }
        return .value(value)
    }

    // MARK: - The attachment report

    /// Sends the attachment `tool_call_update` of one closed call: the
    /// update keys on the wire id of the run (``runCallId(_:)``), carries
    /// each attached document as one content item in call order, and puts the parsed
    /// documents in `rawOutput`. The tool rides as the `name`, and the `op`
    /// rides as the title when the call has no title yet, because this update
    /// can be the creation of the wire call.
    ///
    /// The update claims no status: the report records what the call
    /// attached, not how the call ended, and the terminal claim
    /// belongs to `toolStatus` and `runSettled`.
    ///
    /// It fills `locations` from the one attachment shape that carries
    /// a path contract: the `FileChangeSet` envelope a mutating files
    /// verb attaches (`schemaName` ``FoundationModelsMultitool/FileChangeSet/operationEventDetailKey``).
    /// The paths come from the structured record, never from a rendered
    /// string, and replace the array as a whole. Every
    /// other attachment is an opaque document with no path contract, so
    /// a report of such documents alone leaves `locations` unchanged
    /// rather than erasing it.
    ///
    /// - Parameter report: The report of the call's attachments.
    private mutating func projectToolCallReport(_ report: ToolCallReport) async {
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
            runCallUpdate(
                correlationID: report.correlationID,
                tool: report.tool,
                op: report.op,
                content: .value(documents.map(Self.textItem)),
                locations: locations.isEmpty ? .unchanged : .value(locations),
                rawOutput: Self.rawOutputPatch(fromDocuments: documents)))
    }

    // MARK: - The status functions

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
    /// status alone says everything.
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

    /// Puts `raw` under the ACP extension rule: a custom wire value
    /// starts with `_`, and a value that already does stays as it is.
    ///
    /// - Parameter raw: The raw outcome value.
    /// - Returns: The extension wire value.
    private static func extensionValue(_ raw: String) -> String {
        raw.hasPrefix(extensionValuePrefix) ? raw : extensionValuePrefix + raw
    }

    // MARK: - The file-change path mappings

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
    /// with no destination. The translator reports what the record
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

    /// Makes one agent-owned message id: a fresh ULID,
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
    /// structured segments — never from a rendered string.
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

    /// The settlement content of a stored run: the `Terminal`
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
