import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The event projection (plan.md §8.4–§8.5, §11.6): the one mapping
/// from Router's `SessionEvent` stream to the wire — the tool-call
/// upserts, the terminal status from `OperationOutcome`, the live
/// shell-output chunks, the compaction meter, and the diff path
/// directions.
@Suite struct EventProjectionTests {
    // MARK: - Constants

    /// The SDK tool-call id the scripted tool events carry. It is
    /// Apple's `Transcript.ToolCall.id`, passed through unchanged.
    private static let sdkToolCallId = "call-1"

    /// The tool name of the scripted tool call; the creation's title.
    private static let scriptedToolName = "read_file"

    /// The arguments JSON of the scripted tool call.
    private static let scriptedArgumentsJSON = #"{"path":"notes.txt"}"#

    /// The completion token of the scripted operation run. It is the
    /// run's `correlationID`, its `commandID`, and its `toolCallId`.
    private static let completionToken = "01SCRIPTEDRUNTOKEN00000000"

    /// The estimated transcript size before the scripted fold.
    private static let tokensBeforeFold = 900

    /// The estimated transcript size after the scripted fold.
    private static let tokensAfterFold = 300

    /// The byte count the scripted gap event reports as dropped.
    private static let droppedByteCount = 7

    /// One byte that is not valid UTF-8, for the replacement decode.
    private static let invalidUTF8Byte: UInt8 = 0xFF

    /// The number of notifications the raw wire test waits for: two
    /// tool-call updates and the idle terminator.
    private static let rawWireNotificationCount = 3

    // MARK: - Fixtures

    /// Makes an operation event of the scripted run.
    ///
    /// - Parameters:
    ///   - outcome: How the run ended, or `nil`.
    ///   - kind: The event category; terminal by default.
    /// - Returns: The event.
    private static func makeOperationEvent(
        outcome: OperationOutcome?, kind: OperationEventKind = .completed
    ) -> OperationEvent {
        OperationEvent(
            tool: "shell",
            op: "execute command",
            correlationID: completionToken,
            kind: kind,
            detail: "{}",
            outcome: outcome)
    }

    /// Makes the stored raw output of one stream from `text`.
    ///
    /// - Parameter text: The stored text of the stream.
    /// - Returns: The raw output, complete and not truncated.
    private static func makeRawOutput(text: String) -> ShellRawOutput {
        let bytes = Array(text.utf8)
        return ShellRawOutput(
            bytes: bytes, binaryDetected: false, truncated: false,
            storedByteCount: bytes.count)
    }

