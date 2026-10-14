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
/// mail. When its snippet goes to the background, the settlement of the run
/// and the answer that the mail of the run starts go to the client after the
/// `idle` of the prompt, with no prompt open and no state update. This
/// reverses task ^64pav2a, where the prompt waited for the work of the
/// session.
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
    /// its own mail: one `idle` with `end_turn`, while the run still waits.
    @Test(.timeLimit(.minutes(1)))
    func aPromptEndsAtTheAnswerOfItsOwnMailWhileItsRunWaits() async throws {
        let label = "PromptFollowUpTests-own-mail"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)

        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        try await NamedPipe.write(
            Self.releaseText, toPipeAt: fixture.cwd.appendingPathComponent(Self.releasePipeName))
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        #expect(!ScriptedPromptFixture.agentChunkTexts(in: updates).contains(Self.mailReply))
    }

    /// The fixed order of task ^9xs24pn, decision Q1: the prompt ends, the
    /// run settles after the `idle`, and the answer that the mail of the run
    /// starts reaches the client. No second `idle` goes out, because no
    /// prompt is open (decision Q2).
    @Test(.timeLimit(.minutes(1)))
    func aRunMailAnswerAfterTheIdleOfThePromptReachesTheClient() async throws {
        let label = "PromptFollowUpTests-after-idle"
        let fixture = try await Self.startPromptWithABackgroundRun(label: label)
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)

        try await NamedPipe.write(
            Self.releaseText, toPipeAt: fixture.cwd.appendingPathComponent(Self.releasePipeName))
        let updates = try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the mail reply"
        ) { updates in
            ScriptedPromptFixture.agentChunkTexts(in: updates).contains(Self.mailReply)
        }
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        let idle = try #require(updates.firstIndex { isIdleState($0.update) })
        let mailChunk = try #require(
            updates.firstIndex { ScriptedPromptFixture.agentChunkTexts(in: [$0]) == [Self.mailReply] })
        #expect(idle < mailChunk)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
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
            let session = SyntheticSession(projector: projector, recorder: recorder, outputs: outputs, ends: ends)
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
            await projector.stop()
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
