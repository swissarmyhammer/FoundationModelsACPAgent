import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The current-state sync of `session/resume` (ACP v2 Session Setup, "Ordering"). The agent sends
/// it after the replay of the requested history, if any, and before the response. It sends one
/// current `state_update` and then the current `session_info_update`. It does this for each resume,
/// with or without `replayFrom`. The replay never sends the retained `state_update` as the current
/// state. The sync does not change the retained state of the history.
@Suite(.closesHarnesses) struct ResumeSyncTests {
    // MARK: - Readers

    /// A sink that holds its first update until the test opens the gate. It keeps each update when
    /// the update is done. So the order of the kept updates is the order in which the sends
    /// finished.
    private final class GatedSink: Sendable {
        /// The test opens it to let the first update finish.
        let gate = LateAnswerGate()

        /// Open when the first update reached the sink.
        let firstReached = LateAnswerGate()

        /// The number of updates that reached the sink.
        private let reached = Mutex(0)

        /// The updates whose send is done.
        private let kept = Mutex<[SessionUpdate]>([])

        /// The updates whose send is done, in order.
        var updates: [SessionUpdate] {
            kept.withLock { $0 }
        }

        /// The sink function of the recorder.
        var send: SessionUpdateSink {
            { update in
                let isFirst = self.reached.withLock { count -> Bool in
                    count += 1
                    return count == 1
                }
                if isFirst {
                    await self.firstReached.open()
                    await self.gate.wait()
                }
                self.kept.withLock { $0.append(update) }
            }
        }
    }

    /// Maps each update to its ``WireItem``.
    ///
    /// - Parameter updates: The updates.
    /// - Returns: The kinds, in order.
    private static func kinds(of updates: [SessionUpdate]) -> [WireItem] {
        updates.map(WireItem.of(update:))
    }

