import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The prompt turn (plan.md §8.1–§8.3, §10.1): the acknowledge-then-notify
/// order, the `user_message` echo, the turn-state machine, the stop-reason
/// mapping, and the first-activity index record.
@Suite struct PromptTurnTests {
    // MARK: - Constants

    /// The first prompt line. It becomes the session title.
    private static let promptTitleLine = "Say hello to the tests"

    /// The prompt text of the wire tests: two lines, so the cut to a
    /// one-line title is observable.
    private static let promptText = "Say hello to the tests\nwith a second line"

    // MARK: - Harness
    //
    // The wired fixture, the collector waits, and the sequence readers
    // live in `Support/ScriptedTurnFixture.swift`, shared with
    // `CancellationTests`.

    /// Wires the shared fixture with this suite's directory label.
    ///
    /// - Parameter script: The steps the model plays on every turn.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        script: [ScriptedTurnStep]
    ) async throws -> ScriptedTurnFixture {
        try await ScriptedTurnFixture.make(script: script, label: "PromptTurnTests")
    }

    /// The prompt request with one text block and this suite's default
    /// two-line text.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - text: The text of the one block.
    /// - Returns: The request.
    private static func makePromptRequest(
        sessionId: SessionId, text: String = promptText
    ) -> PromptRequest {
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text)
    }

    /// The index of the fixture session's recording root.
    ///
    /// - Parameter fixture: The fixture whose session is open.
    /// - Returns: The `sessions.jsonl` index.
    /// - Throws: When the session is not in the agent's table.
    private static func sessionIndex(of fixture: ScriptedTurnFixture) async throws -> SessionIndex {
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        return SessionIndex(root: entry.transcriptDirectory.deletingLastPathComponent())
    }

    /// Reads one string field of a wire error's `data` object.
    ///
    /// - Parameters:
    ///   - name: The field name.
    ///   - error: The wire error.
    /// - Returns: The string value, or `nil` when absent.
    private static func dataField(_ name: String, of error: RequestError) -> String? {
        guard case .object(let fields) = error.data ?? .null,
            case .string(let value) = fields[name] ?? .null
        else {
            return nil
        }
        return value
    }

    // MARK: - The §8.1 order

    /// A scripted turn streams the acknowledge-then-notify order: the
    /// `{}` response returns first, then the echo, the first-activity
    /// info update, `running`, the chunks, and one `idle` with
    /// `end_turn`. The echo owns the message identity (§8.3): the agent
    /// chunks ride one different id.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedTurnStreamsTheAcknowledgeThenNotifyOrder() async throws {
        let fixture = try await Self.makeFixture(script: [
            .textDelta("Hello "), .textDelta("there."), .endTurn,
        ])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = turnUpdates(in: try await ScriptedTurnFixture.waitForIdle(fixture.collector))
        await fixture.close()

        #expect(
            updates.map(\.update.kind) == [
                .userMessage, .sessionInfoUpdate, .stateUpdate,
                .agentMessageChunk, .agentMessageChunk, .stateUpdate,
            ])
        guard case .userMessage(let echo) = updates.first?.update else {
            Issue.record("expected the user_message echo first, got \(updates)")
            return
        }
        #expect(echo.content == .value([.text(TextContent(text: Self.promptText))]))
        #expect(!echo.messageId.rawValue.isEmpty)

        let chunkIds = updates.compactMap { notification -> MessageId? in
            if case .agentMessageChunk(let chunk) = notification.update {
                return chunk.messageId
            }
            return nil
        }
        #expect(Set(chunkIds).count == 1)
        #expect(chunkIds.first != echo.messageId)

        guard case .stateUpdate(.running) = updates[2].update else {
            Issue.record("expected running before the turn output, got \(updates[2])")
            return
        }
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        if case .stateUpdate(.idle) = try #require(updates.last).update {} else {
            Issue.record("expected idle as the terminator")
        }
    }

    // MARK: - The busy refusal (§7.1)

    /// A second `session/prompt` during a running turn answers a client
    /// error and does not disturb the first turn.
    @Test(.timeLimit(.minutes(1)))
    func aBusySessionRefusesASecondPromptAsAClientError() async throws {
        let fixture = try await Self.makeFixture(script: [.hold])
        let first = Task {
            try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: fixture.sessionId))
        }
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: fixture.sessionId))
            Issue.record("expected the busy refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidRequest)
            #expect(Self.dataField("sessionId", of: error) == fixture.sessionId.rawValue)
        }

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        _ = try await first.value
        await fixture.close()

        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        #expect(updates.count { $0.update.kind == .userMessage } == 1)
    }

    // MARK: - The stop-reason matrix (§8.2)

    /// A guardrail refusal ends the turn as `idle` with `refusal`.
    @Test(.timeLimit(.minutes(1)))
    func aGuardrailRefusalEndsTheTurnWithTheRefusalStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.guardrailViolation)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .refusal)
    }

    /// A context overflow ends the turn as `idle` with `max_tokens`.
    @Test(.timeLimit(.minutes(1)))
    func aContextOverflowEndsTheTurnWithTheMaxTokensStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.exceededContextWindow)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .maxTokens)
    }

    /// A `session/cancel` during a held turn surfaces as `idle` with
    /// `cancelled`, not as an error (§8.6).
    @Test(.timeLimit(.minutes(1)))
    func aCancelledTurnEndsIdleWithTheCancelledStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("thinking"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
    }

    /// The `TurnStop` to `StopReason` function is total, including the
    /// tool-loop arm whose producer is a later task.
    @Test func theStopReasonMappingIsTotal() {
        #expect(PromptTurn.stopReason(for: .completed) == .endTurn)
        #expect(PromptTurn.stopReason(for: .refusal) == .refusal)
        #expect(PromptTurn.stopReason(for: .cancelled) == .cancelled)
        #expect(PromptTurn.stopReason(for: .budgetExhausted) == .maxTokens)
        #expect(PromptTurn.stopReason(for: .toolLoopCapped) == .maxTurnRequests)
        #expect(
            PromptTurn.stopReason(for: .noOutput)
                == .unknown(PromptTurn.noOutputStopReasonValue))
        #expect(
            PromptTurn.stopReason(for: .failed(message: "boom"))
                == .unknown(PromptTurn.unmappedStopReasonValue))
    }

    /// The error classifier reads `CancellationError` and the public SDK
    /// generation errors; an unmapped error degrades to `failed`.
    @Test func classifyReadsCancellationAndGenerationErrors() {
        #expect(PromptTurn.classify(CancellationError()) == .cancelled)
        #expect(PromptTurn.classify(ScriptedFailure.guardrailViolation.error) == .refusal)
        #expect(
            PromptTurn.classify(ScriptedFailure.exceededContextWindow.error) == .budgetExhausted)
        guard case .failed = PromptTurn.classify(ScriptedModelError.unknownTool("x")) else {
            Issue.record("expected an unmapped error to classify as failed")
            return
        }
    }

    // MARK: - The projection core (synthetic event streams)
    //
    // The sinked-turn and event-stream fixtures live in
    // `Support/ProjectionTestSupport.swift`, shared with
    // `EventProjectionTests`.

    /// A retry turn carries two `turnEnded` events; the turn still ends
    /// with exactly one `idle`, keyed on stream completion (§8.1).
    @Test func aRetryTurnSendsTwoTurnEndedAndExactlyOneIdle() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .textDelta("first attempt"),
                .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 2, contextFill: .nan)),
                .textReset,
                .textDelta("second attempt"),
                .turnEnded(TokenUsage(tokensIn: 3, tokensOut: 4, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        guard case .stateUpdate(.idle(let idle)) = try #require(updates.last) else {
            Issue.record("expected idle as the terminator, got \(updates)")
            return
        }
        #expect(idle.stopReason == .endTurn)
        #expect(!updates.contains { $0.kind == .usageUpdate })
    }

    /// `textReset` discards the collected text as a whole-message
    /// replace on the same message id, never as another chunk (§8.3).
    @Test func textResetSendsAWholeMessageReplaceOnTheSameMessageId() async throws {
        let (turn, recorder) = makeSinkedTurn()
        _ = await turn.drive(
            events: makeEventStream([
                .textDelta("draft"), .textReset, .textDelta("final"),
            ]))
        let updates = await recorder.updates

        guard case .agentMessageChunk(let draft) = updates[0],
            case .agentMessage(let replace) = updates[1],
            case .agentMessageChunk(let final) = updates[2]
        else {
            Issue.record("expected chunk, replace, chunk; got \(updates)")
            return
        }
        #expect(replace.messageId == draft.messageId)
        #expect(replace.content == .value([]))
        #expect(final.messageId == draft.messageId)
    }

    /// Tool events project to `tool_call_update` sends in stream order
    /// (§8.4) and do not disturb the text stream: the two text chunks
    /// still share one message id, and the turn still ends with one
    /// `idle`.
    @Test func toolEventsProjectInOrderWithoutBreakingTheTextStream() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .textDelta("a"),
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .completed, summary: nil, output: nil),
                .textDelta("b"),
                .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(
            updates.map(\.kind) == [
                .agentMessageChunk, .toolCallUpdate, .toolCallUpdate,
                .agentMessageChunk, .stateUpdate,
            ])
        let chunkIds = updates.compactMap { update -> MessageId? in
            if case .agentMessageChunk(let chunk) = update { return chunk.messageId }
            return nil
        }
        #expect(Set(chunkIds).count == 1)
    }

    /// The usage of every `turnEnded` is summed and reported one time,
    /// before the idle terminator (§8.1).
    @Test func turnEndedUsageIsSummedIntoOneUsageUpdate() async throws {
        let (turn, recorder) = makeSinkedTurn()
        _ = await turn.drive(
            events: makeEventStream([
                .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 2, contextFill: .nan)),
                .turnEnded(TokenUsage(tokensIn: 3, tokensOut: 4, contextFill: 0.5)),
            ]))
        let updates = await recorder.updates

        let usages = updates.compactMap { update -> UsageUpdate? in
            if case .usageUpdate(let usage) = update { return usage }
            return nil
        }
        #expect(usages.count == 1)
        #expect(usages.first?.used == 10)
        #expect(usages.first?.size == 20)
        #expect(updates.last?.kind == .stateUpdate)
    }

    /// A thrown `CancellationError` maps to the `cancelled` stop reason;
    /// it never escapes as an error and never reads as `refusal` (§8.2).
    @Test func aThrownCancellationBecomesTheCancelledStopReason() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([.textDelta("partial")], throwing: CancellationError()))
        let updates = await recorder.updates

        #expect(reason == .cancelled)
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
    }

    // MARK: - The no-output turn (§8.2, task ^pez780d)

    /// A completed turn with no output and a zero-token usage report
    /// ends with the honest `_no_output` extension stop reason, never
    /// with a bare `end_turn`.
    @Test func aZeroTokenTurnWithNoOutputEndsWithTheNoOutputStopReason() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .turnEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptTurn.noOutputStopReasonValue))
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(
            ScriptedTurnFixture.idleStopReason(in: updates)
                == .unknown(PromptTurn.noOutputStopReasonValue))
    }

    /// A turn that streamed text keeps `end_turn`, also when the usage
    /// report is zero: the text is real output.
    @Test func aZeroTokenTurnWithTextKeepsTheEndTurnStopReason() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .textDelta("real output"),
                .turnEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A turn that made a tool call keeps `end_turn`, also when the
    /// usage report is zero: the call is real output.
    @Test func aZeroTokenTurnWithAToolCallKeepsTheEndTurnStopReason() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .completed, summary: nil, output: nil),
                .turnEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A turn that carried an attachment report keeps `end_turn`, also
    /// when the usage report is zero: the report's `tool_call_update`
    /// is real output.
    @Test func aZeroTokenTurnWithAToolCallReportKeepsTheEndTurnStopReason() async throws {
        let report = ToolCallReport(
            tool: "files",
            op: "edit file",
            correlationID: "01SCRIPTEDRUNTOKEN00000000",
            sessionID: ULID.generate(),
            attachments: [
                ToolCallAttachment(schemaName: "note", contentJSON: #"{"note":"kept"}"#)
            ])
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(
            events: makeEventStream([
                .toolCallReport(report),
                .turnEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A completed turn with no usage report keeps `end_turn`: with no
    /// report there is no zero-token evidence, and the turn must not
    /// invent one.
    @Test func aTurnWithNoUsageReportKeepsTheEndTurnStopReason() async throws {
        let (turn, recorder) = makeSinkedTurn()
        let reason = await turn.drive(events: makeEventStream([]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A scripted turn that plays only `.endTurn` makes the live defect
    /// shape on the wire: the Router turn completes with no output and
    /// a zero-token usage delta. The idle terminator carries
    /// `_no_output`, never a bare `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedTurnWithNoOutputEndsIdleWithTheNoOutputStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(
            ScriptedTurnFixture.idleStopReason(in: updates)
                == .unknown(PromptTurn.noOutputStopReasonValue))
    }

    // MARK: - The requires_action pairing (§8.2)

    /// Makes one composed Router session for the gate pairing tests.
    private static func makeRoutedSession() async throws -> any RoutedSession {
        let fixture = try await makeFixture(script: [.endTurn])
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        await fixture.close()
        return entry.session
    }

    /// `awaitingUser` sends `requires_action`, runs the body under the
    /// Router gate, and returns to `running` with the body's value.
    @Test(.timeLimit(.minutes(1)))
    func awaitingUserPairsRequiresActionWithTheRouterGate() async throws {
        let session = try await Self.makeRoutedSession()
        let recorder = SinkRecorder()
        let owner = TurnStateOwner(send: { update in await recorder.append(update) })

        let answer = await owner.awaitingUser(on: session) { "the answer" }
        let updates = await recorder.updates

        #expect(answer == "the answer")
        guard updates.count == 2,
            case .stateUpdate(.requiresAction) = updates[0],
            case .stateUpdate(.running) = updates[1]
        else {
            Issue.record("expected requires_action then running, got \(updates)")
            return
        }
    }

    /// A body that throws still returns the state to `running`.
    @Test(.timeLimit(.minutes(1)))
    func awaitingUserReturnsToRunningWhenTheBodyThrows() async throws {
        let session = try await Self.makeRoutedSession()
        let recorder = SinkRecorder()
        let owner = TurnStateOwner(send: { update in await recorder.append(update) })

        await #expect(throws: ScriptedModelError.self) {
            _ = try await owner.awaitingUser(on: session) { () -> String in
                throw ScriptedModelError.unknownTool("x")
            }
        }
        let updates = await recorder.updates

        guard updates.count == 2,
            case .stateUpdate(.requiresAction) = updates[0],
            case .stateUpdate(.running) = updates[1]
        else {
            Issue.record("expected requires_action then running, got \(updates)")
            return
        }
    }

    // MARK: - The unknown-id policy (§10.1)

    /// An unknown `sessionId` answers `-32602` with the id in `data`,
    /// and sends no `session/update`.
    @Test(.timeLimit(.minutes(1)))
    func anUnknownSessionIdAnswersInvalidParamsAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        let bogus = SessionId(rawValue: syntheticSessionIdValue)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: bogus))
            Issue.record("expected invalid params for the unknown id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(Self.dataField("sessionId", of: error) == bogus.rawValue)
        }

        #expect(turnUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }

    /// A known but closed session answers `-32602` with the resume
    /// hint, because a closed session is resumable, not promptable.
    @Test(.timeLimit(.minutes(1)))
    func aClosedSessionIdAnswersInvalidParamsWithTheResumeHint() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        await fixture.harness.agent.markSessionClosed(fixture.sessionId)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: fixture.sessionId))
            Issue.record("expected invalid params for the closed id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(Self.dataField("reason", of: error) == "closed; resume it first")
        }

        #expect(turnUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }

    // MARK: - The title and the index timing (§9)

    /// `sessions.jsonl` is absent before the first prompt, gains the
    /// session's record with a one-line title at the first prompt, and
    /// gains nothing more at the second prompt.
    @Test(.timeLimit(.minutes(1)))
    func theFirstPromptWritesTheIndexRecordWithAOneLineTitle() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("done"), .endTurn])
        let index = try await Self.sessionIndex(of: fixture)
        #expect(try index.read().records.isEmpty)

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let firstTurn = try await ScriptedTurnFixture.waitForIdle(fixture.collector)

        let records = try index.read().records
        #expect(records.count == 1)
        #expect(records.first?.sessionId == fixture.sessionId.rawValue)
        #expect(records.first?.title == Self.promptTitleLine)
        #expect(records.first?.cwd == fixture.cwd.path)

        let titles = firstTurn.compactMap { notification -> PatchField<String>? in
            if case .sessionInfoUpdate(let info) = notification.update { return info.title }
            return nil
        }
        #expect(titles == [.value(Self.promptTitleLine)])

        try await ScriptedTurnFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId, text: "a second prompt"))
        let secondTurn = try await ScriptedTurnFixture.waitForIdle(fixture.collector, count: 2)
        await fixture.close()

        #expect(try index.read().records.count == 1)
        #expect(secondTurn.count { $0.update.kind == .sessionInfoUpdate } == 1)
    }
}
