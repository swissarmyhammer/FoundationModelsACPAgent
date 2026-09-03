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
/// One value projects one turn: `project(_:)` maps each of the
/// fifteen `SessionEvent` cases, and `reportUsage()` closes the turn
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

    /// The handler of a live elicitation request (plan.md §16), or `nil`
    /// when no relay is wired — a synthetic projection drive. The
    /// production wiring supplies ``ElicitationRelay/relay(_:on:turnState:)``
    /// bound to the turn's session and owner.
    var relayElicitation: ElicitationEventHandler?

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

    /// Whether the turn produced observable output: a text delta, a
    /// reasoning delta, a tool call or status, an invocation record,
    /// an attachment report, a relayed elicitation, or a run
    /// settlement (task ^pez780d).
    private var sawOutput = false

    /// Whether at least one `turnEnded` usage report arrived
    /// (task ^pez780d).
    private var sawUsageReport = false

    /// Whether the turn generated nothing: no observable output, while
    /// at least one `turnEnded` arrived and the summed output tokens
    /// are zero. `PromptTurn.drive` reads it to report the honest
    /// `_no_output` stop reason instead of a bare `end_turn`
    /// (plan.md §8.2's `_` rule; task ^pez780d).
    var generatedNothing: Bool {
        !sawOutput && sawUsageReport && tokensOut == 0
    }

    // MARK: - The fifteen cases (§8.4)

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
            sawOutput = true
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
            sawOutput = true
            await projectSettlement(of: operationEvent)
        case .toolCallReport(let report):
            // The "at least one attachment" rule is a doc comment
            // upstream, not a type guarantee: an empty report sends
            // nothing, because an empty content replace would erase
            // the call's content.
            guard !report.attachments.isEmpty else {
                turnLogger.warning(
                    "session \(sessionIdValue, privacy: .public): run \(report.correlationID, privacy: .public) reported no attachments; nothing goes to the wire"
                )
                return
            }
            sawOutput = true
            await projectToolCallReport(report)
        case .elicitationRequested(let operationEvent):
            // The relay runs the round trip inline (plan.md §16): the
            // asking tool is suspended in Router's mailbox until the
            // answer is delivered, so holding this drive loop holds
            // nothing the turn could otherwise do.
            guard let relayElicitation else {
                turnLogger.notice(
                    "session \(sessionIdValue, privacy: .public): run \(operationEvent.correlationID, privacy: .public) requested an elicitation, but no relay is wired; the request is only reported"
                )
                return
            }
            sawOutput = true
            await relayElicitation(operationEvent)
        case .turnEnded(let usage):
            // One event per inner generate call, not per turn: sum,
            // and never send `idle` from here (§8.1).
            sawUsageReport = true
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

    // MARK: - The attachment report (§8.4, §11.6)

    /// Sends the attachment `tool_call_update` of one closed call: the
    /// update keys on the run's `correlationID` — its
    /// `completionToken`, its `toolCallId` — carries each attached
    /// document as one content item in call order, and puts the parsed
    /// documents in `rawOutput`. The `op` rides as the title, because
    /// this update can be the creation of the wire call.
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
            turnLogger.warning(
                "session \(sessionId.rawValue, privacy: .public): run \(report.correlationID, privacy: .public) recorded a file change the wire cannot carry; it rides no location"
            )
        }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: report.correlationID),
                    content: .value(documents.map(Self.textItem)),
                    locations: locations.isEmpty ? .unchanged : .value(locations),
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
        guard let path = AbsolutePath(rawValue: change.path) else { return nil }
        let destination = change.destinationPath.flatMap(AbsolutePath.init(rawValue:))
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
