import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The announcement of each agent run to the client. One `subagent_update` goes out on the parent
/// session, before any message that uses the id of the child.
///
/// The `Queue` suite proves the queue of ``SubagentAnnouncer`` with a
/// recording outlet. The `Patch` suite proves the patch of two snapshots. The
/// `Join` suite proves the wait for the join entry of a tool call. The wire
/// tests are in `SubagentAnnouncerWireTests.swift`.
@Suite struct SubagentAnnouncerTests {
    /// A report of a run in operation.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - caller: The session that started the run, or `nil` for the root.
    ///   - state: The state of the run.
    ///   - completionToken: The token of the `agents` call that started the
    ///     run, or `nil` for a run of the host.
    /// - Returns: The report.
    static func makeReport(
        runID: ULID = ULID(), caller: ULID? = nil,
        state: StateUpdate = .running(RunningStateUpdate()), completionToken: String? = nil
    ) -> SubagentReport {
        SubagentReport(
            runID: runID, caller: caller, title: "worker", description: "A worker.", state: state,
            completionToken: completionToken)
    }

    /// The state of a run that ended.
    static let endedState = StateUpdate.idle(IdleStateUpdate(stopReason: .endTurn))

    /// The full snapshot that a test outlet reports as sent.
    ///
    /// - Parameter report: The report that the outlet got.
    /// - Returns: The snapshot.
    static func makeSnapshot(of report: SubagentReport) -> SubagentUpdate {
        SubagentUpdate(
            sessionId: SessionId(rawValue: report.runID.description), state: .value(report.state),
            title: .value(report.title))
    }

    /// One call of the outlet of a test. It holds the report, the snapshot that the announcer held
    /// for the run at that time, and the link.
    struct Delivery: Sendable {
        /// The report that the announcer delivered.
        let report: SubagentReport

        /// The snapshot that the earlier delivery of the run made, or `nil`.
        let previous: SubagentUpdate?

        /// The wire id of the `agents` call that the announcer passed, or `nil`.
        let link: ToolCallId?
    }
}

// MARK: - The queue

