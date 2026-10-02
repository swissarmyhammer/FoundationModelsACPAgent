import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The prompt execution (plan.md §8.1–§8.3, §10.1): the acknowledge-then-notify
/// order, the `user_message` echo, the prompt-state machine, the stop-reason
/// mapping, and the first-activity index record.
@Suite struct PromptExecutionTests {
    // MARK: - Constants

    /// The first prompt line. It becomes the session title.
    private static let promptTitleLine = "Say hello to the tests"

    /// The prompt text of the wire tests: two lines, so the cut to a
    /// one-line title is observable.
    private static let promptText = "Say hello to the tests\nwith a second line"

    // MARK: - Harness
    //
    // The wired fixture, the collector waits, and the sequence readers
    // live in `Support/ScriptedPromptFixture.swift`, shared with
    // `CancellationTests`.

    /// Wires the shared fixture with this suite's directory label.
    ///
    /// - Parameter script: The steps the model plays on every pass.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        script: [ScriptedPassStep]
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(script: script, label: "PromptExecutionTests")
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
    private static func sessionIndex(of fixture: ScriptedPromptFixture) async throws -> SessionIndex {
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

    /// A scripted prompt streams the acknowledge-then-notify order: the
    /// `{}` response returns first, then the echo, the first-activity
    /// info update, `running`, the chunks, and one `idle` with
    /// `end_turn`. The echo owns the message identity (§8.3): the agent
    /// chunks ride one different id.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedPromptStreamsTheAcknowledgeThenNotifyOrder() async throws {
        let fixture = try await Self.makeFixture(script: [
            .textDelta("Hello "), .textDelta("there."), .endPass,
        ])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = promptUpdates(in: try await ScriptedPromptFixture.waitForIdle(fixture.collector))
        await fixture.close()

        #expect(
            updates.map(\.update.kind) == [
                .userMessage, .sessionInfoUpdate, .stateUpdate,
                .agentMessageChunk, .agentMessageChunk, .stateUpdate,
            ])
        let echo = try #require(
            userMessageEcho(of: updates.first?.update),
            "expected the user_message echo first, got \(updates)")
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

        #expect(
            isRunningState(updates[2].update),
            "expected running before the prompt output, got \(updates[2])")
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        if case .stateUpdate(.idle) = try #require(updates.last).update {} else {
            Issue.record("expected idle as the terminator")
        }
    }

    /// The prompt response names the user message (ACP
    /// schema-v2.0.0-alpha.7): its `messageId` is the id of the one
    /// `user_message` echo that reaches the client.
    @Test(.timeLimit(.minutes(1)))
    func thePromptResponseNamesTheEchoedUserMessage() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("Hello."), .endPass])
        let response = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let echoIds = updates.compactMap { userMessageEcho(of: $0.update)?.messageId }
        #expect(echoIds == [response.messageId])
    }

    // MARK: - The busy refusal (§7.1)

    /// A second `session/prompt` during a running prompt answers a client
    /// error and does not disturb the first prompt.
    @Test(.timeLimit(.minutes(1)))
    func aBusySessionRefusesASecondPromptAsAClientError() async throws {
        let fixture = try await Self.makeFixture(script: [.hold])
        let first = Task {
            try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: fixture.sessionId))
        }
        try await ScriptedPromptFixture.waitForRunning(fixture.collector)

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
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        _ = try await first.value
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .cancelled)
        #expect(updates.count { $0.update.kind == .userMessage } == 1)
    }

    // MARK: - The stop-reason matrix (§8.2)

    /// A guardrail refusal ends the prompt as `idle` with `refusal`.
    @Test(.timeLimit(.minutes(1)))
    func aGuardrailRefusalEndsThePromptWithTheRefusalStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.guardrailViolation)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .refusal)
    }

    /// A context overflow ends the prompt as `idle` with `max_tokens`.
    @Test(.timeLimit(.minutes(1)))
    func aContextOverflowEndsThePromptWithTheMaxTokensStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.exceededContextWindow)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .maxTokens)
    }

    /// A `session/cancel` during a held prompt surfaces as `idle` with
    /// `cancelled`, not as an error (§8.6).
    @Test(.timeLimit(.minutes(1)))
    func aCancelledPromptEndsIdleWithTheCancelledStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("thinking"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await ScriptedPromptFixture.waitForRunning(fixture.collector)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .cancelled)
    }

    /// The `PromptStop` to `StopReason` function is total, including the
    /// tool-loop arm whose producer is a later task.
    @Test func theStopReasonMappingIsTotal() {
        #expect(PromptExecution.stopReason(for: .completed) == .endTurn)
        #expect(PromptExecution.stopReason(for: .refusal) == .refusal)
        #expect(PromptExecution.stopReason(for: .cancelled) == .cancelled)
        #expect(PromptExecution.stopReason(for: .budgetExhausted) == .maxTokens)
        #expect(PromptExecution.stopReason(for: .toolLoopCapped) == .maxTurnRequests)
        #expect(
            PromptExecution.stopReason(for: .noOutput)
                == .unknown(PromptExecution.noOutputStopReasonValue))
        #expect(
            PromptExecution.stopReason(for: .truncated)
                == .unknown(PromptExecution.truncatedStopReasonValue))
        #expect(
            PromptExecution.stopReason(for: .endedInReasoning)
                == .unknown(PromptExecution.endedInReasoningStopReasonValue))
        #expect(
            PromptExecution.stopReason(for: .repeated)
                == .unknown(PromptExecution.repeatedStopReasonValue))
        #expect(
            PromptExecution.stopReason(for: .reasoningLimit)
                == .unknown(PromptExecution.reasoningLimitStopReasonValue))
        #expect(
            PromptExecution.stopReason(
                for: .stalled(Self.makeStall(withoutProgress: .zero, fragments: 0)))
                == .unknown(PromptExecution.stalledStopReasonValue))
        #expect(
            PromptExecution.stopReason(for: .failed(message: "boom"))
                == .unknown(PromptExecution.unmappedStopReasonValue))
    }

    /// Whether one prompt stop is the `failed` stop. The stop carries a
    /// message, so no test can name one value to compare against.
    ///
    /// - Parameter stop: The prompt stop to read.
    /// - Returns: `true` for a failed stop.
    private static func isFailed(_ stop: PromptStop) -> Bool {
        if case .failed = stop { return true }
        return false
    }

    /// The error classifier reads `CancellationError` and the public SDK
    /// generation errors; an unmapped error degrades to `failed`.
    @Test func classifyReadsCancellationAndGenerationErrors() {
        #expect(PromptExecution.classify(CancellationError()) == .cancelled)
        #expect(PromptExecution.classify(ScriptedFailure.guardrailViolation.error) == .refusal)
        #expect(
            PromptExecution.classify(ScriptedFailure.exceededContextWindow.error) == .budgetExhausted)
        #expect(
            Self.isFailed(PromptExecution.classify(ScriptedModelError.unknownTool("x"))),
            "expected an unmapped error to classify as failed")
    }

    // MARK: - The projection core (synthetic event streams)
    //
    // The sinked-execution and event-stream fixtures live in
    // `Support/ProjectionTestSupport.swift`, shared with
    // `EventProjectionTests`.

    /// A retry makes two submissions in one prompt. The Router sends the
    /// events of both submissions, the usage of each generation call, and
    /// one `answered` event with the total usage of the chain. The prompt
    /// sends one `running`, one `usage_update` with each submission counted
    /// one time, and one `idle`, keyed on stream completion (§8.1).
    @Test func aRetryWithTwoSubmissionsSendsOneRunningOneSummedUsageUpdateAndOneIdle() async throws {
        let first = TokenUsage(tokensIn: 100, tokensOut: 20, contextFill: 0.25)
        let second = TokenUsage(tokensIn: 150, tokensOut: 30, contextFill: 0.5)
        let chain = TokenUsage(tokensIn: 250, tokensOut: 50, contextFill: 0.5)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionStarted(),
                .textDelta("first attempt"),
                .generationCall(
                    GenerationCallUsage(
                        tokensIn: 100, tokensOut: 20, finishReason: .completed, entryKind: .text,
                        contextFill: 0.25)),
                makeSubmissionEnded(first),
                makeSubmissionStarted(cause: .continuation),
                .textReset,
                .textDelta("second attempt"),
                .generationCall(
                    GenerationCallUsage(
                        tokensIn: 150, tokensOut: 30, finishReason: .completed, entryKind: .text,
                        contextFill: 0.5)),
                makeSubmissionEnded(second),
                .answered(.makeSynthetic(usage: chain)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(updates.count { isRunningState($0) } == 1)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        let idle = try #require(
            idleState(of: updates.last), "expected idle as the terminator, got \(updates)")
        #expect(idle.stopReason == .endTurn)
        let usages = updates.compactMap(usageReport(of:))
        #expect(usages.count == 1)
        #expect(usages.first?.used == chain.tokensIn + chain.tokensOut)
    }

    /// `textReset` discards the collected text as a whole-message
    /// replace on the same message id, never as another chunk (§8.3).
    @Test func textResetSendsAWholeMessageReplaceOnTheSameMessageId() async throws {
        let (execution, recorder) = makeSinkedExecution()
        _ = await execution.drive(
            events: makeEventStream([
                .textDelta("draft"), .textReset, .textDelta("final"),
            ]))
        let updates = await recorder.updates

        let draft = try #require(
            agentMessageChunk(of: updates[0]),
            "expected chunk, replace, chunk; got \(updates)")
        let replace = try #require(
            agentMessageReplace(of: updates[1]),
            "expected chunk, replace, chunk; got \(updates)")
        let final = try #require(
            agentMessageChunk(of: updates[2]),
            "expected chunk, replace, chunk; got \(updates)")
        #expect(replace.messageId == draft.messageId)
        #expect(replace.content == .value([]))
        #expect(final.messageId == draft.messageId)
    }

    /// Tool events project to `tool_call_update` sends in stream order
    /// (§8.4) and do not disturb the text stream: the two text chunks
    /// still share one message id, and the prompt still ends with one
    /// `idle`.
    @Test func toolEventsProjectInOrderWithoutBreakingTheTextStream() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .textDelta("a"),
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .completed, summary: nil, output: nil),
                .textDelta("b"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
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

    /// The usage of every `submissionEnded` is summed and reported one
    /// time, before the idle terminator (§8.1).
    @Test func submissionUsageIsSummedIntoOneUsageUpdate() async throws {
        let (execution, recorder) = makeSinkedExecution()
        _ = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 2, contextFill: .nan)),
                makeSubmissionEnded(TokenUsage(tokensIn: 3, tokensOut: 4, contextFill: 0.5)),
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
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([.textDelta("partial")], throwing: CancellationError()))
        let updates = await recorder.updates

        #expect(reason == .cancelled)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
    }

    // MARK: - The no-output prompt (§8.2, task ^pez780d)

    /// A prompt whose last generate call reached the output token ceiling
    /// ends with the `_truncated` extension stop reason, never with a
    /// bare `end_turn` (task ^bw9qt1z).
    @Test func aPromptThatEndsAtTheTokenCeilingEndsWithTheTruncatedStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 100, tokensOut: 8192, contextFill: .nan,
                        finishReason: .maxTokens))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.truncatedStopReasonValue))
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.truncatedStopReasonValue))
    }

    /// A prompt whose last submission ended inside the reasoning, below the
    /// ceiling, ends with the `_ended_in_reasoning` extension stop reason.
    /// A bare `end_turn` would show a cut prompt as a finished one, and
    /// `_truncated` would say that the ceiling stopped it, which is false.
    @Test func aPromptThatEndsInsideTheReasoningEndsWithTheEndedInReasoningStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 100, tokensOut: 600, contextFill: .nan,
                        finishReason: .endedInsideReasoning))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.endedInReasoningStopReasonValue))
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.endedInReasoningStopReasonValue))
    }

    /// A prompt whose last submission stopped because it repeated itself,
    /// with no recovery left, ends with the `_repeated` extension stop
    /// reason.
    @Test func aPromptThatEndsOnRepeatedLinesEndsWithTheRepeatedStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 100, tokensOut: 2048, contextFill: .nan,
                        finishReason: .repeatedLines))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.repeatedStopReasonValue))
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.repeatedStopReasonValue))
    }

    /// Router's `reasoningTokenLimit` finish reason cuts the prompt with the
    /// `reasoningLimit` stop, and that stop goes on the wire as
    /// `_reasoning_limit` (task ^7fsfw7y).
    @Test func theReasoningTokenLimitFinishReasonCutsWithTheReasoningLimitStop() {
        #expect(PromptExecution.cutStop(for: .reasoningTokenLimit) == .reasoningLimit)
        #expect(PromptExecution.reasoningLimitStopReasonValue == "_reasoning_limit")
    }

    /// A prompt whose last submission reasoned past the reasoning token limit
    /// of the repetition detection, with no recovery left, ends with the
    /// `_reasoning_limit` extension stop reason. `_truncated` would say that
    /// the output token ceiling stopped it, which is false.
    @Test func aPromptThatEndsAtTheReasoningTokenLimitEndsWithTheReasoningLimitStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 100, tokensOut: RepetitionDetection.defaultReasoningTokenLimit,
                        contextFill: .nan, finishReason: .reasoningTokenLimit))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.reasoningLimitStopReasonValue))
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.reasoningLimitStopReasonValue))
    }

    /// Only the LAST generate call decides: a tool-calling prompt that
    /// reached the ceiling in an earlier call, and then completed its
    /// last call, keeps `end_turn`.
    @Test func anEarlierCeilingDoesNotTruncateAPromptWhoseLastCallCompleted() async throws {
        let (execution, _) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 100, tokensOut: 8192, contextFill: .nan,
                        finishReason: .maxTokens)),
                makeSubmissionEnded(
                    TokenUsage(
                        tokensIn: 200, tokensOut: 50, contextFill: .nan,
                        finishReason: .completed)),
            ]))

        #expect(reason == .endTurn)
    }

    /// A completed prompt with no output and a zero-token usage report
    /// ends with the honest `_no_output` extension stop reason, never
    /// with a bare `end_turn`.
    @Test func aZeroTokenPromptWithNoOutputEndsWithTheNoOutputStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan))
            ]))
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.noOutputStopReasonValue))
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.noOutputStopReasonValue))
    }

    /// A prompt that streamed text keeps `end_turn`, also when the usage
    /// report is zero: the text is real output.
    @Test func aZeroTokenPromptWithTextKeepsTheEndTurnStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .textDelta("real output"),
                makeSubmissionEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A prompt that made a tool call keeps `end_turn`, also when the
    /// usage report is zero: the call is real output.
    @Test func aZeroTokenPromptWithAToolCallKeepsTheEndTurnStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .completed, summary: nil, output: nil),
                makeSubmissionEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A prompt that carried an attachment report keeps `end_turn`, also
    /// when the usage report is zero: the report's `tool_call_update`
    /// is real output.
    @Test func aZeroTokenPromptWithAToolCallReportKeepsTheEndTurnStopReason() async throws {
        let report = ToolCallReport(
            tool: "files",
            op: "edit file",
            correlationID: "01SCRIPTEDRUNTOKEN00000000",
            sessionID: ULID.generate(),
            attachments: [
                ToolCallAttachment(schemaName: "note", contentJSON: #"{"note":"kept"}"#)
            ])
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .toolCallReport(report),
                makeSubmissionEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A completed prompt with no usage report keeps `end_turn`: with no
    /// report there is no zero-token evidence, and the prompt must not
    /// invent one.
    @Test func aPromptWithNoUsageReportKeepsTheEndTurnStopReason() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(events: makeEventStream([]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A scripted prompt that plays only `.endPass` makes the live defect
    /// shape on the wire: the Router pass completes with no output and
    /// a zero-token usage delta. The idle terminator carries
    /// `_no_output`, never a bare `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedPromptWithNoOutputEndsIdleWithTheNoOutputStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.endPass])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.noOutputStopReasonValue))
    }

    // MARK: - The repetition stop (§8.2, task ^k51h6bb)

    /// The window of Router's repetition watch in the repetition proof, in
    /// tokens. It is small, so a short script fills it. The scripted
    /// counter gives one token for each character.
    private static let repetitionWindowTokens = 200

    /// How many times the repeating script writes ``repeatedReasoningLines``:
    /// more than one ``repetitionWindowTokens`` window of tokens.
    private static let repeatedCycleCount = 10

    /// The reasoning line the repeating script writes one time.
    private static let newReasoningLine = "First I read the failing test and its fixture.\n"

    /// The reasoning lines the repeating script writes again and again.
    private static let repeatedReasoningLines = [
        "Maybe the alias is resolved in the compiler.\n",
        "Let me look at how the compiler resolves it.\n",
    ]

    /// The project `config.yaml` of the repetition proof: the small window,
    /// and no recovery, so the first repetition stop ends the prompt.
    private static let repetitionConfigYAML = """
        repetition:
          windowTokens: \(repetitionWindowTokens)
          recoveriesPerAnswer: 0
        """

    /// The script of the repetition proof: one new reasoning line, the
    /// repeated lines, and a hold that only a cancel ends. Router's
    /// repetition watch reads the growing reasoning and stops the call.
    private static var repeatingReasoningScript: [ScriptedPassStep] {
        let cycle = repeatedReasoningLines.map { ScriptedPassStep.reasoning($0) }
        let repeated = Array(repeating: cycle, count: repeatedCycleCount).flatMap { $0 }
        return [.reasoning(newReasoningLine)] + repeated + [.hold]
    }

    /// The content of the one segment of a `repeatedPartRemoval` event: for
    /// each cut entry id, the UTF-8 length of its text that the render keeps.
    private struct RepeatedPartCut: Decodable {
        /// The kept UTF-8 length of each cut entry, by entry id.
        let keptUTF8Lengths: [String: Int]
    }

    /// The cut that `event` records, or `nil` when its first segment is not
    /// a structure segment under Router's repeated-part schema name.
    ///
    /// - Parameter event: A recorded `repeatedPartRemoval` event.
    /// - Returns: The decoded cut, or `nil`.
    /// - Throws: When the segment content does not decode.
    private static func repeatedPartCut(in event: TranscriptEvent) throws -> RepeatedPartCut? {
        guard case .structure(_, let schemaName, let contentJSON)? = event.entry?.segments?.first,
            schemaName == ResumeSessionFixture.repeatedPartRemovalSchemaName
        else {
            return nil
        }
        return try JSONDecoder().decode(RepeatedPartCut.self, from: Data(contentJSON.utf8))
    }

    /// Runs one prompt over ``repeatingReasoningScript`` to its end, and
    /// waits until the journal of the session holds the
    /// `repeatedPartRemoval` event and the session accepts a new request.
    ///
    /// - Returns: The fixture, the idle stop reason of the prompt, and the
    ///   recorded events of the session.
    /// - Throws: Whatever the wire calls, the waits or the journal read throw.
    private static func runRepeatingPrompt() async throws -> (
        fixture: ScriptedPromptFixture, stopReason: StopReason?, events: [TranscriptEvent]
    ) {
        let fixture = try await ScriptedPromptFixture.make(
            script: repeatingReasoningScript, label: "PromptExecutionTests-repetition",
            projectConfigYAML: repetitionConfigYAML)
        _ = try await fixture.harness.connection.prompt(makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let root = try ResumeSessionFixture.projectRecordingRoot(of: fixture.cwd)
        try await Poll.until("the journal holds a repeatedPartRemoval event") {
            try ResumeSessionFixture.recordedEvents(under: root, sessionId: fixture.sessionId)
                .contains { $0.kind == .repeatedPartRemoval }
        }
        try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        let events = try ResumeSessionFixture.recordedEvents(under: root, sessionId: fixture.sessionId)
        return (fixture, ScriptedPromptFixture.idleStopReason(in: updates), events)
    }

    /// A prompt whose reasoning repeats its lines ends with the `_repeated`
    /// stop reason. Router's repetition watch stops the call, and the
    /// session records a `repeatedPartRemoval` event in its journal: Router's
    /// text, and a cut of the one reasoning entry that keeps each new
    /// reasoning line one time. A resume of that session replays each
    /// message that the client saw live, with its live id, and sends no
    /// message for the `repeatedPartRemoval` event.
    @Test(.timeLimit(.minutes(1)))
    func aRepetitionStopRecordsARepeatedPartRemovalThatAResumeReplays() async throws {
        let (fixture, stopReason, events) = try await Self.runRepeatingPrompt()
        #expect(stopReason == .unknown(PromptExecution.repeatedStopReasonValue))

        let removal = try #require(events.first { $0.kind == .repeatedPartRemoval })
        #expect(removal.text?.hasPrefix(ResumeSessionFixture.repeatedPartRemovalText) == true)
        let cut = try #require(try Self.repeatedPartCut(in: removal))
        let newLines = Self.newReasoningLine + Self.repeatedReasoningLines.joined()
        #expect(Array(cut.keptUTF8Lengths.values) == [newLines.utf8.count])

        await fixture.harness.agent.markSessionClosed(fixture.sessionId)
        let live = ReplayedMessage.live(in: await fixture.collector.updates.map(\.update))
        let countBefore = await fixture.collector.updates.count
        _ = try await fixture.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId,
                replayFrom: .start(ReplayFromStart())))
        let replayUpdates = Array(await fixture.collector.updates.dropFirst(countBefore)).map(\.update)
        #expect(!live.isEmpty)
        #expect(ReplayedMessage.replayed(in: replayUpdates) == live)
        await fixture.close()
    }

    // MARK: - The stalled generation (§8.2, task ^s0bw5cv)

    /// Makes one stall report of the shape Router emits on a streaming
    /// request.
    ///
    /// - Parameters:
    ///   - withoutProgress: How long the generation has gone with no
    ///     observable progress. It also stands as the time in flight,
    ///     which no assertion reads.
    ///   - fragments: How many fragments arrived before the stall.
    /// - Returns: The report.
    private static func makeStall(
        withoutProgress: Duration, fragments: Int
    ) -> GenerationStall {
        GenerationStall(
            timeWithoutProgress: withoutProgress,
            timeInFlight: withoutProgress,
            visibility: .fragments(observed: fragments), lastProgress: .callStart)
    }

    /// A generation that has made no fragment for the whole bound ends
    /// the prompt with the honest `_stalled` extension stop reason.
    ///
    /// The stream never finishes, which is the shape of the defect: a
    /// model the loader cannot drive reports a stall on each interval
    /// and yields nothing else, so the guard is the only way out of the
    /// drive loop. The time limit states the bound of the test, so a
    /// hang fails it rather than running to the suite ceiling.
    @Test(.timeLimit(.minutes(1)))
    func aGenerationWithNoFragmentPastTheBoundEndsThePromptAsStalled() async throws {
        let stall = Self.makeStall(
            withoutProgress: PromptExecution.stalledGenerationBound, fragments: 0)
        let events = AsyncThrowingStream<SessionEvent, Error> { continuation in
            continuation.yield(.generationStalled(stall))
        }
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(events: events)
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.stalledStopReasonValue))
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(
            ScriptedPromptFixture.idleStopReason(in: updates)
                == .unknown(PromptExecution.stalledStopReasonValue))
    }

    /// A stall shorter than the bound is a report and not a bound: the
    /// generation continues, and the prompt ends on its own events.
    @Test(.timeLimit(.minutes(1)))
    func aStallShorterThanTheBoundDoesNotEndThePrompt() async throws {
        let stall = Self.makeStall(
            withoutProgress: PromptExecution.stalledGenerationBound - .seconds(1), fragments: 0)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .generationStalled(stall),
                .textDelta("late, and real"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A stall past the bound on a generation that already made a
    /// fragment does not end the prompt: a slow decode is not a model
    /// that cannot generate.
    @Test(.timeLimit(.minutes(1)))
    func aStallPastTheBoundAfterAFragmentDoesNotEndThePrompt() async throws {
        let stall = Self.makeStall(
            withoutProgress: PromptExecution.stalledGenerationBound, fragments: 1)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .textDelta("a first fragment"),
                .generationStalled(stall),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// A stall past the bound after the prompt made a tool call does not
    /// end the prompt. A tool call is observable output, and the fragment
    /// count of the report does not count it, so a report of zero
    /// fragments after a tool call is never a model that cannot generate.
    @Test(.timeLimit(.minutes(1)))
    func aStallPastTheBoundAfterAToolCallDoesNotEndThePrompt() async throws {
        let stall = Self.makeStall(
            withoutProgress: PromptExecution.stalledGenerationBound, fragments: 0)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .generationStalled(stall),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    /// The seconds of one reporting interval of the Router stall watch
    /// in the synthetic stream below. The value is shorter than the
    /// bound, and no assertion reads it.
    private static let stallReportIntervalSeconds = 60

    /// A request that waited for a place in the model queue for longer
    /// than the bound does not end with `_stalled`.
    ///
    /// The Router does not count a queue wait as time without progress
    /// (Router task ^ake8sax). It sends `submissionQueued`, then
    /// `submissionStarted` when the submission gets its place. A stall
    /// report after the wait has a `timeInFlight` that includes the wait,
    /// and a `timeWithoutProgress` that does not. The guard must read
    /// only `timeWithoutProgress`, thus the request continues to its
    /// text and its usage, and it ends with `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func queueWaitNeverEndsTheRequestAsStalled() async throws {
        let queueWait = PromptExecution.stalledGenerationBound + .seconds(1)
        let interval = Duration.seconds(Self.stallReportIntervalSeconds)
        let stallAfterTheWait = GenerationStall(
            timeWithoutProgress: interval,
            timeInFlight: queueWait + interval,
            visibility: .fragments(observed: 0), lastProgress: .callStart)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                makeSubmissionQueued(),
                makeSubmissionStarted(),
                .generationStalled(stallAfterTheWait),
                .textDelta("the answer, after the wait"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// The seconds a real build task took to reach its FIRST observable
    /// output, on the shipped standard model (task ^ec8hn3z).
    ///
    /// Measured on 2026-09-08 with `mlx-community/Qwen3.8-27B-mxfp4`:
    /// the tier-4 `greet` prompt, sent through `acp-agent run`, made its
    /// first tool call 555 seconds after the prompt, and then wrote the
    /// three files, ran pytest green and printed the expected line. The
    /// prompt thus makes no observable output at all for the first nine
    /// minutes.
    private static let measuredSecondsToFirstOutput = 555

    /// A generation that has made no fragment for as long as a real
    /// build task takes to reach its first output does NOT end the prompt.
    ///
    /// The stall reports of that measured run said `0 fragments` for the
    /// whole prompt, while `runCode` and shell calls were completing, so a
    /// fragment count of zero never proves that the model made nothing.
    /// A bound under the measured time therefore ends a healthy prompt.
    @Test(.timeLimit(.minutes(1)))
    func aStallAtTheMeasuredTimeToFirstOutputDoesNotEndThePrompt() async throws {
        let stall = Self.makeStall(
            withoutProgress: .seconds(Self.measuredSecondsToFirstOutput), fragments: 0)
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(
            events: makeEventStream([
                .generationStalled(stall),
                .textDelta("the first output, nine minutes in"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        _ = await recorder.updates

        #expect(reason == .endTurn)
    }

    // MARK: - The requires_action pairing (§8.2)

    /// Checks that the owner sent two updates: `requires_action` first,
    /// and then `running`.
    ///
    /// - Parameter updates: The updates the owner sent, in send order.
    private static func expectRequiresActionThenRunning(in updates: [SessionUpdate]) {
        #expect(updates.count == 2, "expected requires_action then running, got \(updates)")
        #expect(
            isRequiresActionState(updates.first),
            "expected requires_action then running, got \(updates)")
        #expect(
            isRunningState(updates.dropFirst().first),
            "expected requires_action then running, got \(updates)")
    }

    /// `awaitingUser` sends `requires_action`, runs the body, and returns
    /// to `running` with the body's value.
    @Test(.timeLimit(.minutes(1)))
    func awaitingUserPairsRequiresActionWithRunning() async throws {
        let recorder = SinkRecorder()
        let owner = PromptStateOwner(send: { update in await recorder.append(update) })

        let answer = await owner.awaitingUser { "the answer" }
        let updates = await recorder.updates

        #expect(answer == "the answer")
        Self.expectRequiresActionThenRunning(in: updates)
    }

    /// A body that throws still returns the state to `running`.
    @Test(.timeLimit(.minutes(1)))
    func awaitingUserReturnsToRunningWhenTheBodyThrows() async throws {
        let recorder = SinkRecorder()
        let owner = PromptStateOwner(send: { update in await recorder.append(update) })

        await #expect(throws: ScriptedModelError.self) {
            _ = try await owner.awaitingUser { () -> String in
                throw ScriptedModelError.unknownTool("x")
            }
        }
        let updates = await recorder.updates

        Self.expectRequiresActionThenRunning(in: updates)
    }

    // MARK: - A waiting session holds no model (Router generation-queue.md 5.5)
    //
    // The two sessions of each proof use one queued scripted model, thus one
    // generation queue. Session A waits in a background run: an elicitation
    // from a `runCode` snippet, or a shell command. `runCode` holds the model
    // only for its inline grace, and a shell command gives its pending answer
    // at once. Then the run continues in the background, and the submission
    // of A ends. The prompt of B must then get the model and end, while A
    // still waits.

    /// The snippet of the elicitation proof: one question to the person.
    private static let elicitingSnippet = #"return await elicit("Which colour do you want?");"#

    /// The name of the named pipe that the shell command of the tool-body
    /// proof reads. Nothing writes the pipe, thus the read waits until the
    /// session close stops it.
    private static let pipeName = "wait.fifo"

    /// The snippet of the tool-body proof: one shell read of the named pipe.
    private static let waitingSnippet =
        #"return await tools.shell.execute({ command: "cat \#(pipeName)" });"#

    /// The marker of the prompt of session A in the tool-body proof. Its
    /// pass starts the shell read.
    private static let waitingMarker = "Read the pipe"

    /// The text that the pass of session B plays in the tool-body proof.
    private static let answerText = "answered"

    /// Session A waits in an elicitation that the client does not answer.
    /// Session B prompts on the same model, and its prompt ends with
    /// `end_turn` while A still waits.
    @Test(.timeLimit(.minutes(1)))
    func aSessionInAnElicitationHoldsNoModel() async throws {
        let fixture = try await QueuedScriptedFixture.make(
            script: ScriptedPromptFixture.makeToolPromptScript(code: Self.elicitingSnippet),
            label: "PromptExecutionTests-elicitation")
        try await fixture.prompt(fixture.firstSessionId, text: Self.promptText)
        let client = fixture.base.harness.client
        _ = try await ElicitationPoll.firstPendingElicitation(
            of: fixture.firstSessionId, on: client)

        try await fixture.prompt(fixture.secondSessionId, text: Self.promptText)
        let questionOfB = try await ElicitationPoll.firstPendingElicitation(
            of: fixture.secondSessionId, on: client)
        await MainActor.run { client.acceptElicitation(questionOfB.id) }
        let updatesOfB = try await fixture.waitForIdle(of: fixture.secondSessionId)
        let pendingOfA = await fixture.pendingElicitations(of: fixture.firstSessionId)
        let updatesOfA = await fixture.updates(of: fixture.firstSessionId)
        try await fixture.closeSessions()

        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfB) == .endTurn)
        #expect(pendingOfA.count == 1)
        #expect(ScriptedPromptFixture.idleCount(in: updatesOfA) == 0)
    }

    /// Session A waits in a tool body: a shell read of a named pipe that
    /// nothing writes. Session B prompts on the same model, and its prompt
    /// ends with `end_turn` while the tool body of A still waits.
    ///
    /// The prompt of A waits for its background read (task ^64pav2a), so it
    /// sends no `idle`. B starts no read, so its prompt ends after its own
    /// answer. The close of each session at the end stops the read of A and
    /// ends the prompt of A.
    @Test(.timeLimit(.minutes(1)))
    func aSessionInAToolBodyHoldsNoModel() async throws {
        let fixture = try await QueuedScriptedFixture.make(
            script: [
                .onPrompt(
                    containing: Self.waitingMarker,
                    play: try ScriptedPromptFixture.makeToolPromptScript(code: Self.waitingSnippet)),
                .textDelta(Self.answerText),
                .endPass,
            ],
            label: "PromptExecutionTests-tool-body",
            workingDirectory: try NamedPipe.makeDirectory(
                holding: Self.pipeName, label: "PromptExecutionTests-pipe-repo"))
        try await fixture.prompt(fixture.firstSessionId, text: Self.waitingMarker)
        let counter = fixture.passCounter
        try await Poll.until("the pass of session A starts") { counter.startedCount == 1 }

        try await fixture.prompt(fixture.secondSessionId, text: Self.promptText)
        let updatesOfB = try await fixture.waitForIdle(of: fixture.secondSessionId)
        let updatesOfA = await fixture.updates(of: fixture.firstSessionId)
        try await fixture.closeSessions()

        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfB) == .endTurn)
        #expect(ScriptedPromptFixture.idleCount(in: updatesOfA) == 0)
    }

    // MARK: - The unknown-id policy (§10.1)

    /// An unknown `sessionId` answers `-32602` with the id in `data`,
    /// and sends no `session/update`.
    @Test(.timeLimit(.minutes(1)))
    func anUnknownSessionIdAnswersInvalidParamsAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.endPass])
        let bogus = SessionId(rawValue: syntheticSessionIdValue)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: bogus))
            Issue.record("expected invalid params for the unknown id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(Self.dataField("sessionId", of: error) == bogus.rawValue)
        }

        #expect(promptUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }

    /// A known but closed session answers `-32602` with the resume
    /// hint, because a closed session is resumable, not promptable.
    @Test(.timeLimit(.minutes(1)))
    func aClosedSessionIdAnswersInvalidParamsWithTheResumeHint() async throws {
        let fixture = try await Self.makeFixture(script: [.endPass])
        await fixture.harness.agent.markSessionClosed(fixture.sessionId)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: fixture.sessionId))
            Issue.record("expected invalid params for the closed id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(Self.dataField("reason", of: error) == "closed; resume it first")
        }

        #expect(promptUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }

    // MARK: - The title and the index timing (§9)

    /// `sessions.jsonl` is absent before the first prompt, gains the
    /// session's record with a one-line title at the first prompt, and
    /// gains nothing more at the second prompt.
    @Test(.timeLimit(.minutes(1)))
    func theFirstPromptWritesTheIndexRecordWithAOneLineTitle() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("done"), .endPass])
        let index = try await Self.sessionIndex(of: fixture)
        #expect(try index.read().records.isEmpty)

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let firstPrompt = try await ScriptedPromptFixture.waitForIdle(fixture.collector)

        let records = try index.read().records
        #expect(records.count == 1)
        #expect(records.first?.sessionId == fixture.sessionId.rawValue)
        #expect(records.first?.title == Self.promptTitleLine)
        #expect(records.first?.cwd == fixture.cwd.path)

        let titles = firstPrompt.compactMap { notification -> PatchField<String>? in
            if case .sessionInfoUpdate(let info) = notification.update { return info.title }
            return nil
        }
        #expect(titles == [.value(Self.promptTitleLine)])

        try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId, text: "a second prompt"))
        let secondPrompt = try await ScriptedPromptFixture.waitForIdle(fixture.collector, count: 2)
        await fixture.close()

        #expect(try index.read().records.count == 1)
        #expect(secondPrompt.count { $0.update.kind == .sessionInfoUpdate } == 1)
    }
}
