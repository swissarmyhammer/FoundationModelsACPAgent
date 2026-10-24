import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Cancellation: the `session/cancel` notification, the two endings of a
/// cancelled prompt, the strict `idle(cancelled)` terminator, and the
/// no-op cancels for an idle, unknown, or closed session.
///
/// A cancelled prompt usually throws a `CancellationError`, but model
/// work that does not check for cancellation runs to completion. The
/// prompt owner handles both endings. Each update goes before the
/// `idle(cancelled)` update, and no update goes after it.
@Suite(.closesHarnesses) struct CancellationTests {
    // MARK: - Constants

    /// The prompt text of the wire tests.
    private static let promptText = "Run one long prompt"

    /// The SDK tool-call id the synthetic tool events carry.
    private static let toolCallId = "call-1"

    /// The kind sequence of one uncancelled scripted prompt: the echo,
    /// the title info update, `running`, one chunk, and the
    /// `idle` terminator. The no-op cancel tests compare against it, so
    /// a cancel that leaks an update or a state change is visible.
    private static let uncancelledPromptKinds: [SessionUpdateKind] = [
        .userMessage, .sessionInfoUpdate, .stateUpdate,
        .agentMessageChunk, .stateUpdate,
    ]

    // MARK: - Harness

    /// Wires the shared fixture with this suite's directory label.
    ///
    /// - Parameter script: The steps the model plays on every pass.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        script: [ScriptedPassStep]
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(script: script, label: "CancellationTests")
    }

    /// The prompt request with one text block and this suite's text.
    ///
    /// - Parameter sessionId: The session to prompt.
    /// - Returns: The request.
    private static func makePromptRequest(sessionId: SessionId) -> PromptRequest {
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText)
    }

    // MARK: - The throw ending, and the strict terminator

    /// A `session/cancel` during a long-running prompt ends the prompt as
    /// `idle` with `cancelled` — the held pass raises
    /// `CancellationError`, which maps to `cancelled`, never to a
    /// JSON-RPC error and never to `refusal` — and the idle update is
    /// strictly the last update: nothing of any kind arrives after it.
    @Test
    func cancellingALongRunningPromptMakesIdleCancelledTheLastUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("working"), .hold])
        try await ScriptedPromptFixture.runPrompt(
            Self.makePromptRequest(sessionId: fixture.sessionId), through: fixture.harness
        ) {
            try await ScriptedPromptFixture.waitForRunning(fixture.collector)
            try await fixture.harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: fixture.sessionId))
        }
        // The agent clears the finished prompt after the idle went out. The
        // run waited for that clear, so the collector holds everything that
        // the prompt sent.
        let updates = await fixture.collector.updates
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .cancelled)
        let last = try #require(updates.last)
        #expect(
            isIdleState(last.update),
            "expected idle(cancelled) as the strict terminator, got \(updates)")
    }

    // MARK: - The normal-completion ending

    /// A prompt that ignores the cancellation and completes normally with
    /// a real answer still ends `idle` with `cancelled`, never
    /// `end_turn`: the client asked to cancel, and the recorded request
    /// wins over the stream's clean finish.
    @Test func aPromptThatIgnoresCancellationStillEndsIdleCancelled() async throws {
        let (execution, recorder) = makeSinkedExecution()
        await execution.promptState.noteCancelRequested()
        let reason = await execution.drive(
            events: makeEventStream([
                .textDelta("a full answer"),
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
            ]))
        let updates = await recorder.updates

        #expect(reason == .cancelled)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        let idle = try #require(
            idleState(of: updates.last), "expected idle as the terminator, got \(updates)")
        #expect(idle.stopReason == .cancelled)
    }

    /// The updates that follow a cancel go out before the idle
    /// terminator: a terminal tool status that arrives after the cancel
    /// request is still sent, and it never holds the idle update.
    @Test func postCancelUpdatesGoOutBeforeTheIdleTerminator() async throws {
        let (execution, recorder) = makeSinkedExecution()
        await execution.promptState.noteCancelRequested()
        _ = await execution.drive(
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

    // MARK: - A request that waits for the model
    //
    // The two sessions of each proof use one queued scripted model, thus one
    // model lock. Session A holds its pass until the test releases the hold.
    // The prompt of session B thus waits for the model. A cancel or a close
    // of B must end B at once, and must not wait for A.

    /// Wires two sessions over one queued model, starts a held pass on
    /// session A, and starts a prompt on session B that waits for the model.
    ///
    /// - Parameter hold: The hold of each pass.
    /// - Returns: The fixture, with A held and B waiting for the model.
    /// - Throws: Whatever the construction, the wire or the wait throws.
    private static func startPromptThatWaitsForTheModel(
        hold: ScriptedHold
    ) async throws -> QueuedScriptedFixture {
        let fixture = try await QueuedScriptedFixture.make(
            script: [.holdUntilReleased(hold), .textDelta("released"), .endPass],
            label: "CancellationTests-queue")
        let counter = fixture.passCounter
        try await fixture.prompt(fixture.firstSessionId, text: promptText)
        try await counter.wait(for: "the pass of session A is held") { $0.running == 1 }
        try await fixture.prompt(fixture.secondSessionId, text: promptText)
        // The prompt of session B waits for the model.
        try await fixture.waitForPassesThatWaitForTheModel()
        return fixture
    }

    /// A `session/cancel` for a prompt that waits for the model ends it with `idle(cancelled)` while the other session still
    /// holds the model. After the release, the holding session completes,
    /// and a new prompt on the cancelled session completes too.
    @Test
    func cancelEndsARequestThatWaitsForTheModel() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startPromptThatWaitsForTheModel(hold: hold)
        let sessionA = fixture.firstSessionId
        let sessionB = fixture.secondSessionId

        try await fixture.base.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: sessionB))
        let cancelledUpdatesOfB = try await fixture.waitForIdle(of: sessionB)
        let updatesOfAWhileHeld = await fixture.updates(of: sessionA)

        hold.release()
        let updatesOfA = try await fixture.waitForIdle(of: sessionA)
        await ScriptedPromptFixture.waitForPromptsFinished(fixture.base.harness.agent, sessionB)
        try await fixture.prompt(sessionB, text: Self.promptText)
        let updatesOfB = try await fixture.waitForIdle(of: sessionB, count: 2)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleStopReason(in: cancelledUpdatesOfB) == .cancelled)
        #expect(ScriptedPromptFixture.idleCount(in: updatesOfAWhileHeld) == 0)
        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfA) == .endTurn)
        #expect(idleState(of: updatesOfB.last?.update)?.stopReason == .endTurn)
    }

    /// A `session/close` for a session whose prompt waits for the model
    /// answers after the `idle(cancelled)` of that prompt, while
    /// the other session still holds the model. After the release, the
    /// holding session completes.
    @Test
    func closeEndsARequestThatWaitsForTheModel() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startPromptThatWaitsForTheModel(hold: hold)
        let sessionA = fixture.firstSessionId
        let sessionB = fixture.secondSessionId

        _ = try await fixture.base.harness.connection.closeSession(
            CloseSessionRequest(sessionId: sessionB))
        let updatesOfB = await fixture.updates(of: sessionB)
        let updatesOfAWhileHeld = await fixture.updates(of: sessionA)

        hold.release()
        let updatesOfA = try await fixture.waitForIdle(of: sessionA)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfB) == .cancelled)
        #expect(ScriptedPromptFixture.idleCount(in: updatesOfAWhileHeld) == 0)
        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfA) == .endTurn)
    }

    // MARK: - An answer that mail starts, and that waits for the model
    //
    // The prompt of session B starts a shell read of a named pipe in the
    // background. Its caller answer ends, and the prompt waits for the
    // background run (task ^64pav2a). Then session A holds the model. The
    // test writes the pipe, thus the shell run of B settles, and its mail
    // starts an answer of B. That answer has no caller prompt, and it waits
    // for the model behind A. A close of B must end the prompt of B with
    // `cancelled` and answer, and must not wait for A.

    /// The marker of the prompt of session B. Its pass starts the background
    /// run.
    private static let startRunMarker = "Start the background run"

    /// The marker of the prompt of session A. Its pass holds the model.
    private static let holdModelMarker = "Hold the model"

    /// The name of the named pipe that the background run of session B reads.
    private static let releasePipeName = "release.fifo"

    /// The text that the test writes into the named pipe.
    private static let releaseText = "the run can settle"

    /// The snippet of session B: one shell read of the named pipe.
    private static let pipeReadingSnippet =
        #"return await tools.shell.execute({ command: "cat \#(releasePipeName)" });"#

    /// The script of the mail proof. The pass of B starts the background
    /// run, and the pass of A holds the model on `hold`. The answer that the
    /// mail starts matches no marker. It ends at once and starts no new
    /// background run, thus the script is finite.
    ///
    /// - Parameter hold: The hold of the pass of session A.
    /// - Returns: The script.
    /// - Throws: When the arguments of the `runCode` call cannot be encoded.
    private static func makeMailScript(hold: ScriptedHold) throws -> [ScriptedPassStep] {
        [
            .onPrompt(
                containing: startRunMarker,
                play: try ScriptedPromptFixture.makeToolPromptScript(code: pipeReadingSnippet)),
            .onPrompt(
                containing: holdModelMarker,
                play: [.holdUntilReleased(hold), .textDelta("released"), .endPass]),
            .textDelta("the mail was read"),
            .endPass,
        ]
    }

    /// A `session/close` for a session whose mail-started answer waits for
    /// the model answers while the other session still holds
    /// the model. The prompt of that session ended at the answer of its own
    /// mail (task ^9xs24pn, decision Q1), so the close sends no second
    /// `idle`. After the release, the holding session completes.
    @Test
    func closeEndsAMailStartedAnswerThatWaitsForTheModel() async throws {
        let hold = ScriptedHold()
        let directory = try NamedPipe.makeDirectory(
            holding: Self.releasePipeName, label: "CancellationTests-mail")
        let fixture = try await QueuedScriptedFixture.make(
            script: try Self.makeMailScript(hold: hold), label: "CancellationTests-mail",
            workingDirectory: directory)
        let sessionA = fixture.firstSessionId
        let sessionB = fixture.secondSessionId
        let counter = fixture.passCounter

        try await fixture.prompt(sessionB, text: Self.startRunMarker)
        _ = try await ScriptedPromptFixture.waitForUpdatesBeforeSettle(
            of: fixture.base.collector, toReach: "the runCode call of session B gave its pending answer"
        ) { updates in
            updates.contains { notification in
                guard notification.sessionId == sessionB,
                    case .toolCallUpdate(let update) = notification.update
                else { return false }
                return update.status == .value(.completed)
            }
        }
        try await fixture.prompt(sessionA, text: Self.holdModelMarker)
        // The first pass of session B ended before the pass of session A
        // got the model: the pass of A is the second pass.
        try await counter.wait(for: "the pass of session A is held") { $0.started >= 2 && $0.running == 1 }
        try await NamedPipe.write(
            Self.releaseText, toPipeAt: directory.appendingPathComponent(Self.releasePipeName))
        // The mail-started answer of session B waits for the model.
        try await fixture.waitForPassesThatWaitForTheModel()

        _ = try await fixture.base.harness.connection.closeSession(
            CloseSessionRequest(sessionId: sessionB))
        let updatesOfB = await fixture.updates(of: sessionB)
        let updatesOfAWhileHeld = await fixture.updates(of: sessionA)

        hold.release()
        let updatesOfA = try await fixture.waitForIdle(of: sessionA)
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: updatesOfB) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfB) == .endTurn)
        #expect(ScriptedPromptFixture.idleCount(in: updatesOfAWhileHeld) == 0)
        #expect(ScriptedPromptFixture.idleStopReason(in: updatesOfA) == .endTurn)
    }

    // MARK: - The no-op cancels

    /// A cancel of an idle session is a no-op: no error, no update, and
    /// no state change. A later prompt runs untouched and ends with
    /// `end_turn`, so the ignored cancel did not leak into it.
    @Test
    func cancelOfAnIdleSessionIsANoOpWithNoStateChange() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("hello"), .endPass])
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(promptUpdates(in: updates).map(\.update.kind) == Self.uncancelledPromptKinds)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// A cancel with an unknown `sessionId` is logged and ignored: it
    /// is a notification, so there is no error, and no `session/update`
    /// of any kind goes out for it.
    @Test
    func cancelOfAnUnknownSessionIdIsIgnoredAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("hello"), .endPass])
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: SessionId(rawValue: syntheticSessionIdValue)))

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(promptUpdates(in: updates).map(\.update.kind) == Self.uncancelledPromptKinds)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// A cancel for a closed session is logged and ignored: no error
    /// and no `session/update`. A round trip through `session/new`
    /// proves the notification was consumed before the assertion reads
    /// the collector.
    @Test
    func cancelOfAClosedSessionIsIgnoredAndSendsNoUpdate() async throws {
        let fixture = try await Self.makeFixture(script: [.endPass])
        await fixture.harness.agent.markSessionClosed(fixture.sessionId)
        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))

        _ = try await fixture.harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
        #expect(promptUpdates(in: await fixture.collector.updates).isEmpty)
        await fixture.close()
    }
}
