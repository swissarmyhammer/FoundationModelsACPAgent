import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
// `SubmissionID` has an internal initializer only. A debug build compiles
// Router with testing enabled, so the synthetic events reach it this way.
@testable import FoundationModelsRouter

/// The follow-up of a prompt (task ^64pav2a): when the stream of the caller
/// answer ends while a background run of the session is open, the prompt
/// does not end. It projects the session events, the settlement of the run
/// and the answer that its mail starts, into the same ACP prompt, until the
/// session has no more work. Then it sends the stop reason of the last
/// answer.
@Suite struct PromptFollowUpTests {
    // MARK: - Constants

    /// The marker of the prompt that starts the background run.
    private static let startRunMarker = "Start the background run"

    /// The name of the named pipe that the background run reads.
    private static let releasePipeName = "release.fifo"

    /// The text that the test writes into the named pipe.
    private static let releaseText = "the run can settle"

    /// The text of the answer that the mail of the settled run starts.
    private static let mailReply = "the mail was read"

    /// The text of the caller answer of the synthetic proofs.
    private static let callerText = "the snippet runs in the background"

    /// The snippet of the prompt: one shell read of the named pipe. The
    /// shell gives its pending answer at once, so the read runs in the
    /// background.
    private static let pipeReadingSnippet =
        #"return await tools.shell.execute({ command: "cat \#(releasePipeName)" });"#

    /// The completion token of the synthetic background run.
    private static let runToken = "run-1"

    /// The token count of each synthetic submission.
    private static let syntheticTokenCount = 4

    /// The context fill of each synthetic submission.
    private static let syntheticContextFill = 0.25

    /// The text of the failure of a synthetic mail answer.
    private static let mailFailureText = "the mail answer failed"

    // MARK: - The wire proofs

    /// The script of the wire proofs. The prompt with the marker starts the
    /// background run. The answer that the mail starts carries no marker,
    /// so it plays the reply and ends.
    ///
    /// - Returns: The script.
    /// - Throws: When the arguments of the `runCode` call cannot be encoded.
    private static func makeScript() throws -> [ScriptedPassStep] {
        [
            .onPrompt(
                containing: startRunMarker,
                play: try ScriptedPromptFixture.makeToolPromptScript(code: pipeReadingSnippet)),
            .textDelta(mailReply),
            .endPass,
        ]
    }

