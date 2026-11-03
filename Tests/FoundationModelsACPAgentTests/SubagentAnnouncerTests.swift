import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The announcement of each agent run to the client: one `subagent_update` on
/// the parent session, before any message that uses the id of the child.
///
/// The `Queue` suite proves the ordered queue of ``SubagentAnnouncer`` with a
/// recording outlet. The `Wire` suite proves what the agent sends. The
/// `Join` suite proves the wait for the join entry of a tool call.
@Suite struct SubagentAnnouncerTests {
    /// The ULID of a run, as the report of a test names it.
    private static func makeRunID() -> ULID {
        ULID()
    }

    /// A report of a run in operation.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - caller: The session that started the run, or `nil` for the root.
    ///   - state: The state of the run.
    /// - Returns: The report.
    fileprivate static func makeReport(
        runID: ULID = makeRunID(), caller: ULID? = nil,
        state: StateUpdate = .running(RunningStateUpdate())
    ) -> SubagentReport {
        SubagentReport(runID: runID, caller: caller, title: "worker", description: "A worker.", state: state)
    }

    /// The full snapshot that a test outlet reports as sent.
    ///
    /// - Parameter report: The report that the outlet got.
    /// - Returns: The snapshot.
    fileprivate static func makeSnapshot(of report: SubagentReport) -> SubagentUpdate {
        SubagentUpdate(
            sessionId: SessionId(rawValue: report.runID.description), state: .value(report.state),
            title: .value(report.title))
    }

    // MARK: - The queue

    /// One call of the outlet of a test: the report and the snapshot that
    /// the announcer held for the run at that time.
    fileprivate struct Delivery: Sendable {
        /// The report that the announcer delivered.
        let report: SubagentReport

        /// The snapshot that the earlier delivery of the run made, or `nil`.
        let previous: SubagentUpdate?
    }

    /// The ordered queue of the announcer, with an outlet that records what it
    /// gets.
    @Suite struct Queue {
        /// The root session of the outlets of this suite.
        private static let rootRun = ULID()

        /// The ACP id of the root session of the outlets of this suite.
        private static let root = SessionId(rawValue: rootRun.description)

        /// The calls of an outlet, in order.
        private typealias Log = WatchedValue<[Delivery]>

        /// Makes an outlet that records each delivery and answers with
        /// `answer`.
        ///
        /// - Parameters:
        ///   - log: The record of the deliveries.
        ///   - answer: What the outlet answers for a report.
        ///   - parents: The reports that the parent lookup finds.
        /// - Returns: The outlet.
        private static func makeOutlet(
            log: Log, parents: [SubagentReport] = [],
            answer: @escaping @Sendable (SubagentReport) -> SubagentDelivery = { .sent(SubagentAnnouncerTests.makeSnapshot(of: $0)) }
        ) -> SubagentOutlet {
            SubagentOutlet(
                root: root,
                deliver: { report, previous in
                    log.update { $0.append(Delivery(report: report, previous: previous)) }
                    return answer(report)
                },
                announced: { _ in },
                parentReport: { id in parents.first { $0.runID == id } })
        }

