import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Cancellation (plan.md §8.6, §10.1): the `session/cancel`
/// notification, the two endings of a cancelled turn, the strict
/// `idle(cancelled)` terminator, and the no-op cancels for an idle,
/// unknown, or closed session.
@Suite struct CancellationTests {
    // MARK: - Constants

    /// The prompt text of the wire tests.
    private static let promptText = "Run one long turn"

    /// The SDK tool-call id the synthetic tool events carry.
    private static let toolCallId = "call-1"

    /// The kind sequence of one uncancelled scripted turn: the echo,
    /// the first-activity info update, `running`, one chunk, and the
    /// `idle` terminator. The no-op cancel tests compare against it, so
    /// a cancel that leaks an update or a state change is visible.
    private static let uncancelledTurnKinds: [SessionUpdateKind] = [
        .userMessage, .sessionInfoUpdate, .stateUpdate,
        .agentMessageChunk, .stateUpdate,
    ]

    // MARK: - Harness

    /// Wires the shared fixture with this suite's directory label.
    ///
    /// - Parameter script: The steps the model plays on every turn.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        script: [ScriptedTurnStep]
    ) async throws -> ScriptedTurnFixture {
        try await ScriptedTurnFixture.make(script: script, label: "CancellationTests")
    }

    /// The prompt request with one text block and this suite's text.
    ///
    /// - Parameter sessionId: The session to prompt.
    /// - Returns: The request.
    private static func makePromptRequest(sessionId: SessionId) -> PromptRequest {
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText)
    }

    // MARK: - The throw ending, and the strict terminator (§8.6)

    /// A `session/cancel` during a long-running turn ends the turn as
    /// `idle` with `cancelled` — the held turn raises
    /// `CancellationError`, which maps to `cancelled`, never to a
    /// JSON-RPC error and never to `refusal` — and the idle update is
    /// strictly the last update: nothing of any kind arrives after it.
    @Test(.timeLimit(.minutes(1)))
    func cancellingALongRunningTurnMakesIdleCancelledTheLastUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("working"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        // The agent clears the finished turn after the idle went out,
        // so the collector holds everything the turn sent once the
        // session is available again.
        try await ScriptedTurnFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        let updates = await fixture.collector.updates
        await fixture.close()

        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        let last = try #require(updates.last)
        #expect(
            isIdleState(last.update),
            "expected idle(cancelled) as the strict terminator, got \(updates)")
    }

    // MARK: - The normal-completion ending (§8.6)

    /// A turn that ignores the cancellation and completes normally with
    /// a real answer still ends `idle` with `cancelled`, never
    /// `end_turn`: the client asked to cancel, and the recorded request
    /// wins over the stream's clean finish.
    @Test func aTurnThatIgnoresCancellationStillEndsIdleCancelled() async throws {
        let (turn, recorder) = makeSinkedTurn()
        await turn.turnState.noteCancelRequested()
        let reason = await turn.drive(
            events: makeEventStream([
                .textDelta("a full answer"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .cancelled)
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        let idle = try #require(
            idleState(of: updates.last), "expected idle as the terminator, got \(updates)")
        #expect(idle.stopReason == .cancelled)
    }

    /// The updates that follow a cancel go out before the idle
    /// terminator: a terminal tool status that arrives after the cancel
    /// request is still sent, and it never holds the idle update.
    @Test func postCancelUpdatesGoOutBeforeTheIdleTerminator() async throws {
        let (turn, recorder) = makeSinkedTurn()
        await turn.turnState.noteCancelRequested()
        _ = await turn.drive(
            events: makeEventStream([
                .toolCall(id: Self.toolCallId, name: "shell", argumentsJSON: "{}"),
                .toolStatus(id: Self.toolCallId, status: .completed, summary: "done", output: nil),
            ]))
        let updates = await recorder.updates

        #expect(updates.map(\.kind) == [.toolCallUpdate, .toolCallUpdate, .stateUpdate])
        let idle = try #require(
            idleState(of: updates.last),
            "expected idle after the tool updates, got \(updates)")
        #expect(idle.stopReason == .cancelled)
    }

    // MARK: - A request that waits for the model queue (§8.6, §10.1)
    //
    // The two sessions of each proof use one queued scripted model, thus one
    // generation queue. Session A holds its pass until the test releases the
    // hold. The prompt of session B thus waits for a queue place. A cancel or
    // a close of B must end B at once, and must not wait for A.

    /// Wires two sessions over one queued model, starts a held pass on
    /// session A, and starts a prompt on session B that waits for a queue
    /// place.
    ///
    /// - Parameter hold: The hold of each pass.
    /// - Returns: The fixture, with A held and B in the queue.
    /// - Throws: Whatever the construction, the wire or the wait throws.
    private static func startPromptThatWaitsForTheQueue(
        hold: ScriptedHold
    ) async throws -> QueuedScriptedFixture {
        let fixture = try await QueuedScriptedFixture.make(
            script: [.holdUntilReleased(hold), .textDelta("released"), .endTurn],
            label: "CancellationTests-queue")
        let counter = fixture.passCounter
        try await fixture.prompt(fixture.firstSessionId, text: promptText)
        try await Poll.until("the pass of session A is held") { counter.runningCount == 1 }
        try await fixture.prompt(fixture.secondSessionId, text: promptText)
        try await Poll.until("the prompt of session B waits for a queue place") {
            await counter.waitingCount == 1
        }
        return fixture
    }

    /// A `session/cancel` for a prompt that waits for a place in the model
    /// queue ends it with `idle(cancelled)` while the other session still
    /// holds the model. After the release, the holding session completes,
    /// and a new prompt on the cancelled session completes too.
    @Test(.timeLimit(.minutes(1)))
    func cancelEndsARequestThatWaitsForTheModelQueue() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startPromptThatWaitsForTheQueue(hold: hold)
        let sessionA = fixture.firstSessionId
        let sessionB = fixture.secondSessionId

        try await fixture.base.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: sessionB))
        let cancelledUpdatesOfB = try await fixture.waitForIdle(of: sessionB)
        let updatesOfAWhileHeld = await fixture.updates(of: sessionA)

        hold.release()
        let updatesOfA = try await fixture.waitForIdle(of: sessionA)
        try await ScriptedTurnFixture.waitForAvailability(fixture.base.harness.agent, sessionB)
        try await fixture.prompt(sessionB, text: Self.promptText)
        let updatesOfB = try await fixture.waitForIdle(of: sessionB, count: 2)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: cancelledUpdatesOfB) == .cancelled)
        #expect(ScriptedTurnFixture.idleCount(in: updatesOfAWhileHeld) == 0)
        #expect(ScriptedTurnFixture.idleStopReason(in: updatesOfA) == .endTurn)
        #expect(idleState(of: updatesOfB.last?.update)?.stopReason == .endTurn)
    }

    /// A `session/close` for a session whose prompt waits for a place in the
    /// model queue answers after the `idle(cancelled)` of that prompt, while
    /// the other session still holds the model. After the release, the
    /// holding session completes.
    @Test(.timeLimit(.minutes(1)))
    func closeEndsARequestThatWaitsForTheModelQueue() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startPromptThatWaitsForTheQueue(hold: hold)
        let sessionA = fixture.firstSessionId
        let sessionB = fixture.secondSessionId

        _ = try await fixture.base.harness.connection.closeSession(
            CloseSessionRequest(sessionId: sessionB))
        let updatesOfB = await fixture.updates(of: sessionB)
        let updatesOfAWhileHeld = await fixture.updates(of: sessionA)

        hold.release()
        let updatesOfA = try await fixture.waitForIdle(of: sessionA)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updatesOfB) == .cancelled)
        #expect(ScriptedTurnFixture.idleCount(in: updatesOfAWhileHeld) == 0)
        #expect(ScriptedTurnFixture.idleStopReason(in: updatesOfA) == .endTurn)
    }

    // MARK: - The no-op cancels (§8.6, §10.1)

    /// A cancel of an idle session is a no-op: no error, no update, and
    /// no state change. A later turn runs untouched and ends with
    /// `end_turn`, so the ignored cancel did not leak into it.
    @Test(.timeLimit(.minutes(1)))
    func cancelOfAnIdleSessionIsANoOpWithNoStateChange() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("hello"), .endTurn])
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(turnUpdates(in: updates).map(\.update.kind) == Self.uncancelledTurnKinds)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// A cancel with an unknown `sessionId` is logged and ignored: it
    /// is a notification, so there is no error, and no `session/update`
    /// of any kind goes out for it.
    @Test(.timeLimit(.minutes(1)))
    func cancelOfAnUnknownSessionIdIsIgnoredAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("hello"), .endTurn])
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: SessionId(rawValue: syntheticSessionIdValue)))

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(turnUpdates(in: updates).map(\.update.kind) == Self.uncancelledTurnKinds)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// A cancel for a closed session is logged and ignored: no error
    /// and no `session/update`. A round trip through `session/new`
    /// proves the notification was consumed before the assertion reads
    /// the collector.
    @Test(.timeLimit(.minutes(1)))
    func cancelOfAClosedSessionIsIgnoredAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        await fixture.harness.agent.markSessionClosed(fixture.sessionId)
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))

        _ = try await fixture.harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
        #expect(turnUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }
}