    /// Resumes the session and returns the updates that the resume sent.
    ///
    /// - Parameters:
    ///   - resume: The fixture of the session.
    ///   - replayFrom: The replay cursor of the request, or `nil` for none.
    /// - Returns: The updates that came after the call began, in order.
    /// - Throws: Whatever the request throws.
    private static func resumeAndCollect(
        _ resume: ResumeSessionFixture, replayFrom: ReplayFrom? = nil
    ) async throws -> [SessionUpdate] {
        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: replayFrom))
        return Array(await resume.fixture.collector.updates.dropFirst(countBefore)).map(\.update)
    }

    /// Runs ``RoutedACPAgent/syncCurrentState(of:)`` and returns the
    /// snapshot that the client got.
    ///
    /// - Parameters:
    ///   - fixture: The fixture of the session.
    ///   - count: The number of updates that match `isState` when the
    ///     snapshot arrived. The live change before it counts as one.
    ///   - isState: Tells whether an update is the state under test.
    /// - Returns: The updates that came after the call began, in order.
    /// - Throws: Whatever the wait throws.
    private static func syncAndCollect(
        in fixture: ScriptedPromptFixture, count: Int, isState: @escaping @Sendable (SessionUpdate?) -> Bool
    ) async throws -> [SessionUpdate] {
        let countBefore = await fixture.collector.updates.count
        await fixture.harness.agent.syncCurrentState(of: fixture.sessionId)
        let received = try await fixture.collector.wait(for: "the snapshot reaches the client") { updates in
            updates.count { isState($0.update) } >= count
        }
        return Array(received.dropFirst(countBefore)).map(\.update)
    }

    /// Resumes the session of `resume`. It returns what the agent sent from the start of the
    /// request to its response, in wire order.
    ///
    /// - Parameters:
    ///   - resume: The fixture, which taps the wire.
    ///   - replayFrom: The replay cursor of the request, or `nil` for none.
    /// - Returns: The kinds of the wire items.
    /// - Throws: Whatever the request throws.
    private static func wireKindsOfAResume(
        _ resume: ResumeSessionFixture, replayFrom: ReplayFrom?
    ) async throws -> [WireItem] {
        let tap = try #require(resume.fixture.harness.wireTap)
        return try await WireItem.sent(by: tap) {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest(replayFrom: replayFrom))
        }
    }

    /// Runs one prompt, closes the session, and resumes it. It returns what the agent sent from the
    /// start of the resume request to its response.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - replayFrom: The replay cursor of the request, or `nil` for none.
    /// - Returns: The kinds of the wire items.
    /// - Throws: Whatever the setup or the request throws.
    private static func wireOfAResumeAfterAPrompt(label: String, replayFrom: ReplayFrom?) async throws -> [WireItem] {
        var resume = try await ResumeSessionFixture.make(label: label, tapsWire: true)
        try await resume.runPrompt("a question before the resume")
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)
        let kinds = try await wireKindsOfAResume(resume, replayFrom: replayFrom)
        await resume.fixture.close()
        return kinds
    }

    // MARK: - The snapshot of the ledger

    /// A ledger with no work has nothing to announce, and its snapshot is
    /// `idle`.
    @Test
    func aLedgerWithNoWorkSnapshotsIdle() async {
        let ledger = SessionStateLedger(send: RecordingSink().send)

        let snapshot = await ledger.currentSnapshot()

        #expect(ScriptedPromptFixture.isIdle(snapshot))
    }

    /// An `idle` snapshot says nothing about the last stop reason: it is not
    /// a new completion or a new cancellation.
    @Test
    func anIdleSnapshotAfterAPromptEndedAnnouncesNoStopReason() async {
        let ledger = SessionStateLedger(send: RecordingSink().send)
        await ledger.promptStarted()
        await ledger.promptEnded(IdleStateUpdate(stopReason: .cancelled), started: true)

        let snapshot = await ledger.currentSnapshot()

        guard case .idle(let idle) = snapshot else {
            Issue.record("expected idle, got \(snapshot)")
            return
        }
        #expect(idle.stopReason == nil)
    }

    /// An open prompt makes the snapshot `running`.
    @Test
    func aLedgerWithAnOpenPromptSnapshotsRunning() async {
        let ledger = SessionStateLedger(send: RecordingSink().send)
        await ledger.promptStarted()

        let snapshot = await ledger.currentSnapshot()

        #expect(isRunningState(.stateUpdate(snapshot)))
    }

    /// A question that waits for the user makes the snapshot
    /// `requires_action`, also while a prompt is open.
    @Test
    func aWaitingQuestionSnapshotsRequiresAction() async {
        let ledger = SessionStateLedger(send: RecordingSink().send)
        await ledger.promptStarted()
        await ledger.userWaitStarted("a question")

        let snapshot = await ledger.currentSnapshot()

        #expect(isRequiresActionState(.stateUpdate(snapshot)))
    }

    /// The announce sends the snapshot to the announce sink, and not to the sink of the changes.
    /// The sink of the changes records into the history.
    @Test
    func aSnapshotGoesToTheAnnounceSinkAndNotToTheSinkOfTheChanges() async {
        let changes = RecordingSink()
        let announced = RecordingSink()
        let ledger = SessionStateLedger(send: changes.send, announce: announced.send)
        await ledger.promptStarted()

        await ledger.announceCurrentState()

        #expect(stateNames(of: changes.updates) == ["running"])
        #expect(stateNames(of: announced.updates) == ["running"])
    }

    /// The announce sends the snapshot also when the last change said the
    /// same state.
    @Test
    func aSnapshotIsSentAlsoWhenItEqualsTheLastChange() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        await ledger.promptStarted()

        await ledger.announceCurrentState()

        #expect(stateNames(of: sink.updates) == ["running", "running"])
    }

    /// A later change does not overtake a snapshot that is in flight. The sink holds the snapshot.
    /// The session becomes busy. The sink then lets the snapshot go. The snapshot says `idle` and
    /// the change says `running`. The client must read them in that order, because a last `idle`
    /// would show a busy session as idle.
    @Test
    func aSnapshotInFlightIsNotOvertakenByALaterChange() async {
        let sink = GatedSink()
        let ledger = SessionStateLedger(send: sink.send)
        let snapshot = Task { await ledger.announceCurrentState() }
        await sink.firstReached.wait()
        let change = Task { await ledger.promptStarted() }
        while await !ledger.hasOpenPrompt {
            await Task.yield()
        }

        await sink.gate.open()
        await snapshot.value
        await change.value

        #expect(stateNames(of: sink.updates) == ["idle", "running"])
    }

    /// Each snapshot after a change shows the state of that change.
    @Test
    func aSnapshotAfterAChangeShowsTheStateOfThatChange() async {
        let sink = RecordingSink()
        let ledger = SessionStateLedger(send: sink.send)
        await ledger.promptStarted()
        await ledger.announceCurrentState()
        await ledger.promptEnded(IdleStateUpdate(stopReason: .endTurn), started: true)
        await ledger.announceCurrentState()

        #expect(stateNames(of: sink.updates) == ["running", "running", "idle", "idle"])
    }

    // MARK: - The replay path

    /// The replay of the history sends no `state_update`. The retained one is a record of the past,
    /// and not the current state.
    @Test
    func theReplayOfARetainedHistoryHoldsNoStateUpdate() {
        let history = SessionMergeEngine(replaying: [
            .stateUpdate(.running(RunningStateUpdate())),
            .sessionInfoUpdate(SessionInfoUpdate(title: .value("a title"))),
        ])

        let replay = history.replayUpdates(from: .start)

        #expect(stateNames(of: replay).isEmpty)
        #expect(Self.kinds(of: replay).contains(.info))
    }

    // MARK: - The wire order

    /// With `replayFrom: start` the wire order is: the replay, one current
    /// `state_update`, the `session_info_update`, and then the response.
    @Test
    func aResumeWithAReplaySendsTheReplayThenTheStateThenTheSessionInfoThenTheResponse() async throws {
        let kinds = try await Self.wireOfAResumeAfterAPrompt(label: "ResumeSyncTests-replay-order", replayFrom: .start(ReplayFromStart()))

        #expect(kinds.filter { $0 == .state }.count == 1)
        let stateIndex = try #require(kinds.firstIndex(of: .state))
        let lastMessage = try #require(kinds.lastIndex(of: .message))
        let infoIndex = try #require(kinds.lastIndex(of: .info))
        let responseIndex = try #require(kinds.firstIndex(of: .response))
        #expect(lastMessage < stateIndex)
        #expect(stateIndex < infoIndex)
        #expect(infoIndex < responseIndex)
    }

    /// With no `replayFrom` the agent sends no history, and the current
    /// `state_update` and the `session_info_update` still come before the
    /// response.
    @Test
    func aResumeWithNoReplaySendsTheStateAndTheSessionInfoBeforeTheResponseAndNoHistory() async throws {
        let kinds = try await Self.wireOfAResumeAfterAPrompt(label: "ResumeSyncTests-no-replay-order", replayFrom: nil)

        #expect(!kinds.contains(.message))
        #expect(kinds.filter { $0 == .state }.count == 1)
        let stateIndex = try #require(kinds.firstIndex(of: .state))
        let infoIndex = try #require(kinds.lastIndex(of: .info))
        let responseIndex = try #require(kinds.firstIndex(of: .response))
        #expect(stateIndex < infoIndex)
        #expect(infoIndex < responseIndex)
    }

    /// A resumed session with no prompt open shows `idle` as its current state. The recorded `idle`
    /// or `running` of the past is not sent.
    @Test
    func aResumeSendsIdleWhenNoPromptIsOpen() async throws {
        var resume = try await ResumeSessionFixture.make(label: "ResumeSyncTests-idle")
        try await resume.runPrompt("a question before the idle resume")
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let updates = try await Self.resumeAndCollect(resume, replayFrom: .start(ReplayFromStart()))
        await resume.fixture.close()

        #expect(stateNames(of: updates) == ["idle"])
        #expect(updates.compactMap(idleState(of:)).first?.stopReason == nil)
    }

    /// A session with no title and no session info gets no `session_info_update`. An empty update
    /// has no value, and the replay skips it too.
    @Test
    func aResumeOfASessionWithNoInfoSendsNoSessionInfoUpdate() async throws {
        let resume = try await ResumeSessionFixture.make(label: "ResumeSyncTests-no-info")
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let updates = try await Self.resumeAndCollect(resume)
        await resume.fixture.close()

        #expect(stateNames(of: updates) == ["idle"])
        #expect(!Self.kinds(of: updates).contains(.info))
    }

    // MARK: - The retained history

    /// The sync does not replace the retained state of the history. After a resume the history
    /// still holds the `idle` with the stop reason of the last prompt.
    @Test
    func aResumeKeepsTheRetainedIdleWithItsStopReason() async throws {
        var resume = try await ResumeSessionFixture.make(label: "ResumeSyncTests-retained-state")
        try await resume.runPrompt("a question before the resume")
        await ScriptedPromptFixture.waitForPromptsFinished(resume.fixture.harness.agent, resume.fixture.sessionId)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(resume.makeResumeRequest())
        let entry = try #require(await resume.fixture.harness.agent.sessions[resume.fixture.sessionId])
        let retained = entry.history.agentState
        await resume.fixture.close()

        guard case .idle(let idle)? = retained else {
            Issue.record("expected a retained idle, got \(String(describing: retained))")
            return
        }
        #expect(idle.stopReason == .endTurn)
    }

    // MARK: - The function of the sync

    // A resume ends each open prompt of the session. It builds a new entry with a new ledger and a
    // new relay. So at the response of a resume the ledger is busy, or a question waits, only in
    // one case. In this case work or a question starts in the gap between the activation and the
    // sync. No test can place that start in the gap. The two tests below call the function of the
    // sync on a live session. They test the function.

    /// ``RoutedACPAgent/syncCurrentState(of:)`` reads the ledger of the live
    /// session: with a prompt open the current state is `running`.
    @Test
    func syncCurrentStateSendsRunningWhenTheLedgerIsBusy() async throws {
        let resume = try await ResumeSessionFixture.make(label: "ResumeSyncTests-running")
        let agent = resume.fixture.harness.agent
        let sessionId = resume.fixture.sessionId
        let ledger = try #require(await agent.sessions[sessionId]?.stateLedger)
        await ledger.promptStarted()
        try await ScriptedPromptFixture.waitForRunning(resume.fixture.collector)

        let updates = try await Self.syncAndCollect(in: resume.fixture, count: 2, isState: isRunningState)
        await ledger.promptEnded(IdleStateUpdate(stopReason: .cancelled), started: true)
        await resume.fixture.close()

        #expect(stateNames(of: updates) == ["running"])
    }

    /// ``RoutedACPAgent/syncCurrentState(of:)`` sends `requires_action` while
    /// a question of the session waits for the user. The live change of the
    /// question went out first, and the snapshot agrees with it.
    @Test
    func syncCurrentStateSendsRequiresActionWhileAQuestionWaits() async throws {
        let question = try await OpenQuestion.open(label: "ResumeSyncTests-requires-action") {
            OpenQuestion.makeFormRequest(elicitationId: $0)
        }
        let fixture = question.fixture
        _ = try await fixture.collector.wait(for: "the live requires_action") { updates in
            updates.contains { isRequiresActionState($0.update) }
        }

        let updates = try await Self.syncAndCollect(in: fixture, count: 2, isState: isRequiresActionState)
        await question.cancel()
        await fixture.close()

        #expect(stateNames(of: updates) == ["requires_action"])
    }
}
