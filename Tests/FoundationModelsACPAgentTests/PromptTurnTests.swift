import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The prompt turn (plan.md §8.1–§8.3, §10.1): the acknowledge-then-notify
/// order, the `user_message` echo, the turn-state machine, the stop-reason
/// mapping, and the first-activity index record.
@Suite struct PromptTurnTests {
    // MARK: - Constants

    /// The pause between two looks at the collector.
    private static let pollInterval: Swift.Duration = .milliseconds(20)

    /// The number of looks a wait makes before it records a failure.
    private static let maxPollAttempts = 500

    /// The first prompt line. It becomes the session title.
    private static let promptTitleLine = "Say hello to the tests"

    /// The prompt text of the wire tests: two lines, so the cut to a
    /// one-line title is observable.
    private static let promptText = "Say hello to the tests\nwith a second line"

    /// A well-formed ULID that names no live session.
    private static let unknownSessionIdValue = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    // MARK: - Harness

    /// One wired prompt-turn fixture: a scripted agent, a recording
    /// harness, an initialized wire, and one new session in `cwd`.
    private struct Fixture {
        /// The wired harness.
        let harness: AgentClientHarness

        /// The collector of the raw update sequence.
        let collector: UpdateCollector

        /// The id of the one open session.
        let sessionId: SessionId

        /// The session working directory.
        let cwd: URL

        /// Closes the harness wire.
        func close() async {
            await harness.close()
        }
    }

