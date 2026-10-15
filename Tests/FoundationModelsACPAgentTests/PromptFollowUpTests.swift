import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
// `SubmissionID` has an internal initializer only. A debug build compiles
// Router with testing enabled, so the synthetic events reach it this way.
@testable import FoundationModelsRouter

/// The work that comes after a prompt (elicitation-plan section 8; task
/// ^9xs24pn, decision Q1). A prompt ends at the terminal event of its own
/// mail. When its snippet goes to the background, the run is Router work, so
/// the session stays `running`: the settlement of the run and the answer
/// that the mail of the run starts come before the one `idle` of the
/// session (elicitation-plan task 2). A run that waits only for the user is
/// no work, so a question of a background run does not keep the session
/// `running`.
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

    /// The typed error of a failed synthetic answer, which
    /// `awaitAnswer(of:)` gives.
    private struct MailAnswerFailure: Error, CustomStringConvertible {
        /// The text of the failure.
        var description: String { PromptFollowUpTests.mailFailureText }
    }

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

    /// A prompt whose snippet goes to the background ends at the answer of
    /// its own mail, while the run still waits. The run is Router work, so
    /// no `idle` goes out at the end of the prompt: the session stays
    /// `running` until the run ends.
    @Test
    func aPromptEndsAtTheAnswerOfItsOwnMailWhileItsRunWaits() async throws {
        let label = "PromptFollowUpTests-own-mail"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)

        await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
        let atPromptEnd = await fixture.collector.updates
        try await NamedPipe.write(
            Self.releaseText, toPipeAt: fixture.cwd.appendingPathComponent(Self.releasePipeName))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        #expect(ScriptedPromptFixture.idleCount(in: atPromptEnd) == 0)
        #expect(!ScriptedPromptFixture.agentChunkTexts(in: atPromptEnd).contains(Self.mailReply))
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// The fixed order of task ^9xs24pn, decision Q1, with the work state of
    /// elicitation-plan task 2: the prompt ends, the run settles, the answer
    /// that the mail of the run starts reaches the client, and then the one
    /// `idle` of the session goes out, with the stop reason of the prompt.
    @Test
    func aRunMailAnswerComesBeforeTheOneIdleOfTheSession() async throws {
        let label = "PromptFollowUpTests-after-idle"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)
        await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)

        try await NamedPipe.write(
            Self.releaseText, toPipeAt: fixture.cwd.appendingPathComponent(Self.releasePipeName))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        let idle = try #require(updates.firstIndex { isIdleState($0.update) })
        let mailChunk = try #require(
            updates.firstIndex { ScriptedPromptFixture.agentChunkTexts(in: [$0]) == [Self.mailReply] })
        #expect(mailChunk < idle)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - The work state with no prompt open (elicitation-plan task 2)

    /// The marker of the prompt that starts the asking background run.
    private static let askMarker = "Ask in the background"

    /// The snippet that asks the person one question. The question sends
    /// the run to the background.
    private static let askingSnippet = #"return await elicit("Which colour do you want?");"#

    /// Opens one session whose prompt starts a background run that asks one
    /// question, and waits until the question reaches the client and the
    /// session sent its first `idle`.
    ///
    /// - Parameter label: The directory label of the proof.
    /// - Returns: The fixture, the pending question, and the updates at that
    ///   `idle`.
    /// - Throws: Whatever the construction, the wire or the waits throw.
    private static func askInTheBackground(
        label: String
    ) async throws -> (fixture: ScriptedPromptFixture, question: PendingElicitation, updates: [UpdateSessionNotification]) {
        let fixture = try await ScriptedPromptFixture.make(
            script: [
                .onPrompt(
                    containing: askMarker,
                    play: try ScriptedPromptFixture.makeToolPromptScript(code: askingSnippet)),
                .textDelta(mailReply),
                .endPass,
            ],
            label: label)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: askMarker))
        let question = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        return (fixture, question, updates)
    }

    /// An open question does not keep the session `running`: a background
    /// run that waits only for the user is no Router work, so the session
    /// goes `idle` while its question is still open at the client. No
    /// `requires_action` goes out.
    @Test
    func anOpenQuestionDoesNotKeepTheSessionRunning() async throws {
        let asked = try await Self.askInTheBackground(label: "PromptFollowUpTests-open-question")
        let pendingAtIdle = await ElicitationWait.pendingElicitations(in: asked.fixture.session)
        _ = try await asked.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: asked.fixture.sessionId))
        await asked.fixture.close()

        #expect(pendingAtIdle.map(\.id) == [asked.question.id])
        #expect(ScriptedPromptFixture.idleStopReason(in: asked.updates) == .endTurn)
        #expect(!asked.updates.contains { isRequiresActionState($0.update) })
    }

    /// Background work with no prompt open gives `running` and then `idle`.
    /// The answer to the question resumes the background run: Router work
    /// starts with no prompt open, the run settles, its mail starts an
    /// answer, and the work ends. No prompt ended since that `running`, so
    /// the `idle` has no stop reason.
    @Test
    func backgroundWorkWithNoPromptOpenGivesRunningThenIdle() async throws {
        let asked = try await Self.askInTheBackground(label: "PromptFollowUpTests-background-work")

        await MainActor.run { asked.fixture.session.acceptElicitation(asked.question.id) }
        _ = try await ScriptedPromptFixture.waitForUpdates(
            of: asked.fixture.collector, toReach: "the mail reply"
        ) { updates in
            ScriptedPromptFixture.agentChunkTexts(in: updates).contains(Self.mailReply)
        }
        // The fixed point: Router has no work, and the close sends each
        // event of the session before its response.
        let session = try #require(
            await asked.fixture.harness.agent.sessions[asked.fixture.sessionId]?.session)
        _ = await session.awaitIdle()
        _ = try await asked.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: asked.fixture.sessionId))
        let updates = await asked.fixture.collector.updates
        await asked.fixture.close()

        let afterFirstIdle = Array(updates[asked.updates.count...])
        let states = afterFirstIdle.filter {
            if case .stateUpdate = $0.update { true } else { false }
        }
        #expect(states.count == 2, "expected running then idle, got \(states)")
        #expect(isRunningState(states.first?.update))
        #expect(isIdleState(states.last?.update))
        if case .stateUpdate(.idle(let idle)) = states.last?.update {
            #expect(idle.stopReason == nil)
        }
        #expect(ScriptedPromptFixture.agentChunkTexts(in: afterFirstIdle).contains(Self.mailReply))
    }

    /// A prompt that starts no background run ends as before: the echo, the
    /// first-activity title, `running`, the text and one `idle` with
    /// `end_turn`.
    @Test
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

    /// The final answer of the mail `mailId`.
    ///
    /// - Parameters:
    ///   - reply: The final reply of the answer.
    ///   - mailId: The mail that the answer answers.
    /// - Returns: The `answered` event.
    private static func makeAnswered(reply: String, mailId: MailID) -> SessionEvent {
        .answered(
            SessionAnswer(
                reply: reply, mailIds: [mailId], usage: makeUsage(), compactions: [], toolCalls: [],
                toolInvocations: []))
    }

    /// The caller answer of the synthetic proofs: one text delta, one
    /// submission, and the final answer of the mail of the prompt.
    ///
    /// - Parameter mailId: The mail of the prompt.
    /// - Returns: The events.
    private static func callerEvents(of mailId: MailID) -> [SessionEvent] {
        [
            makeSubmissionStarted(),
            .textDelta(callerText),
            makeSubmissionEnded(makeUsage()),
            makeAnswered(reply: callerText, mailId: mailId),
        ]
    }

    /// The settlement of the synthetic background run.
    private static let settledRun = SessionEvent.runSettled(
        OperationEvent(
            tool: "shell", op: "execute command", correlationID: runToken, kind: .completed, detail: "{}",
            outcome: .succeeded))

    /// The events of one synthetic answer that the mail `mailId` of the run
    /// starts: a submission that `finishReason` ends, and the whole reply.
    ///
    /// - Parameters:
    ///   - mailId: The run mail.
    ///   - finishReason: Why the submission of the mail answer stopped.
    /// - Returns: The events.
    private static func mailAnswer(of mailId: MailID, finishReason: FinishReason = .completed) -> [SessionEvent] {
        [
            makeSubmissionStarted(cause: .mail),
            makeSubmissionEnded(makeUsage(finishReason: finishReason)),
            makeAnswered(reply: mailReply, mailId: mailId),
        ]
    }

    /// One synthetic session: a projector over a recording sink, one source
    /// of outputs, and one open prompt.
    private struct SyntheticSession {
        /// The projector.
        let projector: SessionProjector

        /// The recorder of each update that the projector sent.
        let recorder: SinkRecorder

        /// The input of the outputs of the source.
        let outputs: AsyncStream<SessionOutput>.Continuation

        /// The id of the source.
        let sourceId: ULID

        /// The mail of the open prompt.
        let promptMail = MailID()

        /// The stop reasons of the prompt; the only one comes at its end.
        let ends: AsyncStream<StopReason>

        /// Makes the session and opens the prompt.
        ///
        /// - Parameter failure: The error that `awaitAnswer(of:)` throws
        ///   for a failed answer, or `nil`.
        /// - Returns: The session.
        static func make(failure: (any Error)? = nil) async -> SyntheticSession {
            let recorder = SinkRecorder()
            let send: SessionUpdateSink = { update in await recorder.append(update) }
            let projector = SessionProjector(
                sessionId: SessionId(rawValue: syntheticSessionIdValue), modelName: syntheticModelName,
                send: send, relay: nil, runCallJoins: RunCallJoinTable())
            let (stream, outputs) = AsyncStream.makeStream(of: SessionOutput.self)
            let source = SessionProjector.Source(id: ULID.generate(), session: nil)
            await projector.attach(stream, from: source)
            let (ends, end) = AsyncStream.makeStream(of: StopReason.self)
            let session = SyntheticSession(
                projector: projector, recorder: recorder, outputs: outputs, sourceId: source.id, ends: ends)
            projector.open(
                SessionProjector.Prompt(
                    mailId: session.promptMail, sourceId: source.id,
                    awaitAnswer: { _ in throw failure ?? CancellationError() },
                    owner: PromptStateOwner(send: send), modelName: syntheticModelName,
                    onEnd: { reason in
                        end.yield(reason)
                        end.finish()
                    }))
            return session
        }

        /// Gives `events` to the projector, each with the origin of the mail
        /// `mailId`.
        ///
        /// - Parameters:
        ///   - events: The events, in order.
        ///   - mailId: The mail that the events answer.
        func send(_ events: [SessionEvent], answering mailId: MailID) {
            for event in events {
                outputs.yield(SessionOutput(origin: .mail([mailId]), event: event))
            }
        }

        /// Ends the source, stops the projector after each event, and gives
        /// the stop reason of the prompt and each sent update.
        ///
        /// - Returns: The stop reason, or `nil` when the prompt did not end,
        ///   and the updates in send order.
        func finish() async -> (reason: StopReason?, updates: [SessionUpdate]) {
            outputs.finish()
            await projector.stop(after: [sourceId])
            var reason: StopReason?
            for await ended in ends {
                reason = ended
            }
            return (reason, await recorder.updates)
        }
    }

    /// The prompt ends at the answer of its own mail. The settlement of the
    /// run and the reply of the run mail go out after its `idle`, and no
    /// second `idle` goes out.
    @Test func theWorkAfterThePromptGoesOutAfterItsIdle() async throws {
        let session = await SyntheticSession.make()
        let runMail = MailID()
        session.send(Self.callerEvents(of: session.promptMail), answering: session.promptMail)
        session.send([Self.settledRun] + Self.mailAnswer(of: runMail), answering: runMail)
        let (reason, updates) = await session.finish()

        let chunks = updates.compactMap { agentMessageChunk(of: $0) }.map { chunk -> String? in
            guard case .text(let content) = chunk.content else { return nil }
            return content.text
        }
        let idle = try #require(updates.firstIndex(where: isIdleState))
        let settlement = try #require(updates.firstIndex { toolCallUpdates(in: [$0]).count == 1 })
        #expect(chunks == [Self.callerText, Self.mailReply])
        #expect(idle < settlement)
        #expect(reason == .endTurn)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
    }

    /// The stop reason comes from the answer of the mail of the prompt: a run
    /// mail answer that stops at the output token ceiling after the prompt
    /// does not change it.
    @Test func theStopReasonComesFromTheAnswerOfThePromptMail() async {
        let session = await SyntheticSession.make()
        let runMail = MailID()
        session.send(Self.callerEvents(of: session.promptMail), answering: session.promptMail)
        session.send([Self.settledRun] + Self.mailAnswer(of: runMail, finishReason: .maxTokens), answering: runMail)
        let (reason, _) = await session.finish()

        #expect(reason == .endTurn)
    }

    /// An event of another mail while the prompt is open does not count for
    /// the prompt: a run mail answer that stops at the output token ceiling
    /// before the prompt ends does not cut the prompt.
    @Test func anEventOfAnotherMailDoesNotCountForThePrompt() async {
        let session = await SyntheticSession.make()
        let runMail = MailID()
        session.send(Self.mailAnswer(of: runMail, finishReason: .maxTokens), answering: runMail)
        session.send(Self.callerEvents(of: session.promptMail), answering: session.promptMail)
        let (reason, _) = await session.finish()

        #expect(reason == .endTurn)
    }

    /// A failed answer of the mail of the prompt ends the prompt with the
    /// `error` stop reason, and the `error` object of the idle holds the text
    /// of the typed error that `awaitAnswer(of:)` gives.
    @Test func aFailedAnswerOfThePromptMailEndsWithTheErrorStopReason() async throws {
        let session = await SyntheticSession.make(failure: MailAnswerFailure())
        let failure = SessionEvent.answerFailed(
            AnswerFailure(mailIds: [session.promptMail], reason: .error(Self.mailFailureText)))
        session.send([makeSubmissionStarted(), failure], answering: session.promptMail)
        let (reason, updates) = await session.finish()
        let idle = try #require(try updates.last.flatMap(wireObject(of:)))

        #expect(reason == .error)
        #expect(jsonString(of: idle["stopReason"]) == "error")
        #expect(jsonString(of: jsonObject(of: idle["error"])?["message"]) == Self.mailFailureText)
    }

    /// A Router session that closes while the prompt is open ends the prompt
    /// with `cancelled`: the prompt did not see the terminal of its mail.
    @Test func aSourceThatEndsWithThePromptOpenEndsThePromptCancelled() async {
        let session = await SyntheticSession.make()
        session.send([makeSubmissionStarted(), .textDelta(Self.callerText)], answering: session.promptMail)
        let (reason, _) = await session.finish()

        #expect(reason == .cancelled)
    }
}