    /// Opens one session in a directory that holds the named pipe, sends the
    /// prompt that starts the background run, and waits until the `runCode`
    /// call of the prompt completed with its pending answer.
    ///
    /// - Parameter label: The directory label of the proof.
    /// - Returns: The fixture, with the run of the prompt in the background.
    /// - Throws: Whatever the construction, the wire or the wait throws.
    private static func startPromptWithABackgroundRun(label: String) async throws -> ScriptedPromptFixture {
        let directory = try NamedPipe.makeDirectory(holding: releasePipeName, label: label)
        let fixture = try await ScriptedPromptFixture.make(
            script: try makeScript(), label: label, workingDirectory: directory)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: startRunMarker))
        _ = try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the completed runCode call"
        ) { updates in
            updates.contains { notification in
                guard case .toolCallUpdate(let update) = notification.update else { return false }
                return update.status == .value(.completed)
            }
        }
        return fixture
    }

    /// Whether `notification` comes from the terminal stream of the session
    /// and not from the prompt. The terminal stream announces a shell run
    /// and reports its output and its exit for the life of the session
    /// (plan.md §11.8), so its updates can come after the `idle` of a
    /// prompt.
    ///
    /// - Parameter notification: The collected notification.
    /// - Returns: Whether the terminal stream sent it.
    private static func isTerminalStreamUpdate(_ notification: UpdateSessionNotification) -> Bool {
        switch notification.update {
        case .terminalUpdate, .terminalOutputChunk:
            return true
        case .toolCallUpdate(let update):
            return update.status == .value(.inProgress)
        default:
            return false
        }
    }

    /// Asserts that `updates` holds one `idle`, and that no update of the
    /// prompt comes after it.
    ///
    /// - Parameter updates: The collected notifications of the prompt.
    /// - Returns: The index of the `idle`.
    /// - Throws: When `updates` holds no `idle`.
    private static func requireIdleLast(in updates: [UpdateSessionNotification]) throws -> Int {
        let idle = try #require(updates.lastIndex { isIdleState($0.update) })
        let after = updates[(idle + 1)...]
        #expect(
            after.allSatisfy(isTerminalStreamUpdate),
            "expected no prompt update after the idle, got \(after.map(\.update.kind))")
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        return idle
    }

    /// A prompt whose snippet goes to the background gets the answer that the
    /// mail of the settled run starts. The text of that answer arrives in the
    /// same prompt, and the one `idle` with `end_turn` comes after it.
    @Test(.timeLimit(.minutes(1)))
    func theMailAnswerOfABackgroundRunArrivesInTheSamePrompt() async throws {
        let label = "PromptFollowUpTests-mail"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)

        try await NamedPipe.write(
            Self.releaseText, toPipeAt: fixture.cwd.appendingPathComponent(Self.releasePipeName))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        let kinds = updates.map(\.update.kind)
        let mailChunk = try #require(
            updates.firstIndex { notification in
                ScriptedPromptFixture.agentChunkTexts(in: [notification]) == [Self.mailReply]
            },
            "expected the mail reply in the prompt, got \(kinds)")
        let idle = try Self.requireIdleLast(in: updates)
        #expect(mailChunk < idle)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// A `session/cancel` while the prompt waits for its background run ends
    /// the prompt with `cancelled` at once, and no update of the prompt
    /// follows the `idle`: also not the settlement that the close of the
    /// session makes.
    @Test(.timeLimit(.minutes(1)))
    func cancelDuringTheWaitForABackgroundRunEndsThePromptCancelled() async throws {
        let label = "PromptFollowUpTests-cancel"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        let updates = promptUpdates(in: await fixture.collector.updates)
        await fixture.close()

        _ = try Self.requireIdleLast(in: updates)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .cancelled)
    }

    /// A prompt that starts no background run ends as before: the echo, the
    /// first-activity title, `running`, the text and one `idle` with
    /// `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func aPromptWithNoBackgroundRunEndsAsBefore() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta(Self.mailReply), .endPass], label: "PromptFollowUpTests-plain")
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.startRunMarker))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(
            promptUpdates(in: updates).map(\.update.kind) == [
                .userMessage, .sessionInfoUpdate, .stateUpdate, .agentMessageChunk, .stateUpdate,
            ])
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - The synthetic proofs

    /// The usage of one synthetic submission.
    ///
    /// - Parameter finishReason: Why the submission stopped.
    /// - Returns: The usage.
    private static func makeUsage(finishReason: FinishReason = .completed) -> TokenUsage {
        TokenUsage(
            tokensIn: syntheticTokenCount, tokensOut: syntheticTokenCount,
            contextFill: syntheticContextFill, finishReason: finishReason)
    }

    /// The final answer of one synthetic chain. The reply tells the caller
    /// answer from the mail answer, because a synthetic stream has no
    /// message ids: only the mailbox makes them.
    ///
    /// - Parameter reply: The final reply of the chain.
    /// - Returns: The `answered` event.
    private static func makeAnswered(reply: String) -> SessionEvent {
        .answered(
            SessionAnswer(
                reply: reply, messageIds: [], usage: makeUsage(), compactions: [], toolCalls: [],
                toolInvocations: []))
    }

    /// The caller answer of the synthetic proofs: one text delta, one
    /// submission, and the final answer of the caller message.
    private static let callerEvents: [SessionEvent] = [
        makeSubmissionStarted(),
        .textDelta(callerText),
        makeSubmissionEnded(makeUsage()),
        makeAnswered(reply: callerText),
    ]

    /// The settlement of the synthetic background run.
    private static let settledRun = SessionEvent.runSettled(
        OperationEvent(
            tool: "shell", op: "execute command", correlationID: runToken, kind: .completed, detail: "{}",
            outcome: .succeeded))

    /// The events of one synthetic mail answer: a submission that `finishReason`
    /// ends, and the whole reply.
    ///
    /// - Parameter finishReason: Why the submission of the mail answer stopped.
    /// - Returns: The events.
    private static func makeMailAnswer(finishReason: FinishReason = .completed) -> [SessionEvent] {
        [
            makeSubmissionStarted(cause: .mail),
            makeSubmissionEnded(makeUsage(finishReason: finishReason)),
            makeAnswered(reply: mailReply),
        ]
    }

    /// A session-scoped event stream that holds `events` and never ends, as
    /// the stream of a live session does.
    ///
    /// - Parameters:
    ///   - events: The events of the session, in order.
    ///   - idle: What the idle wait gives.
    /// - Returns: The follow-up over the stream.
    private static func makeFollowUp(_ events: [SessionEvent], idle: Bool = true) -> SessionFollowUp {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        for event in events {
            continuation.yield(event)
        }
        return SessionFollowUp(events: stream) {
            // The continuation stays alive until the wait ends, so the
            // stream does not end before the drive reads it.
            _ = continuation
            return idle
        }
    }

    /// The session stream carries each event of the caller answer as well.
    /// The follow-up projects only the events after the caller answer: the
    /// caller text goes out one time, the settlement and the mail reply go
    /// out, and the `idle` with `end_turn` comes last.
    @Test func aFollowUpProjectsTheEventsAfterTheCallerAnswerOneTime() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let followUp = Self.makeFollowUp(Self.callerEvents + [Self.settledRun] + Self.makeMailAnswer())

        let reason = await execution.drive(events: makeEventStream(Self.callerEvents), followUp: followUp)
        let updates = await recorder.updates

        let chunks = updates.compactMap { agentMessageChunk(of: $0) }.map { chunk -> String? in
            guard case .text(let content) = chunk.content else { return nil }
            return content.text
        }
        #expect(chunks == [Self.callerText, Self.mailReply])
        #expect(toolCallUpdates(in: updates).map(\.toolCallId.rawValue) == [Self.runToken])
        #expect(reason == .endTurn)
        #expect(idleState(of: updates.last)?.stopReason == .endTurn)
    }

    /// The stop reason of a prompt comes from its last answer: a mail answer
    /// that stops at the output token ceiling ends the prompt with
    /// `_truncated`, also when the caller answer ended by itself.
    @Test func theStopReasonComesFromTheLastAnswer() async throws {
        let (execution, recorder) = makeSinkedExecution()
        let followUp = Self.makeFollowUp(
            Self.callerEvents + [Self.settledRun] + Self.makeMailAnswer(finishReason: .maxTokens))

        let reason = await execution.drive(events: makeEventStream(Self.callerEvents), followUp: followUp)
        let updates = await recorder.updates

        #expect(reason == .unknown(PromptExecution.truncatedStopReasonValue))
        #expect(idleState(of: updates.last)?.stopReason == reason)
    }

    /// A mail answer that fails ends the prompt with the `_error` stop
    /// reason of a failed prompt.
    @Test func aFailedMailAnswerEndsThePromptWithTheErrorStopReason() async throws {
        let (execution, _) = makeSinkedExecution()
        let failure = SessionEvent.answerFailed(
            AnswerFailure(messageIds: [], reason: .error(Self.mailFailureText)))
        let followUp = Self.makeFollowUp(
            Self.callerEvents + [Self.settledRun, makeSubmissionStarted(cause: .mail), failure])

        let reason = await execution.drive(events: makeEventStream(Self.callerEvents), followUp: followUp)

        #expect(reason == .unknown(PromptExecution.unmappedStopReasonValue))
    }

    /// A wait that ends with no idle session, because the session closed,
    /// ends the prompt with `cancelled`: the prompt did not see the end of
    /// the work of the session.
    @Test func aWaitThatEndsWithNoIdleSessionEndsThePromptCancelled() async throws {
        let (execution, _) = makeSinkedExecution()
        let followUp = Self.makeFollowUp(Self.callerEvents, idle: false)

        let reason = await execution.drive(events: makeEventStream(Self.callerEvents), followUp: followUp)

        #expect(reason == .cancelled)
    }
}