    /// Drives one synthetic event stream through a sinked turn.
    ///
    /// - Parameters:
    ///   - events: The events to project, in order.
    ///   - shellSnapshot: The reader of a settled run's stored output.
    /// - Returns: The updates the turn sent, in order.
    private static func drive(
        _ events: [SessionEvent],
        shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil }
    ) async -> [SessionUpdate] {
        let (turn, recorder) = makeSinkedTurn(shellSnapshot: shellSnapshot)
        _ = await turn.drive(events: makeEventStream(events))
        return await recorder.updates
    }

    // MARK: - Readers

    /// The tool-call updates in the sequence, in order.
    private static func toolCallUpdates(in updates: [SessionUpdate]) -> [ToolCallUpdate] {
        updates.compactMap { update in
            if case .toolCallUpdate(let call) = update { return call }
            return nil
        }
    }

    /// The text of every plain-content item in a content patch.
    private static func texts(in content: PatchField<[ToolCallContent]>) -> [String] {
        guard case .value(let items) = content else { return [] }
        return items.compactMap { item in
            if case .content(let wrapped) = item, case .text(let text) = wrapped.content {
                return text.text
            }
            return nil
        }
    }

    /// The message ids of the agent message chunks in the sequence.
    private static func chunkMessageIds(in updates: [SessionUpdate]) -> [MessageId] {
        updates.compactMap { update in
            if case .agentMessageChunk(let chunk) = update { return chunk.messageId }
            return nil
        }
    }

    /// The fields of a JSON object value, or `nil` for another shape.
    private static func objectFields(_ value: FoundationModelsACP.JSONValue?) -> [String: FoundationModelsACP.JSONValue]? {
        guard case .object(let fields) = value ?? .null else { return nil }
        return fields
    }

    /// The string of a JSON string value, or `nil` for another shape.
    private static func stringValue(_ value: FoundationModelsACP.JSONValue?) -> String? {
        guard case .string(let string) = value ?? .null else { return nil }
        return string
    }

    // MARK: - The terminal status function (§8.4)

    /// The `OperationOutcome` to `ToolCallStatus` function is total and
    /// follows the §8.4 table. `lost` maps to `_lost` and never to
    /// `failed`.
    @Test func theOutcomeStatusFunctionMapsEveryCasePerTheTable() {
        #expect(EventProjection.wireStatus(for: .succeeded) == .completed)
        #expect(EventProjection.wireStatus(for: OperationOutcome.failed) == .failed)
        #expect(EventProjection.wireStatus(for: .timedOut) == .failed)
        #expect(EventProjection.wireStatus(for: .stopped) == .cancelled)
        #expect(EventProjection.wireStatus(for: .cancelled) == .cancelled)
        #expect(
            EventProjection.wireStatus(for: .lost)
                == .unknown(EventProjection.lostStatusWireValue))
        #expect(EventProjection.wireStatus(for: .lost) != .failed)
    }

    /// An `other(raw)` outcome passes its raw value through under the
    /// `_` extension rule (§18): an unprefixed value gains the prefix,
    /// and a prefixed value stays as it is.
    @Test func anOtherOutcomePassesThroughUnderTheUnderscoreRule() {
        #expect(EventProjection.wireStatus(for: .other("paused")) == .unknown("_paused"))
        #expect(EventProjection.wireStatus(for: .other("_held")) == .unknown("_held"))
    }

    // MARK: - The tool-call upsert (§11.6)

    /// A scripted tool turn creates the call with a title, an
    /// `in_progress` status and the parsed raw input, keeps the one
    /// `toolCallId` across the updates, and completes it.
    @Test func aScriptedToolTurnCreatesWithTitleThenRunsThenCompletes() async throws {
        let updates = await Self.drive([
            .toolCall(
                id: Self.sdkToolCallId, name: Self.scriptedToolName,
                argumentsJSON: Self.scriptedArgumentsJSON),
            .toolStatus(id: Self.sdkToolCallId, status: .running, summary: nil, output: nil),
            .toolStatus(
                id: Self.sdkToolCallId, status: .completed, summary: "done",
                output: [.text(id: "segment-1", content: "file text")]),
        ])
        let calls = Self.toolCallUpdates(in: updates)

        #expect(calls.map(\.toolCallId.rawValue) == Array(repeating: Self.sdkToolCallId, count: calls.count))
        guard case (let creation?, let running?, let completion?) = (calls.first, calls.dropFirst().first, calls.dropFirst(2).first) else {
            Issue.record("expected three tool_call_update sends, got \(calls)")
            return
        }
        #expect(creation.title == .value(Self.scriptedToolName))
        #expect(creation.status == .value(.inProgress))
        #expect(creation.rawInput == .value(.object(["path": .string("notes.txt")])))
        #expect(running.status == .value(.inProgress))
        #expect(completion.status == .value(.completed))
        #expect(Self.texts(in: completion.content) == ["done", "file text"])
    }

    /// A failed tool status reports `failed`.
    @Test func aFailedToolStatusReportsFailed() async throws {
        let updates = await Self.drive([
            .toolStatus(id: Self.sdkToolCallId, status: .failed, summary: nil, output: nil)
        ])
        let call = try #require(Self.toolCallUpdates(in: updates).first)
        #expect(call.status == .value(.failed))
    }

    // MARK: - The settlement (§8.4, §11.6)

    /// A `.lost` outcome settles as `_lost` — never as `failed` — and
    /// its text says the run's fate is unknown.
    @Test func aLostRunSettlesAsUnderscoreLostAndNeverFailed() async throws {
        let updates = await Self.drive([.runSettled(Self.makeOperationEvent(outcome: .lost))])
        let call = try #require(Self.toolCallUpdates(in: updates).first)

        #expect(call.toolCallId.rawValue == Self.completionToken)
        #expect(call.status == .value(.unknown(EventProjection.lostStatusWireValue)))
        #expect(call.status != .value(.failed))
        #expect(Self.texts(in: call.content).contains { $0.contains("do not know") })
    }

    /// A `.timedOut` outcome settles as `failed` and names the timeout
    /// in the text.
    @Test func aTimedOutRunSettlesAsFailedAndNamesTheTimeout() async throws {
        let updates = await Self.drive([.runSettled(Self.makeOperationEvent(outcome: .timedOut))])
        let call = try #require(Self.toolCallUpdates(in: updates).first)

        #expect(call.status == .value(.failed))
        #expect(Self.texts(in: call.content).contains { $0.contains("timed out") })
    }

    /// A `.completed` event that arrives with a nil outcome — the rule
    /// is a doc comment, not a type guarantee — settles as unknown and
    /// does not crash the projection.
    @Test func aCompletedEventWithNilOutcomeSettlesAsUnknown() async throws {
        let updates = await Self.drive([.runSettled(Self.makeOperationEvent(outcome: nil))])
        let call = try #require(Self.toolCallUpdates(in: updates).first)

        #expect(
            call.status
                == .value(.unknown(EventProjection.unknownOutcomeStatusWireValue)))
    }

    /// An outcome on a non-terminal event is ignored: a `.progress`
    /// event that carries one settles nothing.
    @Test func anOutcomeOnAProgressEventIsIgnored() async throws {
        let updates = await Self.drive([
            .runSettled(Self.makeOperationEvent(outcome: .succeeded, kind: .progress))
        ])
        #expect(Self.toolCallUpdates(in: updates).isEmpty)
    }

    /// The settlement update replaces the call's content with the
    /// complete stored record, so a client that missed a chunk
    /// converges (§11.6).
    @Test func aSettledRunReplacesContentFromTheStoredSnapshot() async throws {
        let snapshot = ShellOutputSnapshot(
            stdout: Self.makeRawOutput(text: "hello"),
            stderr: Self.makeRawOutput(text: "oops"))
        let updates = await Self.drive(
            [.runSettled(Self.makeOperationEvent(outcome: .succeeded))]
        ) { commandID in
            commandID == Self.completionToken ? snapshot : nil
        }
        let call = try #require(Self.toolCallUpdates(in: updates).first)

        #expect(call.status == .value(.completed))
        #expect(Self.texts(in: call.content) == ["hello", "oops"])
    }

    // MARK: - The live shell chunks (§8.4, §11.8)

    /// An output event becomes one `tool_call_content_chunk` keyed by
    /// the run's `commandID`, decoded as UTF-8 with replacement so no
    /// byte is dropped silently.
    @Test func aShellOutputEventBecomesOneChunkKeyedByTheCommandID() throws {
        let bytes = Array("build ok".utf8) + [Self.invalidUTF8Byte]
        let update = EventProjection.update(
            for: ShellOutputEvent(
                commandID: Self.completionToken,
                kind: .output(stream: .stdout, bytes: bytes)))

        guard case .toolCallContentChunk(let chunk) = try #require(update) else {
            Issue.record("expected a tool_call_content_chunk, got \(String(describing: update))")
            return
        }
        #expect(chunk.toolCallId.rawValue == Self.completionToken)
        guard case .content(let wrapped) = chunk.content, case .text(let text) = wrapped.content
        else {
            Issue.record("expected a text content item, got \(chunk.content)")
            return
        }
        #expect(text.text.contains("build ok"))
        #expect(text.text.contains("\u{FFFD}"))
    }

    /// A gap event becomes one chunk that names the dropped byte count
    /// and the stream it belongs to.
    @Test func aGapEventBecomesOneChunkNamingTheDroppedBytes() throws {
        let update = EventProjection.update(
            for: ShellOutputEvent(
                commandID: Self.completionToken,
                kind: .gap(stream: .stderr, droppedByteCount: Self.droppedByteCount)))

        guard case .toolCallContentChunk(let chunk) = try #require(update) else {
            Issue.record("expected a tool_call_content_chunk, got \(String(describing: update))")
            return
        }
        guard case .content(let wrapped) = chunk.content, case .text(let text) = wrapped.content
        else {
            Issue.record("expected a text content item, got \(chunk.content)")
            return
        }
        #expect(text.text.contains("\(Self.droppedByteCount)"))
        #expect(text.text.contains("stderr"))
    }

    /// The completion marker sends nothing: the settlement update from
    /// `runSettled` is the run's terminal report.
    @Test func aCompletedMarkerSendsNoChunk() {
        let update = EventProjection.update(
            for: ShellOutputEvent(commandID: Self.completionToken, kind: .completed))
        #expect(update == nil)
    }

    /// The projection consumes the host-owned live stream to its end,
    /// sending one chunk per payload event.
    @Test func theProjectionConsumesTheLiveShellStreamToChunks() async {
        let recorder = SinkRecorder()
        let (stream, continuation) = AsyncStream<ShellOutputEvent>.makeStream()
        continuation.yield(
            ShellOutputEvent(
                commandID: Self.completionToken,
                kind: .output(stream: .stdout, bytes: Array("line one\n".utf8))))
        continuation.yield(
            ShellOutputEvent(
                commandID: Self.completionToken,
                kind: .gap(stream: .stdout, droppedByteCount: Self.droppedByteCount)))
        continuation.yield(
            ShellOutputEvent(commandID: Self.completionToken, kind: .completed))
        continuation.finish()

        await EventProjection.projectShellOutput(stream) { update in
            await recorder.append(update)
        }
        let updates = await recorder.updates

        #expect(updates.map(\.kind) == [.toolCallContentChunk, .toolCallContentChunk])
    }

    // MARK: - The message-closing entry record (§8.4)

    /// A recorded `.response` entry closes the agent message: the next
    /// text delta starts a new message id (§8.3).
    @Test func aRecordedResponseEntryClosesTheAgentMessage() async throws {
        let updates = await Self.drive([
            .textDelta("first"),
            .entryRecorded(id: "entry-1", kind: .response),
            .textDelta("second"),
        ])
        let ids = Self.chunkMessageIds(in: updates)

        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    /// A recorded `.reasoning` entry closes the thought message the
    /// same way.
    @Test func aRecordedReasoningEntryClosesTheThoughtMessage() async throws {
        let updates = await Self.drive([
            .reasoningDelta("first"),
            .entryRecorded(id: "entry-1", kind: .reasoning),
            .reasoningDelta("second"),
        ])
        let ids = updates.compactMap { update -> MessageId? in
            if case .agentThoughtChunk(let chunk) = update { return chunk.messageId }
            return nil
        }

        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    // MARK: - The delivery-only and log-only events (§8.4)

    /// A `toolInvocation` record, a priming failure, and a stall report
    /// send nothing on the wire: the only update of the turn is its
    /// idle terminator.
    @Test func deliveryOnlyEventsSendNoWireMessage() async {
        let record = ToolInvocationRecord(
            tool: "shell",
            op: "execute command",
            correlationID: Self.completionToken,
            sessionID: ULID.generate(),
            openedAt: Date())
        let stall = GenerationStall(
            timeWithoutProgress: .seconds(1),
            timeInFlight: .seconds(1),
            visibility: .wholeAnswer)
        let updates = await Self.drive([
            .toolInvocation(record),
            .discoveryPrimingFailed(.toolNotMounted(tool: "codemode")),
            .generationStalled(stall),
        ])

        #expect(updates.map(\.kind) == [.stateUpdate])
    }

    // MARK: - Compaction (§8.5)

    /// A compaction sends one `usage_update` — the meter drops to the
    /// post-fold size — and no message update.
    @Test func aCompactionSendsOneUsageUpdateAndNoMessageUpdate() async throws {
        let result = CompactionResult(
            summary: nil,
            tokensBefore: Self.tokensBeforeFold,
            tokensAfter: Self.tokensAfterFold,
            stagesApplied: ["fold"])
        let updates = await Self.drive([.compaction(result)])

        #expect(updates.map(\.kind) == [.usageUpdate, .stateUpdate])
        guard case .usageUpdate(let usage) = try #require(updates.first) else {
            Issue.record("expected the usage update first, got \(updates)")
            return
        }
        #expect(usage.used == Self.tokensAfterFold)
        #expect(usage.size == Self.tokensBeforeFold)
    }

    // MARK: - The NaN meter guard (§8.4)

    /// A `NaN` context fill means "no stamp": the turn sends no meter
    /// and never puts a `NaN` on the wire.
    @Test func aNaNContextFillOmitsTheUsageUpdate() async {
        let updates = await Self.drive([
            .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan))
        ])
        #expect(!updates.contains { $0.kind == .usageUpdate })
    }

    // MARK: - The diff path directions (§11.6)

    /// A move maps the source to `oldPath` and the destination to
    /// `path`: ACP's `path` is post-operation.
    @Test func aMoveMapsTheSourceToOldPathAndTheDestinationToPath() throws {
        let source = try #require(AbsolutePath(rawValue: "/repo/old.txt"))
        let destination = try #require(AbsolutePath(rawValue: "/repo/new.txt"))
        let change = EventProjection.diffChange(
            for: .move(source: source, destination: destination))

        guard case .move(let pair) = change.operation else {
            Issue.record("expected a move operation, got \(change.operation)")
            return
        }
        #expect(pair.oldPath == source)
        #expect(pair.path == destination)
    }

    /// A copy maps the two endpoints the same way as a move.
    @Test func aCopyMapsTheSourceToOldPathAndTheDestinationToPath() throws {
        let source = try #require(AbsolutePath(rawValue: "/repo/a.txt"))
        let destination = try #require(AbsolutePath(rawValue: "/repo/b.txt"))
        let change = EventProjection.diffChange(
            for: .copy(source: source, destination: destination))

        guard case .copy(let pair) = change.operation else {
            Issue.record("expected a copy operation, got \(change.operation)")
            return
        }
        #expect(pair.oldPath == source)
        #expect(pair.path == destination)
    }

    /// An add, a delete, and a modify map the one path without change.
    @Test func addDeleteAndModifyMapThePathWithoutChange() throws {
        let path = try #require(AbsolutePath(rawValue: "/repo/file.txt"))

        guard
            case .add(let added) = EventProjection.diffChange(for: .add(path: path)).operation,
            case .delete(let deleted) = EventProjection.diffChange(for: .delete(path: path))
                .operation,
            case .modify(let modified) = EventProjection.diffChange(for: .modify(path: path))
                .operation
        else {
            Issue.record("expected add, delete and modify operations")
            return
        }
        #expect(added.path == path)
        #expect(deleted.path == path)
        #expect(modified.path == path)
    }

    // MARK: - The raw wire shape (plan.md §20.1)

    /// The tool updates cross the transport with the v2 shape: the
    /// `snake_case` `sessionUpdate` discriminator, the `camelCase`
    /// properties, the `in_progress` status spelling, and the `_lost`
    /// extension value.
    @Test(.timeLimit(.minutes(1)))
    func toolUpdatesHaveTheV2WireShapeThroughTheTransport() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "EventProjectionTests-cache"))
        let connection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        let frames = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled)
        let sessionId = SessionId(rawValue: syntheticSessionIdValue)
        let send: SessionUpdateSink = { update in await connection.post(update, in: sessionId) }
        let turn = PromptTurn(
            sessionId: sessionId,
            promptBlocks: [],
            turnState: TurnStateOwner(send: send),
            send: send,
            firstActivity: nil)

        _ = await turn.drive(
            events: makeEventStream([
                .toolCall(
                    id: Self.sdkToolCallId, name: Self.scriptedToolName,
                    argumentsJSON: Self.scriptedArgumentsJSON),
                .runSettled(Self.makeOperationEvent(outcome: .lost)),
            ]))

        var notifications: [[String: FoundationModelsACP.JSONValue]] = []
        var iterator = frames.makeAsyncIterator()
        while notifications.count < Self.rawWireNotificationCount,
            let frame = try await iterator.next()
        {
            guard case .message(.object(let fields)) = frame,
                Self.stringValue(fields["method"]) == "session/update",
                let params = Self.objectFields(fields["params"])
            else { continue }
            #expect(Self.stringValue(params["sessionId"]) == syntheticSessionIdValue)
            let update = try #require(Self.objectFields(params["update"]))
            notifications.append(update)
        }
        await connection.close()
        clientEnd.close()

        #expect(
            notifications.map { Self.stringValue($0["sessionUpdate"]) } == [
                "tool_call_update", "tool_call_update", "state_update",
            ])
        let creation = try #require(notifications.first)
        #expect(Self.stringValue(creation["toolCallId"]) == Self.sdkToolCallId)
        #expect(Self.stringValue(creation["status"]) == "in_progress")
        #expect(Self.stringValue(creation["title"]) == Self.scriptedToolName)
        let settlement = try #require(notifications.dropFirst().first)
        #expect(
            Self.stringValue(settlement["status"]) == EventProjection.lostStatusWireValue)
    }
}