        /// The first report of a run is delivered with no earlier snapshot.
        @Test
        func theFirstReportOfARunHasNoPreviousSnapshot() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))

            announcer.observe(SubagentAnnouncerTests.makeReport())

            let deliveries = try await log.wait(for: "one delivery") { $0.count == 1 }
            #expect(deliveries[0].previous == nil)
            await announcer.stop()
        }

        /// A changed report of the same run is delivered with the snapshot of
        /// the first delivery, so the outlet sends only the changed fields.
        @Test
        func aChangedReportCarriesTheSnapshotOfTheFirstDelivery() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let first = SubagentAnnouncerTests.makeReport()

            announcer.observe(first)
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: first.runID, state: .idle(IdleStateUpdate(stopReason: .endTurn))))

            let deliveries = try await log.wait(for: "two deliveries") { $0.count == 2 }
            #expect(deliveries[1].previous == SubagentAnnouncerTests.makeSnapshot(of: first))
            await announcer.stop()
        }

        /// A report that did not change is not delivered again: the queue
        /// holds the first report, the changed report, and the report of a
        /// last run that shows that the queue is empty.
        @Test
        func aReportThatDidNotChangeIsDeliveredOnce() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let running = SubagentAnnouncerTests.makeReport()
            let ended = SubagentAnnouncerTests.makeReport(runID: running.runID, state: .idle(IdleStateUpdate(stopReason: .endTurn)))
            let sentinel = SubagentAnnouncerTests.makeReport()

            for report in [running, running, ended, ended, sentinel] {
                announcer.observe(report)
            }

            let deliveries = try await log.wait(for: "the sentinel") { $0.contains { $0.report == sentinel } }
            #expect(deliveries.map(\.report) == [running, ended, sentinel])
            await announcer.stop()
        }

        /// A report of a run whose parent run was not announced yet comes
        /// after the report of the parent.
        @Test
        func aParentRunIsDeliveredBeforeItsChild() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let parent = SubagentAnnouncerTests.makeReport()
            let child = SubagentAnnouncerTests.makeReport(caller: parent.runID)
            announcer.bind(Self.makeOutlet(log: log, parents: [parent]))

            announcer.observe(child)

            let deliveries = try await log.wait(for: "the child") { $0.contains { $0.report == child } }
            #expect(deliveries.map(\.report) == [parent, child])
            await announcer.stop()
        }

        /// A parent that the client knows already is not delivered a second
        /// time for the report of its child. One chain of three sessions:
        /// the root, the parent run and the child run.
        @Test
        func aParentThatIsAnnouncedIsNotDeliveredAgain() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let parent = SubagentAnnouncerTests.makeReport()
            let child = SubagentAnnouncerTests.makeReport(caller: parent.runID)
            announcer.bind(Self.makeOutlet(log: log, parents: [parent]))

            announcer.observe(parent)
            announcer.observe(child)

            let deliveries = try await log.wait(for: "the child") { $0.contains { $0.report == child } }
            #expect(deliveries.map(\.report) == [parent, child])
            await announcer.stop()
        }

        /// A report of a run whose caller is the root session needs no parent
        /// delivery.
        @Test
        func aRunOfTheRootSessionHasNoParentDelivery() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let rootRun = SubagentAnnouncerTests.makeReport(caller: Self.rootRun)
            announcer.bind(Self.makeOutlet(log: log))

            announcer.observe(rootRun)

            let deliveries = try await log.wait(for: "the run") { $0.count == 1 }
            #expect(deliveries.map(\.report) == [rootRun])
            await announcer.stop()
        }

        /// A report that the outlet could not deliver is delivered again at
        /// the next observation of the run.
        @Test
        func aBlockedReportIsDeliveredAgainAtTheNextObservation() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let answers = AnswerQueue([.blocked, .sent(SubagentAnnouncerTests.makeSnapshot(of: SubagentAnnouncerTests.makeReport()))])
            announcer.bind(Self.makeOutlet(log: log) { _ in answers.next() })
            let report = SubagentAnnouncerTests.makeReport()

            announcer.observe(report)
            _ = try await log.wait(for: "the first delivery") { $0.count == 1 }
            announcer.observe(report)

            let deliveries = try await log.wait(for: "the second delivery") { $0.count == 2 }
            #expect(deliveries.map(\.report) == [report, report])
            await announcer.stop()
        }

        /// The announcer knows a run after its first delivery was sent, and
        /// not before.
        @Test
        func aRunIsAnnouncedAfterItsFirstDeliveryWasSent() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log))
            #expect(!announcer.hasAnnounced(report.runID))

            announcer.observe(report)
            _ = try await log.wait(for: "the delivery") { $0.count == 1 }
            await announcer.stop()

            #expect(announcer.hasAnnounced(report.runID))
        }

        /// A run that the outlet could not deliver is not announced.
        @Test
        func aBlockedRunIsNotAnnounced() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log) { _ in .blocked })

            announcer.observe(report)
            _ = try await log.wait(for: "the delivery") { $0.count == 1 }
            await announcer.stop()

            #expect(!announcer.hasAnnounced(report.runID))
        }

        /// A report that comes before the bind waits for it, and the bind
        /// delivers the reports in the order that they came.
        @Test
        func reportsBeforeTheBindAreDeliveredInOrderAfterIt() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let reports = (0..<3).map { _ in SubagentAnnouncerTests.makeReport() }
            for report in reports {
                announcer.observe(report)
            }

            announcer.bind(Self.makeOutlet(log: log))

            let deliveries = try await log.wait(for: "three deliveries") { $0.count == 3 }
            #expect(deliveries.map(\.report) == reports)
            await announcer.stop()
        }

        /// After the stop, a report waiting in the queue is not delivered:
        /// the first delivery holds until the stop, and the second report
        /// stays in the queue.
        @Test
        func aStoppedAnnouncerDeliversNoQueuedReport() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let released = WatchedValue(false)
            let first = SubagentAnnouncerTests.makeReport()
            let second = SubagentAnnouncerTests.makeReport()
            announcer.bind(
                SubagentOutlet(
                    root: Self.root,
                    deliver: { report, _ in
                        log.update { $0.append(Delivery(report: report, previous: nil)) }
                        _ = try? await released.wait(for: "the release") { $0 }
                        return .blocked
                    },
                    announced: { _ in },
                    parentReport: { _ in nil }))
            announcer.observe(first)
            _ = try await log.wait(for: "the first delivery") { $0.count == 1 }
            announcer.observe(second)

            async let stopped: Void = announcer.stop()
            released.update { $0 = true }
            await stopped

            #expect(log.value.map(\.report) == [first])
        }

        /// After the stop, a new report is not queued.
        @Test
        func aStoppedAnnouncerQueuesNoNewReport() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            await announcer.stop()

            announcer.observe(SubagentAnnouncerTests.makeReport())
            announcer.bind(Self.makeOutlet(log: log))
            await announcer.stop()

            #expect(log.value.isEmpty)
        }

        /// The answers of an outlet, in order. The last answer repeats.
        private final class AnswerQueue: Sendable {
            /// The answers that are left, under a lock.
            private let answers: WatchedValue<[SubagentDelivery]>

            /// Makes the queue.
            ///
            /// - Parameter answers: The answers, in order.
            init(_ answers: [SubagentDelivery]) {
                self.answers = WatchedValue(answers)
            }

            /// The next answer.
            ///
            /// - Returns: The first answer that is left.
            func next() -> SubagentDelivery {
                var taken = SubagentDelivery.blocked
                answers.update { answers in
                    taken = answers.count > 1 ? answers.removeFirst() : answers[0]
                }
                return taken
            }
        }
    }
}