extension SubagentAnnouncerTests {
    /// The queue of the announcer, with an outlet that records what it gets.
    @Suite(.timeLimit(.minutes(1))) struct Queue {
        /// The root session of the outlets of this suite.
        private static let rootRun = ULID()

        /// The ACP id of the root session of the outlets of this suite.
        private static let root = SessionId(rawValue: rootRun.description)

        /// The calls of an outlet, in order.
        private typealias Log = WatchedValue<[Delivery]>

        /// The final reports that an outlet settled, in order.
        private typealias Settlements = WatchedValue<[SubagentReport]>

        /// Makes an outlet that records each delivery and answers with
        /// `answer`.
        ///
        /// - Parameters:
        ///   - log: The record of the deliveries.
        ///   - parents: The reports that the parent lookup finds.
        ///   - link: What the outlet finds as the link of a run.
        ///   - answer: What the outlet answers for a report.
        /// - Returns: The outlet.
        private static func makeOutlet(
            log: Log, parents: [SubagentReport] = [], settlements: Settlements? = nil,
            link: @escaping @Sendable (SubagentReport) async -> SubagentLink = { _ in .none },
            answer: @escaping @Sendable (SubagentReport) async -> SubagentDelivery = {
                .sent(SubagentAnnouncerTests.makeSnapshot(of: $0))
            }
        ) -> SubagentOutlet {
            SubagentOutlet(
                root: root,
                link: link,
                deliver: { report, previous, link, _ in
                    log.update { $0.append(Delivery(report: report, previous: previous, link: link)) }
                    return await answer(report)
                },
                session: { _ in nil },
                settle: { report in settlements?.update { $0.append(report) } },
                parentReport: { id in parents.first { $0.runID == id } })
        }

        /// Waits until a run was delivered at least `count` times.
        ///
        /// - Parameters:
        ///   - log: The record of the deliveries.
        ///   - runID: The run.
        ///   - count: The number of deliveries.
        /// - Returns: The deliveries so far.
        /// - Throws: A failed wait.
        @discardableResult
        private static func wait(_ log: Log, for runID: ULID, times count: Int = 1) async throws -> [Delivery] {
            try await log.wait(for: "\(count) delivery of the run") { deliveries in
                deliveries.filter { $0.report.runID == runID }.count >= count
            }
        }

        /// Waits until the announcer holds no state of any run. The wait has a
        /// limit, so a state that stays gives a failed test and no hang.
        ///
        /// - Parameter announcer: The announcer.
        /// - Returns: The number of runs with a state at the end of the wait.
        private static func trackedRunCountAfterSettling(_ announcer: SubagentAnnouncer) async -> Int {
            let deadline = ContinuousClock.now + .seconds(5)
            while announcer.trackedRunCount != 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return announcer.trackedRunCount
        }

        /// Counts the deliveries of one run.
        ///
        /// - Parameters:
        ///   - log: The record of the deliveries.
        ///   - runID: The run.
        /// - Returns: The count.
        private static func deliveryCount(_ log: Log, of runID: ULID) -> Int {
            log.value.filter { $0.report.runID == runID }.count
        }

        // MARK: Order and dedupe

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

        /// A changed report of the same run is delivered with the snapshot of the first delivery.
        /// So the outlet sends only the changed fields.
        @Test
        func aChangedReportCarriesTheSnapshotOfTheFirstDelivery() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let first = SubagentAnnouncerTests.makeReport()

            announcer.observe(first)
            try await Self.wait(log, for: first.runID)
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: first.runID, state: SubagentAnnouncerTests.endedState))

            let deliveries = try await Self.wait(log, for: first.runID, times: 2)
            #expect(deliveries[1].previous == SubagentAnnouncerTests.makeSnapshot(of: first))
            await announcer.stop()
        }

        /// Events that come while a delivery of the run is in flight are not
        /// lost and not doubled. A report that equals the handled one is not
        /// queued. The changed report is delivered once.
        @Test
        func eventsDuringADeliveryAreDeliveredOnceAfterIt() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let released = WatchedValue(false)
            let running = SubagentAnnouncerTests.makeReport()
            let ended = SubagentAnnouncerTests.makeReport(runID: running.runID, state: SubagentAnnouncerTests.endedState)
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    if report == running {
                        _ = try? await released.wait(for: "the release") { $0 }
                    }
                    return .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                }))
            announcer.observe(running)
            _ = try await Self.wait(log, for: running.runID)

            for report in [running, ended, ended, sentinel] {
                announcer.observe(report)
            }
            released.update { $0 = true }

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
        /// time for the report of its child.
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

        /// A report that comes before the bind waits for it. The bind then delivers the runs in the
        /// order that they came.
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

        // MARK: The observer never waits

        /// The observer returns while the consumer is blocked in a delivery.
        @Test
        func observeReturnsWhileTheConsumerIsBlockedInADelivery() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let released = WatchedValue(false)
            let first = SubagentAnnouncerTests.makeReport()
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    _ = try? await released.wait(for: "the release") { $0 }
                    return .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                }))
            announcer.observe(first)
            _ = try await Self.wait(log, for: first.runID)

            announcer.observe(SubagentAnnouncerTests.makeReport())
            announcer.observe(SubagentAnnouncerTests.makeReport(runID: first.runID, state: SubagentAnnouncerTests.endedState))

            #expect(log.value.count == 1)
            released.update { $0 = true }
            await announcer.stop()
        }

        // MARK: The links

        /// A run that no call started (a run of the host) has no link and is
        /// announced at once. The announcer never asks for its link.
        @Test
        func aRunOfTheHostIsAnnouncedAtOnceWithoutALink() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let asked = WatchedValue(0)
            announcer.bind(
                Self.makeOutlet(log: log) { _ in
                    asked.update { $0 += 1 }
                    return .unavailable
                })
            let report = SubagentAnnouncerTests.makeReport()

            announcer.observe(report)

            let deliveries = try await Self.wait(log, for: report.runID)
            #expect(deliveries[0].link == nil)
            #expect(asked.value == 0)
            await announcer.stop()
        }

        /// A run that an `agents` call started is delivered with the wire id
        /// that the outlet found.
        @Test
        func aRunOfAnAgentsCallIsDeliveredWithItsWireId() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let callId = ToolCallId(rawValue: "wire-id")
            announcer.bind(Self.makeOutlet(log: log) { _ in .callId(callId) })
            let report = SubagentAnnouncerTests.makeReport(completionToken: "token")

            announcer.observe(report)

            let deliveries = try await Self.wait(log, for: report.runID)
            #expect(deliveries[0].link == callId)
            await announcer.stop()
        }

        /// A run whose entry does not come holds no other run. A run of the
        /// host behind it is announced at once. The waiting run follows when
        /// its entry comes.
        @Test
        func aRunThatWaitsForItsLinkHoldsNoOtherRun() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let entry = WatchedValue<ToolCallId?>(nil)
            announcer.bind(
                Self.makeOutlet(log: log) { _ in
                    guard let id = try? await entry.wait(for: "the entry", until: { $0 != nil }) else {
                        return .unavailable
                    }
                    return .callId(id)
                })
            let waiting = SubagentAnnouncerTests.makeReport(completionToken: "token")
            let behind = SubagentAnnouncerTests.makeReport()

            announcer.observe(waiting)
            announcer.observe(behind)

            let before = try await Self.wait(log, for: behind.runID)
            #expect(!before.contains { $0.report.runID == waiting.runID })
            entry.update { $0 = ToolCallId(rawValue: "wire-id") }
            let after = try await Self.wait(log, for: waiting.runID)
            #expect(after.last?.link == ToolCallId(rawValue: "wire-id"))
            await announcer.stop()
        }

        /// A run whose link cannot be found now is blocked, and the retry
        /// asks again.
        @Test
        func aRunWithoutAnAvailableLinkIsAnnouncedAfterTheRetry() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let answers = WatchedValue([SubagentLink.unavailable, .callId(ToolCallId(rawValue: "wire-id"))])
            let asked = WatchedValue(0)
            announcer.bind(
                Self.makeOutlet(log: log) { _ in
                    asked.update { $0 += 1 }
                    var answer = SubagentLink.unavailable
                    answers.update { answers in answer = answers.count > 1 ? answers.removeFirst() : answers[0] }
                    return answer
                })
            let report = SubagentAnnouncerTests.makeReport(completionToken: "token")
            announcer.observe(report)
            _ = try await asked.wait(for: "the first ask") { $0 == 1 }

            announcer.retryBlocked()

            let deliveries = try await Self.wait(log, for: report.runID)
            #expect(deliveries.map(\.link) == [ToolCallId(rawValue: "wire-id")])
            await announcer.stop()
        }

        /// A retry that comes while the link is being found is not lost. The
        /// attempt ends with no link, and the run is tried again at once.
        @Test
        func aRetryDuringTheWaitForALinkIsNotLost() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let entered = WatchedValue(0)
            let released = WatchedValue(false)
            announcer.bind(
                Self.makeOutlet(log: log) { _ in
                    var attempt = 0
                    entered.update { $0 += 1; attempt = $0 }
                    guard attempt > 1 else {
                        _ = try? await released.wait(for: "the release") { $0 }
                        return .unavailable
                    }
                    return .callId(ToolCallId(rawValue: "wire-id"))
                })
            let report = SubagentAnnouncerTests.makeReport(completionToken: "token")
            announcer.observe(report)
            _ = try await entered.wait(for: "the first attempt") { $0 == 1 }

            announcer.retryBlocked()
            released.update { $0 = true }

            let deliveries = try await Self.wait(log, for: report.runID)
            #expect(deliveries[0].link == ToolCallId(rawValue: "wire-id"))
            await announcer.stop()
        }

        /// A retry that comes while a delivery is in flight is not lost. The delivery ends blocked,
        /// and the run is delivered again at once.
        @Test
        func aRetryDuringABlockedDeliveryIsNotLost() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let released = WatchedValue(false)
            announcer.bind(
                Self.makeOutlet(
                    log: log,
                    answer: { report in
                        guard log.value.count > 1 else {
                            _ = try? await released.wait(for: "the release") { $0 }
                            return .blocked
                        }
                        return .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                    }))
            let report = SubagentAnnouncerTests.makeReport()
            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)

            announcer.retryBlocked()
            released.update { $0 = true }

            try await Self.wait(log, for: report.runID, times: 2)
            await announcer.stop()
        }

        /// The stop ends the wait for a link, and nothing is delivered.
        @Test
        func theStopEndsTheWaitForALink() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let waiting = WatchedValue(0)
            let never = WatchedValue(false)
            announcer.bind(
                Self.makeOutlet(log: log) { _ in
                    waiting.update { $0 += 1 }
                    guard (try? await never.wait(for: "never", until: { $0 })) != nil else {
                        return .unavailable
                    }
                    return .none
                })
            announcer.observe(SubagentAnnouncerTests.makeReport(completionToken: "token"))
            _ = try await waiting.wait(for: "the wait") { $0 == 1 }

            await announcer.stop()

            #expect(log.value.isEmpty)
        }

        // MARK: Blocked runs

        /// A report that the outlet could not deliver is delivered again at the retry. The retry
        /// uses the newest report of the run.
        @Test
        func aBlockedReportIsDeliveredAgainAtTheRetry() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let answers = WatchedValue([SubagentDelivery.blocked])
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    var answer = SubagentDelivery.sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                    answers.update { answers in
                        if let first = answers.first {
                            answer = first
                            answers.removeFirst()
                        }
                    }
                    return answer
                }))
            let report = SubagentAnnouncerTests.makeReport()
            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)

            announcer.retryBlocked()

            let deliveries = try await Self.wait(log, for: report.runID, times: 2)
            #expect(deliveries.map(\.report) == [report, report])
            await announcer.stop()
        }

        /// An event that equals the report in flight is not lost when the delivery ends blocked.
        /// The retry delivers the run.
        @Test
        func anEqualEventDuringABlockedDeliveryIsNotLost() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let released = WatchedValue(false)
            let first = WatchedValue(true)
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    var isFirst = false
                    first.update { isFirst = $0; $0 = false }
                    guard isFirst else {
                        return .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                    }
                    _ = try? await released.wait(for: "the release") { $0 }
                    return .blocked
                }))
            let report = SubagentAnnouncerTests.makeReport()
            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)
            announcer.observe(report)
            released.update { $0 = true }
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.observe(sentinel)
            _ = try await Self.wait(log, for: sentinel.runID)

            announcer.retryBlocked()

            try await Self.wait(log, for: report.runID, times: 2)
            await announcer.stop()
        }

        /// A blocked run costs no work for a later event. The outlet gets no second delivery and no
        /// parent lookup until the retry.
        @Test
        func aBlockedRunCostsNoWorkForLaterEvents() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log, answer: { _ in .blocked }))
            let blocked = SubagentAnnouncerTests.makeReport()
            announcer.observe(blocked)
            _ = try await Self.wait(log, for: blocked.runID)

            for index in 0..<5 {
                announcer.observe(
                    SubagentReport(
                        runID: blocked.runID, caller: nil, title: "event \(index)", description: nil,
                        state: .running(RunningStateUpdate())))
            }
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.observe(sentinel)
            let deliveries = try await Self.wait(log, for: sentinel.runID)

            #expect(deliveries.filter { $0.report.runID == blocked.runID }.count == 1)
            await announcer.stop()
        }

        /// The end of a run is an event that retries a blocked run. So a child is never gated for
        /// good.
        @Test
        func theEndOfARunRetriesABlockedRun() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let answers = WatchedValue([SubagentDelivery.blocked])
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    var answer = SubagentDelivery.sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                    answers.update { answers in
                        if let first = answers.first {
                            answer = first
                            answers.removeFirst()
                        }
                    }
                    return answer
                }))
            let running = SubagentAnnouncerTests.makeReport()
            announcer.observe(running)
            _ = try await Self.wait(log, for: running.runID)

            announcer.observe(
                SubagentAnnouncerTests.makeReport(runID: running.runID, state: SubagentAnnouncerTests.endedState),
                isFinal: true)

            let deliveries = try await Self.wait(log, for: running.runID, times: 2)
            #expect(deliveries[1].report.state == SubagentAnnouncerTests.endedState)
            await announcer.stop()
        }

        // MARK: The state of a run

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
            _ = try await Self.wait(log, for: report.runID)
            await announcer.stop()

            #expect(announcer.hasAnnounced(report.runID))
        }

        /// A run that the outlet could not deliver is not announced.
        @Test
        func aBlockedRunIsNotAnnounced() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log, answer: { _ in .blocked }))

            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)
            await announcer.stop()

            #expect(!announcer.hasAnnounced(report.runID))
        }

        /// The final report of a run, once handled, ends the state of the run. The announcer holds
        /// nothing of a run that ended.
        @Test
        func theFinalReportEndsTheStateOfTheRun() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let running = SubagentAnnouncerTests.makeReport()
            announcer.observe(running)
            _ = try await Self.wait(log, for: running.runID)
            #expect(announcer.hasAnnounced(running.runID))

            announcer.observe(
                SubagentAnnouncerTests.makeReport(runID: running.runID, state: SubagentAnnouncerTests.endedState),
                isFinal: true)
            _ = try await Self.wait(log, for: running.runID, times: 2)
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.observe(sentinel)
            _ = try await Self.wait(log, for: sentinel.runID)

            #expect(!announcer.hasAnnounced(running.runID))
            await announcer.stop()
        }


        /// The final report of a run settles the run once, after the outlet delivered the final
        /// report. The outlet then sends the last updates of the child and ends it.
        @Test
        func theFinalReportSettlesTheRunAfterItsDelivery() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let settlements = Settlements([])
            announcer.bind(Self.makeOutlet(log: log, settlements: settlements))
            let running = SubagentAnnouncerTests.makeReport()
            announcer.observe(running)
            _ = try await Self.wait(log, for: running.runID)
            let ended = SubagentAnnouncerTests.makeReport(
                runID: running.runID, state: SubagentAnnouncerTests.endedState)

            announcer.observe(ended, isFinal: true)

            let settled = try await settlements.wait(for: "the settlement of the run") { !$0.isEmpty }
            #expect(settled == [ended])
            #expect(Self.deliveryCount(log, of: running.runID) == 2)
            await announcer.stop()
        }

        /// A run that ended with a blocked outlet settles too: its child must end although the
        /// client never learned of it.
        @Test
        func aFinalRunWhoseOutletBlocksSettles() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let settlements = Settlements([])
            announcer.bind(Self.makeOutlet(log: log, settlements: settlements, answer: { _ in .blocked }))
            let ended = SubagentAnnouncerTests.makeReport(state: SubagentAnnouncerTests.endedState)

            announcer.observe(ended, isFinal: true)

            let settled = try await settlements.wait(for: "the settlement of the run") { !$0.isEmpty }
            #expect(settled == [ended])
            await announcer.stop()
        }

        /// A final run whose last try ends blocked holds no state. A nested
        /// run of an `agents` call has no parent entry, so each try ends so.
        @Test
        func aFinalRunWhoseOutletBlocksHoldsNoState() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log, answer: { _ in .blocked }))
            let running = SubagentAnnouncerTests.makeReport()
            announcer.observe(running)
            _ = try await Self.wait(log, for: running.runID)

            announcer.observe(
                SubagentAnnouncerTests.makeReport(runID: running.runID, state: SubagentAnnouncerTests.endedState),
                isFinal: true)

            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)
            await announcer.stop()
        }

        /// A final run whose link is not found at the last try holds no state.
        @Test
        func aFinalRunWhoseLinkIsUnavailableHoldsNoState() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let links = WatchedValue(0)
            announcer.bind(
                Self.makeOutlet(
                    log: log,
                    link: { _ in
                        links.update { $0 += 1 }
                        return .unavailable
                    }))
            let running = SubagentAnnouncerTests.makeReport(completionToken: "token")
            announcer.observe(running)
            _ = try await links.wait(for: "the first ask") { $0 >= 1 }

            announcer.observe(
                SubagentAnnouncerTests.makeReport(
                    runID: running.runID, state: SubagentAnnouncerTests.endedState, completionToken: "token"),
                isFinal: true)

            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)
            await announcer.stop()
        }

        /// A final report that equals the handled report is not queued, and
        /// the state of the run still ends.
        @Test
        func aFinalReportEqualToTheHandledReportEndsTheState() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let ended = SubagentAnnouncerTests.makeReport(state: SubagentAnnouncerTests.endedState)
            announcer.observe(ended)
            _ = try await Self.wait(log, for: ended.runID)

            announcer.observe(ended, isFinal: true)

            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)
            await announcer.stop()
        }

        /// A late event of a run that ended does nothing. The client knows the child, so it gets no
        /// second full announcement.
        @Test
        func anEventAfterTheEndOfTheRunSendsNothing() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let ended = SubagentAnnouncerTests.makeReport(state: SubagentAnnouncerTests.endedState)
            announcer.observe(ended, isFinal: true)
            _ = try await Self.wait(log, for: ended.runID)
            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)
            let watches = Mutex(0)

            announcer.observe(
                runID: ended.runID, watchEnd: { watches.withLock { $0 += 1 } },
                makeReport: { SubagentAnnouncerTests.makeReport(runID: ended.runID) })
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.observe(sentinel)
            _ = try await Self.wait(log, for: sentinel.runID)

            #expect(Self.deliveryCount(log, of: ended.runID) == 1)
            #expect(watches.withLock { $0 } == 0)
            await announcer.stop()
        }

        /// A parent that ended counts as announced. A child that outlives its
        /// parent does not announce the parent again.
        @Test
        func aChildThatOutlivesItsParentDoesNotAnnounceTheParentAgain() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let parent = SubagentAnnouncerTests.makeReport()
            let child = SubagentAnnouncerTests.makeReport(caller: parent.runID)
            announcer.bind(Self.makeOutlet(log: log, parents: [parent]))
            announcer.observe(parent)
            _ = try await Self.wait(log, for: parent.runID)
            announcer.observe(
                SubagentAnnouncerTests.makeReport(runID: parent.runID, state: SubagentAnnouncerTests.endedState),
                isFinal: true)
            _ = try await Self.wait(log, for: parent.runID, times: 2)
            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)

            announcer.observe(child)
            _ = try await Self.wait(log, for: child.runID)

            #expect(Self.deliveryCount(log, of: parent.runID) == 2)
            #expect(announcer.trackedRunCount == 1)
            await announcer.stop()
        }

        /// A child waits for a parent that is not announced. When the parent
        /// ends blocked and its state is dropped, the child is tried again.
        @Test
        func aChildWaitingForAParentIsTriedAgainWhenTheParentEnds() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let parent = SubagentAnnouncerTests.makeReport()
            let child = SubagentAnnouncerTests.makeReport(caller: parent.runID)
            announcer.bind(
                Self.makeOutlet(
                    log: log, parents: [parent],
                    answer: { report in
                        report.runID == parent.runID ? .blocked : .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                    }))
            announcer.observe(child)
            _ = try await Self.wait(log, for: parent.runID)

            announcer.observe(
                SubagentAnnouncerTests.makeReport(runID: parent.runID, state: SubagentAnnouncerTests.endedState),
                isFinal: true)

            _ = try await Self.wait(log, for: child.runID)
            await announcer.stop()
        }

        /// A blocked and watched run builds no report for a later event. The retry delivers the
        /// report that the announcer held.
        @Test
        func aBlockedRunBuildsNoReportForALaterEvent() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let blocking = WatchedValue(true)
            announcer.bind(
                Self.makeOutlet(log: log, answer: { report in
                    blocking.value ? .blocked : .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
                }))
            let held = SubagentAnnouncerTests.makeReport()
            let builds = Mutex(0)
            let observeEvent = {
                announcer.observe(
                    runID: held.runID, watchEnd: {},
                    makeReport: {
                        builds.withLock { $0 += 1 }
                        return held
                    })
            }
            observeEvent()
            _ = try await Self.wait(log, for: held.runID)
            let sentinel = SubagentAnnouncerTests.makeReport()
            announcer.observe(sentinel)
            _ = try await Self.wait(log, for: sentinel.runID)

            observeEvent()
            blocking.update { $0 = false }
            announcer.retryBlocked()

            _ = try await Self.wait(log, for: held.runID, times: 2)
            #expect(builds.withLock { $0 } == 1)
            await announcer.stop()
        }

        // MARK: The gate

        /// The gate of a run opens after its announcement was sent. This holds
        /// also when the session took the gate before the announcement. The
        /// gate does not depend on an entry.
        @Test
        func theAnnouncementOpensTheGateThatWasTakenBefore() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log))
            let gate = announcer.gate(for: report.runID)
            #expect(!gate.isOpen)

            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)
            await announcer.stop()

            #expect(gate.isOpen)
        }

        /// A gate that is taken after the announcement is open.
        @Test
        func aGateTakenAfterTheAnnouncementIsOpen() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log))
            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)

            #expect(announcer.gate(for: report.runID).isOpen)
            await announcer.stop()
        }

        /// A blocked run leaves its gate closed.
        @Test
        func aBlockedRunLeavesItsGateClosed() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log, answer: { _ in .blocked }))
            let gate = announcer.gate(for: report.runID)

            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)
            await announcer.stop()

            #expect(!gate.isOpen)
        }


        /// A session that registers after the end of its run holds a closed gate. The announcer
        /// keeps no state for it.
        @Test
        func aGateTakenAfterTheEndOfTheRunIsClosedAndKeepsNoState() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            announcer.bind(Self.makeOutlet(log: log))
            let ended = SubagentAnnouncerTests.makeReport(state: SubagentAnnouncerTests.endedState)
            announcer.observe(ended, isFinal: true)
            _ = try await Self.wait(log, for: ended.runID)
            #expect(await Self.trackedRunCountAfterSettling(announcer) == 0)

            let gate = announcer.gate(for: ended.runID)

            #expect(!gate.isOpen)
            #expect(announcer.trackedRunCount == 0)
            await announcer.stop()
        }

        /// A session that is retired and registered again during the life of its run gets the same
        /// gate. The announcement opens it.
        @Test
        func aSessionRegisteredAgainGetsTheSameOpenGate() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let report = SubagentAnnouncerTests.makeReport()
            announcer.bind(Self.makeOutlet(log: log))
            let first = announcer.gate(for: report.runID)

            announcer.observe(report)
            _ = try await Self.wait(log, for: report.runID)
            let second = announcer.gate(for: report.runID)

            #expect(second === first)
            #expect(second.isOpen)
            await announcer.stop()
        }

        // MARK: Stop

        /// After the stop, a run waiting in the queue is not delivered. The first delivery holds
        /// until the stop cancels the task of the queue. The second run stays in the queue.
        @Test
        func aStoppedAnnouncerDeliversNoQueuedReport() async throws {
            let announcer = SubagentAnnouncer()
            let log = Log([])
            let first = SubagentAnnouncerTests.makeReport()
            let second = SubagentAnnouncerTests.makeReport()
            announcer.bind(
                Self.makeOutlet(log: log, answer: { _ in
                    // The gate that the test controls: the delivery ends only
                    // after the stop cancelled the task of the queue.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                    return .blocked
                }))
            announcer.observe(first)
            _ = try await Self.wait(log, for: first.runID)
            announcer.observe(second)

            await announcer.stop()

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
    }
}