    /// Wires a scripted agent, completes `initialize`, and opens one
    /// session.
    ///
    /// - Parameter script: The steps the model plays on every turn.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(script: [ScriptedTurnStep]) async throws -> Fixture {
        let userDirectory = makeResolvedDirectory(label: "PromptTurnTests-user")
        let cwd = makeResolvedDirectory(label: "PromptTurnTests-repo")
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "PromptTurnTests-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "PromptTurnTests-recordings"),
            userDirectory: userDirectory,
            loader: makeScriptedModelLoader(script: script))
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let response = try await harness.connection.newSession(
            NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: cwd.path))))
        let collector = try #require(harness.collector)
        return Fixture(
            harness: harness, collector: collector, sessionId: response.sessionId, cwd: cwd)
    }

    /// The prompt request with one text block.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - text: The text of the one block.
    /// - Returns: The request.
    private static func makePromptRequest(
        sessionId: SessionId, text: String = promptText
    ) -> PromptRequest {
        PromptRequest(prompt: [.text(TextContent(text: text))], sessionId: sessionId)
    }

    /// The index of the fixture session's recording root.
    ///
    /// - Parameter fixture: The fixture whose session is open.
    /// - Returns: The `sessions.jsonl` index.
    /// - Throws: When the session is not in the agent's table.
    private static func sessionIndex(of fixture: Fixture) async throws -> SessionIndex {
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        return SessionIndex(root: entry.transcriptDirectory.deletingLastPathComponent())
    }

    // MARK: - Waits

    /// Polls the collector until `condition` accepts the collected
    /// sequence, then returns that sequence.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - label: What the wait is for, named in the failure.
    ///   - condition: The acceptance test over the collected sequence.
    /// - Returns: The first accepted sequence, or the final look.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForUpdates(
        of collector: UpdateCollector,
        toReach label: String,
        _ condition: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
    ) async throws -> [UpdateSessionNotification] {
        for _ in 0..<maxPollAttempts {
            let updates = await collector.updates
            if condition(updates) {
                return updates
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("the collector never reached: \(label)")
        return await collector.updates
    }

    /// Waits until the collector holds `count` idle state updates.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - count: The number of turn ends to wait for.
    /// - Returns: The collected sequence.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForIdle(
        _ collector: UpdateCollector, count: Int = 1
    ) async throws -> [UpdateSessionNotification] {
        try await waitForUpdates(of: collector, toReach: "\(count) idle update(s)") { updates in
            idleCount(in: updates) >= count
        }
    }

    /// Waits for the running state update that starts a turn.
    ///
    /// - Parameter collector: The collector to poll.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForRunning(_ collector: UpdateCollector) async throws {
        _ = try await waitForUpdates(of: collector, toReach: "a running update") { updates in
            updates.contains { notification in
                if case .stateUpdate(.running) = notification.update { return true }
                return false
            }
        }
    }

    /// Polls the agent until the session accepts a new prompt again.
    /// The idle notification goes out before the agent clears the turn,
    /// so a follow-up prompt waits here first.
    ///
    /// - Parameters:
    ///   - agent: The agent under test.
    ///   - sessionId: The session to watch.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForAvailability(
        _ agent: RoutedACPAgent, _ sessionId: SessionId
    ) async throws {
        for _ in 0..<maxPollAttempts {
            if await agent.sessions[sessionId]?.availability == .idle {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("the session never returned to idle availability")
    }

    // MARK: - Readers

    /// The number of idle state updates in the sequence.
    private static func idleCount(in updates: [UpdateSessionNotification]) -> Int {
        updates.count { notification in
            if case .stateUpdate(.idle) = notification.update { return true }
            return false
        }
    }

    /// The stop reason of the first idle state update, or `nil`.
    private static func idleStopReason(in updates: [UpdateSessionNotification]) -> StopReason? {
        for notification in updates {
            if case .stateUpdate(.idle(let idle)) = notification.update {
                return idle.stopReason
            }
        }
        return nil
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
        let updates = try await Self.waitForIdle(fixture.collector)
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
        #expect(Self.idleCount(in: updates) == 1)
        #expect(Self.idleStopReason(in: updates) == .endTurn)
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
        try await Self.waitForRunning(fixture.collector)

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
        let updates = try await Self.waitForIdle(fixture.collector)
        _ = try await first.value
        await fixture.close()

        #expect(Self.idleCount(in: updates) == 1)
        #expect(Self.idleStopReason(in: updates) == .cancelled)
        #expect(updates.count { $0.update.kind == .userMessage } == 1)
    }

    // MARK: - The stop-reason matrix (§8.2)

    /// A guardrail refusal ends the turn as `idle` with `refusal`.
    @Test(.timeLimit(.minutes(1)))
    func aGuardrailRefusalEndsTheTurnWithTheRefusalStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.guardrailViolation)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await Self.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(Self.idleStopReason(in: updates) == .refusal)
    }

    /// A context overflow ends the turn as `idle` with `max_tokens`.
    @Test(.timeLimit(.minutes(1)))
    func aContextOverflowEndsTheTurnWithTheMaxTokensStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.fail(.exceededContextWindow)])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await Self.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(Self.idleStopReason(in: updates) == .maxTokens)
    }

    /// A `session/cancel` during a held turn surfaces as `idle` with
    /// `cancelled`, not as an error (§8.6).
    @Test(.timeLimit(.minutes(1)))
    func aCancelledTurnEndsIdleWithTheCancelledStopReason() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("thinking"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await Self.waitForRunning(fixture.collector)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        let updates = try await Self.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(Self.idleCount(in: updates) == 1)
        #expect(Self.idleStopReason(in: updates) == .cancelled)
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

    /// A sink that collects every update a turn sends.
    private actor SinkRecorder {
        /// The collected updates, in send order.
        private(set) var updates: [SessionUpdate] = []

        /// Appends one update.
        ///
        /// - Parameter update: The update to record.
        func append(_ update: SessionUpdate) {
            updates.append(update)
        }
    }

    /// Makes a turn over a recording sink. The synthetic stream tests
    /// drive `drive(events:)` directly and never touch a session.
    private static func makeSinkedTurn() -> (turn: PromptTurn, recorder: SinkRecorder) {
        let recorder = SinkRecorder()
        let send: SessionUpdateSink = { update in await recorder.append(update) }
        let turn = PromptTurn(
            sessionId: SessionId(rawValue: unknownSessionIdValue),
            promptBlocks: [],
            turnState: TurnStateOwner(send: send),
            send: send,
            firstActivity: nil)
        return (turn, recorder)
    }

    /// Makes a finished synthetic stream of `events`.
    ///
    /// - Parameters:
    ///   - events: The events to yield, in order.
    ///   - error: The terminal error, or `nil` for a clean finish.
    /// - Returns: The stream.
    private static func makeEventStream(
        _ events: [SessionEvent], throwing error: (any Error)? = nil
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish(throwing: error)
        }
    }

    /// The number of idle state updates in a raw update sequence.
    private static func idleCount(in updates: [SessionUpdate]) -> Int {
        updates.count { update in
            if case .stateUpdate(.idle) = update { return true }
            return false
        }
    }

    /// A retry turn carries two `turnEnded` events; the turn still ends
    /// with exactly one `idle`, keyed on stream completion (§8.1).
    @Test func aRetryTurnSendsTwoTurnEndedAndExactlyOneIdle() async throws {
        let (turn, recorder) = Self.makeSinkedTurn()
        let reason = await turn.drive(
            events: Self.makeEventStream([
                .textDelta("first attempt"),
                .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 2, contextFill: .nan)),
                .textReset,
                .textDelta("second attempt"),
                .turnEnded(TokenUsage(tokensIn: 3, tokensOut: 4, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(Self.idleCount(in: updates) == 1)
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
        let (turn, recorder) = Self.makeSinkedTurn()
        _ = await turn.drive(
            events: Self.makeEventStream([
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

    /// Tool events pass the default arm without breaking the §8.1 order;
    /// their wire mapping is the §8.4 projection task.
    @Test func toolEventsPassTheDefaultArmWithoutBreakingTheOrder() async throws {
        let (turn, recorder) = Self.makeSinkedTurn()
        let reason = await turn.drive(
            events: Self.makeEventStream([
                .textDelta("a"),
                .toolCall(id: "call-1", name: "x", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .completed, summary: nil, output: nil),
                .textDelta("b"),
                .turnEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .endTurn)
        #expect(updates.map(\.kind) == [.agentMessageChunk, .agentMessageChunk, .stateUpdate])
    }

    /// The usage of every `turnEnded` is summed and reported one time,
    /// before the idle terminator (§8.1).
    @Test func turnEndedUsageIsSummedIntoOneUsageUpdate() async throws {
        let (turn, recorder) = Self.makeSinkedTurn()
        _ = await turn.drive(
            events: Self.makeEventStream([
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
        let (turn, recorder) = Self.makeSinkedTurn()
        let reason = await turn.drive(
            events: Self.makeEventStream([.textDelta("partial")], throwing: CancellationError()))
        let updates = await recorder.updates

        #expect(reason == .cancelled)
        #expect(Self.idleCount(in: updates) == 1)
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
        let bogus = SessionId(rawValue: Self.unknownSessionIdValue)

        do {
            _ = try await fixture.harness.connection.prompt(
                Self.makePromptRequest(sessionId: bogus))
            Issue.record("expected invalid params for the unknown id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(Self.dataField("sessionId", of: error) == bogus.rawValue)
        }

        #expect(await fixture.collector.updates.isEmpty)
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

        #expect(await fixture.collector.updates.isEmpty)
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
        let firstTurn = try await Self.waitForIdle(fixture.collector)

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

        try await Self.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId, text: "a second prompt"))
        let secondTurn = try await Self.waitForIdle(fixture.collector, count: 2)
        await fixture.close()

        #expect(try index.read().records.count == 1)
        #expect(secondTurn.count { $0.update.kind == .sessionInfoUpdate } == 1)
    }
}