// MARK: - The wait for a join entry

extension SubagentAnnouncerTests {
    /// The wait of the announcer for the entry that the join table writes for
    /// the `agents` call that started a run.
    @Suite struct Join {
        /// The completion token of the `agents` call.
        private static let token = "01AGENTSCALLTOKEN0000000001"

        /// The id that the SDK gave the `agents` call.
        private static let sdkCallId = "call-of-the-agents-tool"

        /// The wait ends when the projection writes the entry, and it gives
        /// the id of the SDK call.
        @Test
        func theWaitGivesTheSdkIdThatTheProjectionWrote() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            let waiting = Task { await joins.awaitToolCallId(for: Self.token) }

            joins.record(toolCallID: Self.sdkCallId, for: Self.token)

            #expect(await waiting.value == ToolCallId(rawValue: Self.sdkCallId))
        }

        /// While no projection is open, no entry can come, so the wait gives
        /// the completion token at once.
        @Test
        func theWaitGivesTheTokenWhenNoProjectionIsOpen() async {
            let joins = RunCallJoinTable()

            let id = await joins.awaitToolCallId(for: Self.token)

            #expect(id == ToolCallId(rawValue: Self.token))
        }

        /// The stop of the projection ends the wait with "no join", so the
        /// wait never outlives the session.
        @Test
        func theStopOfTheProjectionEndsTheWait() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            let waiting = Task { await joins.awaitToolCallId(for: Self.token) }

