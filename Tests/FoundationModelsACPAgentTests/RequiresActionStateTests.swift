import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
@testable import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The live `requires_action` state (ACP v2, prompt lifecycle). While a
/// question of the session waits for the user, the session reports
/// `requires_action`. When the question ends, the session reports `running`
/// or `idle`. The copy of a child question reports nothing.
@Suite(.closesHarnesses) struct RequiresActionStateTests {
    /// A sink that keeps each update it gets.
    private final class RecordingSink: Sendable {
        /// The updates that the sink got.
        private let kept = Mutex<[SessionUpdate]>([])

        /// The updates that the sink got, in order.
        var updates: [SessionUpdate] {
            kept.withLock { $0 }
        }

        /// The names of the states that the sink got, in order.
        var names: [String] {
            stateNames(of: updates)
        }

        /// The sink function of the recorder.
        var send: SessionUpdateSink {
            { update in self.kept.withLock { $0.append(update) } }
        }
    }

    // MARK: - The ledger

    /// A question that waits while the session is idle sends
    /// `requires_action`, and its end sends `idle`.
    @Test
    func aQuestionOnAnIdleSessionSendsRequiresActionThenIdle() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)

        await ledger.userWaitStarted("question")
        await ledger.userWaitEnded("question")

        #expect(sink.names == ["requires_action", "idle"])
    }

    /// A question that waits while a prompt is open sends `requires_action`,
    /// and its end sends `running` again.
    @Test
    func theEndOfAQuestionOfABusySessionSendsRunning() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        await ledger.promptStarted()

        await ledger.userWaitStarted("question")
        await ledger.userWaitEnded("question")

        #expect(sink.names == ["running", "requires_action", "running"])
    }

    /// A second question sends no second `requires_action`, and the state
    /// ends only with the last question.
    @Test
    func theStateEndsWithTheLastWaitingQuestion() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)

        await ledger.userWaitStarted("first")
        await ledger.userWaitStarted("second")
        await ledger.userWaitEnded("first")
        await ledger.userWaitEnded("second")

        #expect(sink.names == ["requires_action", "idle"])
    }

    /// The `idle` after a question carries the stop reason of the prompt
    /// that ended while the question waited.
    @Test
    func theIdleAfterAQuestionCarriesTheStopReasonOfThePromptThatEndedMeanwhile() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        await ledger.promptStarted()
        await ledger.userWaitStarted("question")
        await ledger.promptEnded(IdleStateUpdate(stopReason: .cancelled), started: true)

        await ledger.userWaitEnded("question")

        #expect(sink.names == ["running", "requires_action", "idle"])
        #expect(sink.updates.compactMap(idleState(of:)).last?.stopReason == .cancelled)
    }

    /// An answer that Router took resumes a run. The session goes `running`
    /// at once, with no `idle` between the answer and the work, even when the
    /// work event of Router comes later.
    @Test
    func anAnswerThatResumesARunSendsNoIdleBeforeTheWorkEvent() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        let source = ULID()
        await ledger.userWaitStarted("question")
        let mark = await ledger.workEventMark

        await ledger.userWaitEnded("question", resumedWork: true, since: mark)
        await ledger.workStarted(on: source)
        await ledger.workEnded(on: source)

        #expect(sink.names == ["requires_action", "running", "idle"])
    }

    /// An answer whose work already started and ended sends `idle`: the
    /// ledger must not keep the session busy for a work event that it took
    /// already.
    @Test
    func anAnswerWhoseWorkAlreadyEndedLeavesTheSessionIdle() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        let source = ULID()
        await ledger.userWaitStarted("question")
        let mark = await ledger.workEventMark
        await ledger.workStarted(on: source)
        await ledger.workEnded(on: source)

        await ledger.userWaitEnded("question", resumedWork: true, since: mark)

        #expect(sink.names == ["requires_action", "idle"])
    }

    // MARK: - The relay

    /// A question of the session sends `requires_action` to the client while
    /// it waits, and `idle` after its end.
    @Test
    func aQuestionOfTheSessionReportsRequiresActionToTheClient() async throws {
        let question = try await OpenQuestion.open(label: "RequiresActionStateTests-question") {
            OpenQuestion.makeFormRequest(elicitationId: $0)
        }
        let fixture = question.fixture
        let atWait = await fixture.collector.updates.map(\.update)

        await question.cancel()
        await fixture.close()
        let updates = await fixture.collector.updates.map(\.update)

        #expect(stateNames(of: atWait).last == "requires_action")
        #expect(stateNames(of: updates) == ["requires_action", "idle"])
    }

    /// The copy of a child question sends nothing: the child session holds
    /// the question and reports its own state.
    @Test
    func theCopyOfAChildQuestionReportsNoStateToTheClient() async throws {
        let question = try await OpenQuestion.open(label: "RequiresActionStateTests-relayed-copy") {
            OpenQuestion.makeFormRequest(elicitationId: $0).relayed(by: "reviewer", askedBy: "elicitor")
        }
        let fixture = question.fixture
        let ledger = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.stateLedger)
        let snapshot = await ledger.currentSnapshot()

        await question.cancel()
        await fixture.close()
        let updates = await fixture.collector.updates.map(\.update)

        #expect(stateNames(of: updates).isEmpty)
        #expect(ScriptedPromptFixture.isIdle(snapshot))
    }
}