// MARK: - The patch

extension SubagentAnnouncerTests {
    /// The patch of a snapshot against the snapshot that the client holds.
    @Suite struct Patch {
        /// A snapshot with a title and a state.
        private static let base = SubagentUpdate(
            sessionId: SessionId(rawValue: "child"), state: .value(.running(RunningStateUpdate())), title: .value("worker"))

        /// The client holds nothing: the patch is the whole snapshot.
        @Test
        func aSnapshotWithNoPreviousIsItsOwnPatch() {
            #expect(Self.base.patch(replacing: nil) == Self.base)
        }

        /// Equal snapshots give no patch.
        @Test
        func anEqualSnapshotGivesNoPatch() {
            #expect(Self.base.patch(replacing: Self.base) == nil)
        }

        /// One changed field gives a patch with only that field.
        @Test
        func oneChangedFieldGivesOnlyThatField() {
            var changed = Self.base
            changed.state = .value(SubagentAnnouncerTests.endedState)

            #expect(
                changed.patch(replacing: Self.base)
                    == SubagentUpdate(sessionId: Self.base.sessionId, state: .value(SubagentAnnouncerTests.endedState)))
        }

        /// A new `_meta` is a changed field.
        @Test
        func aNewMetaIsAChangedField() {
            var changed = Self.base
            changed.meta = .value(.object(["sah": .object([:])]))

            #expect(
                changed.patch(replacing: Self.base)
                    == SubagentUpdate(sessionId: Self.base.sessionId, meta: .value(.object(["sah": .object([:])]))))
        }
    }
}