            joins.closeProjection()

            #expect(await waiting.value == ToolCallId(rawValue: Self.token))
        }

        /// A cancelled wait ends, so the stop of the announcer does not hang
        /// on a call that no entry reaches.
        @Test
        func aCancelledWaitEnds() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            let waiting = Task { await joins.awaitToolCallId(for: Self.token) }

            waiting.cancel()

            #expect(await waiting.value == ToolCallId(rawValue: Self.token))
        }

        /// A wait on a run that has an entry gives that entry, and the first
        /// write stays final.
        @Test
        func aRunWithAnEntryGivesItAtOnce() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            joins.record(toolCallID: Self.sdkCallId, for: Self.token)

            let id = await joins.awaitToolCallId(for: Self.token)

            #expect(id == ToolCallId(rawValue: Self.sdkCallId))
        }
    }
}

// MARK: - The wire

extension SubagentAnnouncerTests {
    /// What the agent sends to the client for an agent run.
    @Suite(.closesHarnesses) struct Wire {
        /// The prefix of the folders of each fixture of this suite.
        private static let label = "SubagentAnnouncerTests"

        /// One `subagent_update` on the wire.
        private struct Announcement {
            /// The session that the notification names: the parent.
            let parent: SessionId

            /// The update.
            let update: SubagentUpdate
        }

        /// The first text of a slow run. It is the first session event of the
        /// run, and the run holds after it.
        private static let startedText = "STARTED-TEXT"

        /// The script of the runs of this suite. The slow run gives one text
        /// delta, so its session has an event, and then it holds until the
        /// test releases it. The root session starts the slow run when its
        /// prompt names it.
        ///
        /// - Parameter hold: The hold that the slow run waits on.
        /// - Returns: The script.
        private static func makeScript(hold: ScriptedHold) -> [ScriptedPassStep] {
            [
                .onPrompt(
                    containing: AgentsToolTests.slowRunPrompt,
                    play: [
                        .textDelta(startedText), .holdUntilReleased(hold),
                        .textDelta(AgentsToolTests.slowFinalText), .endPass,
                    ]),
                .onPrompt(
                    containing: AgentsToolTests.rootSlowPrompt,
                    play: [
                        AgentsToolTests.startAgentCall(
                            agent: AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt),
                        .endPass,
                    ]),
                .endPass,
            ]
        }

        /// Wires an agent whose root session can start the slow agent, with
        /// a clock that never ends the settle period.
        ///
        /// - Parameter hold: The hold that the slow run waits on.
        /// - Returns: The fixture.
        /// - Throws: Whatever the fixture throws.
        private static func makeFixture(hold: ScriptedHold) async throws -> ScriptedPromptFixture {
            let cwd = makeResolvedDirectory(label: "\(label)-repo")
            try AgentsToolTests.writeAgent(named: AgentsToolTests.slowAgent, in: cwd)
            return try await ScriptedPromptFixture.make(
                script: makeScript(hold: hold), label: label, workingDirectory: cwd, runClock: ManualRunClock())
        }

        /// The announcer of the root session of a fixture.
        ///
        /// - Parameter fixture: The fixture.
        /// - Returns: The announcer.
        /// - Throws: A failed requirement when the root session has no
        ///   `agents` mount.
        private static func announcer(of fixture: ScriptedPromptFixture) async throws -> SubagentAnnouncer {
            try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents?.announcer)
        }

