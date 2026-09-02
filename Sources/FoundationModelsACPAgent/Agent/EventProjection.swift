import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter

/// Reads the stored raw output of a settled run, keyed by the run's
/// `commandID` — which is its `completionToken` and its `toolCallId`
/// (plan.md §11.8). The production reader is the host-owned
/// `ShellOutputChunkStream.snapshot(for:)`; a turn with no shell mount
/// reads nothing.
typealias ShellSnapshotProvider = @Sendable (_ commandID: String) -> ShellOutputSnapshot?

/// One file change, in this package's own vocabulary (plan.md §11.6).
///
/// Multitool keeps its `FileChange` internal, so the projection owns
/// this mirror. A move and a copy carry both endpoints, which is what
/// makes the §11.6 path-direction mapping total: ACP's `path` is
/// post-operation, so the source becomes `oldPath` and the destination
/// becomes `path` for those two kinds only.
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
/// One value projects one turn: `project(_:)` maps each of the
/// thirteen `SessionEvent` cases, and `reportUsage()` closes the turn
/// with its one summed `usage_update`. The live shell bytes have no
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

    // MARK: - The turn's wiring

    /// The id of the session this projection reports for, in the logs.
    let sessionId: SessionId

    /// The turn-state owner: `turnStarted` maps through it (§8.2).
    let turnState: TurnStateOwner

    /// The sink every update of this projection goes to.
    let send: SessionUpdateSink

    /// The reader of a settled run's stored output, for the §11.6
    /// convergence replace. The default finds no run.
    var shellSnapshot: ShellSnapshotProvider = { _ in nil }

    // MARK: - The turn's mutable state

    /// The one agent message id of the current message, made at the
    /// first text delta (§8.3: a new id starts a new message).
    private var agentMessageId: MessageId?

    /// The one agent thought id of the current reasoning message.
    private var thoughtMessageId: MessageId?

    /// The prompt tokens summed across every `turnEnded` (§8.1).
    private var tokensIn = 0

    /// The completion tokens summed across every `turnEnded`.
    private var tokensOut = 0

    /// The newest context fill. `nan` means "no stamp": send no meter
    /// for the turn (§8.4).
    private var contextFill = Double.nan

    // MARK: - The thirteen cases (§8.4)

    /// Projects one event to the wire.
    ///
    /// The switch lists every case and keeps an `@unknown default`
    /// arm: `SessionEvent` has no library evolution, and its own
    /// contract tells a consumer to absorb a new case rather than
    /// break.
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: SessionEvent) async {
        // A copy for the log lines: the logger's message is an escaping
        // autoclosure, which must not capture the mutating `self`.
        let sessionIdValue = sessionId.rawValue
        switch event {
        case .turnStarted:
            await turnState.turnDidStart()
        case .textDelta(let text):
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
            let messageId = thoughtMessageId ?? Self.makeMessageId()
            thoughtMessageId = messageId
            await send(
                .agentThoughtChunk(
                    ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
        case .toolCall(let id, let name, let argumentsJSON):
            await projectToolCall(id: id, name: name, argumentsJSON: argumentsJSON)
        case .toolStatus(let id, let status, let summary, let output):
            await projectToolStatus(id: id, status: status, summary: summary, output: output)
        case .toolInvocation(let record):
            // A correlation record only, never a wire message: its
            // `correlationID` is the run's completion token, a
            // different identity space from `Transcript.ToolCall.id`.
            turnLogger.debug(
                "session \(sessionIdValue, privacy: .public): tool invocation record for run \(record.correlationID, privacy: .public)"
            )
        case .entryRecorded(let id, let kind):
            closeMessage(recordedEntryId: id, kind: kind)
        case .compaction(let result):
            await projectCompaction(result)
        case .discoveryPrimingFailed(let failure):
            turnLogger.error(
                "session \(sessionIdValue, privacy: .public): discovery priming failed: \(String(describing: failure), privacy: .public)"
            )
        case .generationStalled(let stall):
            // A report, not a bound (§8.4): the generation continues.
            turnLogger.notice(
                "session \(sessionIdValue, privacy: .public): \(stall.description, privacy: .public)"
            )
        case .runSettled(let operationEvent):
            await projectSettlement(of: operationEvent)
        case .turnEnded(let usage):
            // One event per inner generate call, not per turn: sum,
            // and never send `idle` from here (§8.1).
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
        @unknown default:
            // `SessionEvent` requires a default arm by its own
            // contract: a new case degrades to a log line, never to a
            // broken stream.
            turnLogger.debug(
                "session \(sessionIdValue, privacy: .public): unprojected event \(String(describing: event), privacy: .public)"
            )
        }
    }

    /// Sends the one `usage_update` of the turn, from the summed
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
    /// creation. It carries the title and says `in_progress` — the
    /// call already runs, and `pending` is the default a creating
    /// update must not leave in place.
    ///
    /// - Parameters:
    ///   - id: Apple's `Transcript.ToolCall.id`, passed through
    ///     unchanged.
    ///   - name: The tool name; the creation's title.
    ///   - argumentsJSON: The call's arguments, the structured
    ///     per-call record `rawInput` parses from.
    private func projectToolCall(id: String, name: String, argumentsJSON: String) async {
        let rawInput: PatchField<FoundationModelsACP.JSONValue>
        if let value = Self.jsonValue(from: argumentsJSON) {
            rawInput = .value(value)
        } else {
            turnLogger.warning(
                "session \(sessionId.rawValue, privacy: .public): tool call \(id, privacy: .public) arguments did not parse as JSON"
            )
            rawInput = .unchanged
        }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: id),
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
        // A copy for the log line: the logger's message is an escaping
        // autoclosure, which must not capture the mutating `self`.
        let sessionIdValue = sessionId.rawValue
        switch kind {
        case .response:
            agentMessageId = nil
        case .reasoning:
            thoughtMessageId = nil
        case .toolCalls:
            break
        @unknown default:
            turnLogger.debug(
                "session \(sessionIdValue, privacy: .public): recorded entry \(recordedEntryId, privacy: .public) of an unmapped kind"
            )
        }
    }

    // MARK: - Compaction (§8.5)

    /// Sends the compaction's one `usage_update`: the meter drops to
    /// the post-fold size. No message update clears or rewrites
    /// anything — the journal only ever appends.
    ///
    /// - Parameter result: The fold's result.
    private func projectCompaction(_ result: CompactionResult) async {
        // The fold's own estimates are the only sizes it carries. The
        // pre-fold estimate stands in for the context size, so the
        // visible effect is the meter dropping to the post-fold size.
        await send(
            .usageUpdate(
                UsageUpdate(
                    size: max(result.tokensBefore, result.tokensAfter),
                    used: result.tokensAfter)))
    }

    // MARK: - The settlement (§8.4, §11.6)

    /// Sends the terminal `tool_call_update` of a settled run.
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
                turnLogger.warning(
                    "session \(sessionId.rawValue, privacy: .public): run \(operationEvent.correlationID, privacy: .public) carried an outcome on a non-terminal event; ignored"
                )
            }
            return
        }
        let status: FoundationModelsACP.ToolCallStatus
        if let outcome = operationEvent.outcome {
            status = Self.wireStatus(for: outcome)
        } else {
            turnLogger.warning(
                "session \(sessionId.rawValue, privacy: .public): run \(operationEvent.correlationID, privacy: .public) completed with no outcome"
            )
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
                    status: .value(status),
                    title: .value(operationEvent.op))))
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

    // MARK: - The diff path directions (§11.6)

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
    /// structured segments — never from a rendered string (§11.6). One
    /// structured segment is the value itself; several become an
    /// array; none leaves the field unchanged.
    ///
    /// - Parameter output: The answering output segments, or `nil`.
    /// - Returns: The raw-output patch.
    private static func rawOutputPatch(from output: [SegmentPayload]?) -> PatchField<FoundationModelsACP.JSONValue> {
        let values = (output ?? []).compactMap { payload -> FoundationModelsACP.JSONValue? in
            guard case .structure(_, _, let contentJSON) = payload else { return nil }
            return jsonValue(from: contentJSON)
        }
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