// MARK: - The wait for a join entry

/// Waits until a caller waits in the table. A write after this point reaches
/// the caller, so no test depends on the order in which tasks start.
///
/// - Parameter joins: The table.
func waitForWaiter(in joins: RunCallJoinTable) async {
    while joins.waiterCount == 0 {
        await Task.yield()
    }
}

extension SubagentAnnouncerTests {
    /// The wait of the announcer for the entry that the join table writes. The entry is for the
    /// `agents` call that started a run.
    @Suite(.timeLimit(.minutes(1))) struct Join {
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
            await waitForWaiter(in: joins)

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
            await waitForWaiter(in: joins)

            joins.closeProjection()

            #expect(await waiting.value == ToolCallId(rawValue: Self.token))
        }

        /// A cancelled wait ends with no id. The token is not the wire id of a
        /// run that can still get an SDK id.
        @Test
        func aCancelledWaitGivesNoId() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            let waiting = Task { await joins.awaitToolCallId(for: Self.token) }
            await waitForWaiter(in: joins)

            waiting.cancel()

            #expect(await waiting.value == nil)
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

        /// A waiter is counted while it waits, and not after the entry came.
        @Test
        func theWaiterCountFollowsTheWaiters() async {
            let joins = RunCallJoinTable()
            joins.openProjection()
            let waiting = Task { await joins.awaitToolCallId(for: Self.token) }
            await waitForWaiter(in: joins)
            #expect(joins.waiterCount == 1)

            joins.record(toolCallID: Self.sdkCallId, for: Self.token)
            _ = await waiting.value

            #expect(joins.waiterCount == 0)
        }
    }
}