        /// Starts a host-driven run of the slow agent, which holds.
        ///
        /// - Parameter fixture: The fixture.
        /// - Returns: The run.
        /// - Throws: Whatever the start throws.
        private static func startSlowRun(in fixture: ScriptedPromptFixture) async throws -> AgentRun {
            let agents = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents)
            return try await agents.runner.start(AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt)
        }

        /// The `subagent_update` of a notification.
        ///
        /// - Parameter notification: The notification.
        /// - Returns: The announcement, or `nil` for another update.
        private static func announcement(in notification: UpdateSessionNotification) -> Announcement? {
            if case .subagentUpdate(let update) = notification.update {
                return Announcement(parent: notification.sessionId, update: update)
            }
            return nil
        }

        /// The link to the tool call that an announcement carries.
        ///
        /// - Parameter update: The announcement.
        /// - Returns: The link, or `nil` when the announcement has none.
        private static func link(of update: SubagentUpdate) -> SAH.AgentRun? {
            if case .value(let meta) = update.meta {
                return SAH.AgentRun.extract(from: meta)
            }
            return nil
        }

        /// The announcements of a sequence, in wire order.
        ///
        /// - Parameter updates: The collected notifications.
        /// - Returns: The announcements.
        private static func announcements(in updates: [UpdateSessionNotification]) -> [Announcement] {
            updates.compactMap(announcement(in:))
        }

        /// The announcements of one child, in wire order.
        ///
        /// - Parameters:
        ///   - child: The id of the child.
        ///   - updates: The collected notifications.
        /// - Returns: The announcements of the child.
        private static func announcements(
            of child: SessionId, in updates: [UpdateSessionNotification]
        ) -> [Announcement] {
            announcements(in: updates).filter { $0.update.sessionId == child }
        }

        /// Whether a notification uses the id of `child`: it is on the
        /// session of the child, or it is an update for the child.
        ///
        /// - Parameters:
        ///   - notification: The notification.
        ///   - child: The id of the child.
        /// - Returns: `true` when it names the child.
        private static func names(_ notification: UpdateSessionNotification, child: SessionId) -> Bool {
            notification.sessionId == child || announcement(in: notification)?.update.sessionId == child
        }

        /// The ACP id of a run.
        ///
        /// - Parameter run: The run.
        /// - Returns: The id of its session.
        private static func sessionId(of run: AgentRun) -> SessionId {
            SessionId(rawValue: run.id.description)
        }

        /// Releases the hold, then closes the fixture.
        ///
        /// - Parameters:
        ///   - fixture: The fixture.
        ///   - hold: The hold of the slow run.
        private static func finish(_ fixture: ScriptedPromptFixture, releasing hold: ScriptedHold) async {
            hold.release()
            await fixture.close()
        }

        // MARK: The first message

        /// The first wire message that uses the id of a child is the
        /// `subagent_update` for that id, on the parent session.
        @Test
        func theFirstMessageOfAChildIsItsSubagentUpdateOnTheParent() async throws {
            let hold = ScriptedHold()
            let fixture = try await Self.makeFixture(hold: hold)
            let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))

            let updates = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }

            let first = try #require(updates.first { Self.names($0, child: child) })
            #expect(first.sessionId == fixture.sessionId)
            #expect(Self.announcement(in: first)?.update.sessionId == child)
            await Self.finish(fixture, releasing: hold)
        }

        /// The announcement names the agent, its description, the cancel
        /// capability, the running state and the place of the child. A run
        /// that no tool call started has no link.
        @Test
        func theAnnouncementCarriesTheFieldsOfTheRun() async throws {
            let hold = ScriptedHold()
            let fixture = try await Self.makeFixture(hold: hold)
            let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))

            let updates = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }

            let update = try #require(Self.announcements(of: child, in: updates).first).update
            #expect(update.title == .value(AgentsToolTests.slowAgent))
            #expect(update.description == .value("The \(AgentsToolTests.slowAgent) test agent."))
            #expect(update.capabilities == .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities())))
            #expect(update.state == .value(.running(RunningStateUpdate())))
            #expect(update.cwd == .value(AbsolutePath(rawValue: fixture.cwd.path)))
            #expect(update.additionalDirectories == .value([]))
            #expect(update.meta == .unchanged)
            await Self.finish(fixture, releasing: hold)
        }

        /// The retained history of the parent holds the announcement, so a
        /// `session/resume` of the parent replays it.
        @Test
        func theRetainedHistoryOfTheParentHoldsTheAnnouncement() async throws {
            let hold = ScriptedHold()
            let fixture = try await Self.makeFixture(hold: hold)
            let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))
            _ = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }

            let history = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.history)

            #expect(history.subagents.map(\.sessionId) == [child])
            await Self.finish(fixture, releasing: hold)
        }

        // MARK: The link

        /// The announcement of a run that an `agents` call started names the
        /// tool call id that is on the wire for that call.
        @Test
        func theAnnouncementLinksTheToolCallThatStartedTheRun() async throws {
            let hold = ScriptedHold()
            let fixture = try await Self.makeFixture(hold: hold)
            let prompt = Task {
                try await fixture.harness.connection.prompt(
                    AgentClientHarness.makePromptRequest(
                        sessionId: fixture.sessionId, text: AgentsToolTests.rootSlowPrompt))
            }

            let updates = try await fixture.collector.wait(for: "the linked announcement") { updates in
                Self.announcements(in: updates).contains { $0.update.meta != .unchanged }
            }

            let update = try #require(Self.announcements(in: updates).first).update
            let link = try #require(Self.link(of: update))
            let toolCall = try #require(
                updates.compactMap { notification -> ToolCallUpdate? in
                    if case .toolCallUpdate(let call) = notification.update { return call }
                    return nil
                }.first)
            #expect(link.toolCallId == toolCall.toolCallId)
            hold.release()
            _ = try await prompt.value
            await fixture.close()
        }

        // MARK: The patch

        /// A run that ended sends only its changed state. The title, the
        /// link and the place stay unchanged, and no second full
        /// announcement goes out, also when the run is observed again.
        @Test
        func aChangedStateSendsOnlyTheState() async throws {
            let hold = ScriptedHold()
            let fixture = try await Self.makeFixture(hold: hold)
            let announcer = try await Self.announcer(of: fixture)
            let run = try await Self.startSlowRun(in: fixture)
            let child = Self.sessionId(of: run)
            _ = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }

            hold.release()
            _ = try await run.result()
            announcer.observe(run)
            let updates = try await fixture.collector.wait(for: "the patch") {
                Self.announcements(of: child, in: $0).count == 2
            }
            announcer.observe(run)
            await fixture.close()

            let sent = Self.announcements(of: child, in: await fixture.collector.updates)
            #expect(sent.count == 2)
            let patch = try #require(Self.announcements(of: child, in: updates).last).update
            #expect(
                patch
                    == SubagentUpdate(
                        sessionId: child, state: .value(.idle(IdleStateUpdate(stopReason: .endTurn)))))
        }

        // MARK: The chain

        /// One chain of three sessions: the root, a child and a grandchild.
        /// The child is announced on the root, then the grandchild is
        /// announced on the child.
        @Test
        func aGrandchildIsAnnouncedOnTheChildAfterTheChild() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let announcer = try await Self.announcer(of: fixture)
            let child = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: fixture.sessionId)
            let grandchild = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: child)
            let childRun = try #require(ULID(ulidString: child.rawValue))
            let grandchildRun = try #require(ULID(ulidString: grandchild.rawValue))

            announcer.observe(SubagentAnnouncerTests.makeReport(runID: childRun))
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: grandchildRun, caller: childRun))

            let updates = try await fixture.collector.wait(for: "both announcements") {
                Self.announcements(in: $0).count == 2
            }
            let sent = Self.announcements(in: updates)
            #expect(sent.map(\.parent) == [fixture.sessionId, child])
            #expect(sent.map(\.update.sessionId) == [child, grandchild])
            await fixture.close()
        }

        /// A child whose parent is not announced yet waits: the agent sends
        /// nothing for it, and it goes out at its next report, after the
        /// parent.
        @Test
        func aChildWaitsForItsParentToBeAnnounced() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let announcer = try await Self.announcer(of: fixture)
            let child = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: fixture.sessionId)
            let grandchild = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: child)
            let childRun = try #require(ULID(ulidString: child.rawValue))
            let grandchildReport = SubagentAnnouncerTests.makeReport(
                runID: try #require(ULID(ulidString: grandchild.rawValue)), caller: childRun)

            announcer.observe(grandchildReport)
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: childRun))
            _ = try await fixture.collector.wait(for: "the child") {
                !Self.announcements(of: child, in: $0).isEmpty
            }
            announcer.observe(grandchildReport)

            let updates = try await fixture.collector.wait(for: "the grandchild") {
                !Self.announcements(of: grandchild, in: $0).isEmpty
            }
            #expect(Self.announcements(in: updates).map(\.update.sessionId) == [child, grandchild])
            await fixture.close()
        }

        // MARK: The gate

        /// A session that the agent registers after its announcement starts
        /// with an open gate, because the client knows it already.
        @Test
        func aSessionRegisteredAfterItsAnnouncementStartsOpen() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let agent = fixture.harness.agent
            let announcer = try await Self.announcer(of: fixture)
            let parentSession = try #require(await agent.sessions[fixture.sessionId]?.session)
            let nested = SessionSetupNestedTests.makeNestedRouterSession(below: parentSession)
            let child = SessionId(rawValue: nested.id.description)
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: nested.id))
            _ = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }

            try await agent.registerNestedSession(nested, parent: fixture.sessionId)

            #expect(await agent.sessions[child]?.announcement.isOpen == true)
            await fixture.close()
        }

        /// The updates of a child race its announcement. No update of the
        /// child leaves before the `subagent_update`, and an update that
        /// the child sends after the announcement goes out.
        @Test
        func noUpdateOfTheChildLeavesBeforeItsAnnouncementUnderARace() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let agent = fixture.harness.agent
            let announcer = try await Self.announcer(of: fixture)
            let child = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: fixture.sessionId)
            let entry = try #require(await agent.sessions[child])
            let childRun = try #require(ULID(ulidString: child.rawValue))
            let racingUpdates = 20

            await withTaskGroup(of: Void.self) { group in
                group.addTask { announcer.observe(SubagentAnnouncerTests.makeReport(runID: childRun)) }
                for _ in 0..<racingUpdates {
                    group.addTask { await entry.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate()) }
                }
            }
            _ = try await fixture.collector.wait(for: "the announcement") {
                !Self.announcements(of: child, in: $0).isEmpty
            }
            await entry.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate())
            let updates = try await fixture.collector.wait(for: "a message of the child") { updates in
                updates.contains { $0.sessionId == child }
            }

            let firstIndex = try #require(updates.firstIndex { Self.names($0, child: child) })
            #expect(Self.announcement(in: updates[firstIndex])?.update.sessionId == child)
            await fixture.close()
        }

        // MARK: The closed cases

        /// A session that is closed gets no announcement.
        @Test
        func aClosedSessionGetsNoAnnouncement() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let agent = fixture.harness.agent
            _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))

            let delivery = await agent.deliverSubagentReport(
                SubagentAnnouncerTests.makeReport(), replacing: nil, root: fixture.sessionId)

            #expect(delivery == .blocked)
            await fixture.close()
        }

        /// A session whose connection is gone gets no announcement, and the
        /// retained history keeps nothing of it.
        @Test
        func aSessionWithoutAConnectionGetsNoAnnouncement() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let agent = fixture.harness.agent
            let owner = try #require(agent.connections.owner(of: fixture.sessionId))
            agent.connections.remove(owner)

            let delivery = await agent.deliverSubagentReport(
                SubagentAnnouncerTests.makeReport(), replacing: nil, root: fixture.sessionId)

            #expect(delivery == .blocked)
            #expect(await agent.sessions[fixture.sessionId]?.history.subagents.isEmpty == true)
            // The agent closed the table row of the connection, so the
            // session/close request cannot reach it: the close of the wire
            // closes the session.
            await fixture.harness.close()
        }

        /// The close of the root session stops the announcer.
        @Test
        func theCloseOfTheSessionStopsTheAnnouncer() async throws {
            let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
            let announcer = try await Self.announcer(of: fixture)
            _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))

            #expect(announcer.isStopped)
            await fixture.close()
        }
    }
}
