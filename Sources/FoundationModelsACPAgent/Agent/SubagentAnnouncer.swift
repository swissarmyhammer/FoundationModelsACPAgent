import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Synchronization

/// What the announcer knows of one agent run when it reports the run. These are the fields that
/// make the `subagent_update` of the run.
///
/// The report holds values only. So the observer of the run events can make it at once. It then
/// hands the report to the queue of the announcer.
struct SubagentReport: Equatable, Sendable {
    /// The id of the run. The session of a run has the id of the run. So this is the Router session
    /// id of the child.
    let runID: ULID

    /// The session that started the run: the root session or the parent run.
    /// `nil` for a run that the host started, which belongs to the root
    /// session of the surface.
    let caller: ULID?

    /// The display title of the child: the id of its agent.
    let title: String

    /// The description of the agent, or `nil` when the agent has none.
    let description: String?

    /// The foreground state of the run.
    let state: StateUpdate

    /// The completion token of the `agents` call that started the run. It is `nil` for a run that
    /// no call started (a run of the host). The join table of the parent maps the token to the wire
    /// id of the call.
    let completionToken: String?

    /// Makes a report from its parts.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - caller: The session that started the run, or `nil`.
    ///   - title: The display title of the child.
    ///   - description: The description of the agent, or `nil`.
    ///   - state: The foreground state of the run.
    ///   - completionToken: The completion token of the `agents` call that
    ///     started the run, or `nil`.
    init(
        runID: ULID, caller: ULID?, title: String, description: String?, state: StateUpdate,
        completionToken: String? = nil
    ) {
        self.runID = runID
        self.caller = caller
        self.title = title
        self.description = description
        self.state = state
        self.completionToken = completionToken
    }

    /// Makes the report of a run, as the run is now.
    ///
    /// - Parameter run: The agent run.
    init(run: AgentRun) {
        self.init(
            runID: run.id, caller: run.caller, title: run.agent.id, description: run.agent.description,
            state: Self.state(of: run.state), completionToken: run.completionToken)
    }

    /// The foreground state that a state of a run reports. A run in operation is `running`. A run
    /// that ended is `idle`. Its stop reason is the way it ended, the same mapping as for the end
    /// of a prompt.
    ///
    /// - Parameter runState: The state of the run.
    /// - Returns: The state update.
    private static func state(of runState: AgentRunState) -> StateUpdate {
        switch runState {
        case .running:
            .running(RunningStateUpdate())
        case .finished:
            .idle(PromptExecution.idleState(for: .completed))
        case .failed(let failure):
            .idle(PromptExecution.idleState(for: .failed(message: "\(failure)")))
        case .cancelled:
            .idle(PromptExecution.idleState(for: .cancelled))
        }
    }
}

/// What the link of a run to its `agents` call is, at this time.
enum SubagentLink: Equatable, Sendable {
    /// No call started the run, so no link can exist. The run is announced
    /// at once, with no link.
    case none

    /// The wire id of the `agents` call that started the run.
    case callId(ToolCallId)

    /// The wire id cannot be found now. The parent is not in the table, or the wait ended with no
    /// entry. The next event that can change this tries the run again
    /// (``SubagentAnnouncer/retryBlocked()``).
    case unavailable

    /// The wire id, or `nil` for any other link.
    var toolCallId: ToolCallId? {
        if case .callId(let id) = self {
            return id
        }
        return nil
    }
}

/// What an outlet did with a report.
enum SubagentDelivery: Equatable, Sendable {
    /// The outlet sent an update. The value is the full snapshot of the child
    /// after the update, which the next delivery of the run replaces.
    case sent(SubagentUpdate)

    /// The report changes nothing that the client knows, so the outlet sent
    /// nothing.
    case unchanged

    /// The outlet could not send: the parent is closed, has no connection, or
    /// the client does not know it yet. The run waits for the next event that
    /// can change this (``SubagentAnnouncer/retryBlocked()``).
    case blocked
}

/// What the announcer needs from the agent: where the announcements go, and
/// how to reach the agent. The agent makes one outlet for the root session of
/// the surface (``RoutedACPAgent/makeSubagentOutlet(root:runner:)``).
struct SubagentOutlet: Sendable {
    /// The ACP id of the root session of the surface. A run with no caller
    /// belongs to it.
    let root: SessionId

    /// Finds the link of a run that an `agents` call started. It waits for the
    /// join entry of the call. Each run waits in its own task, so a wait that
    /// does not end holds no other run.
    let link: @Sendable (_ report: SubagentReport) async -> SubagentLink

    /// Sends the announcement of a report, as a patch of the snapshot that
    /// the earlier delivery of the run made. The link is the wire id of the
    /// `agents` call, or `nil` when the run has none.
    let deliver:
        @Sendable (_ report: SubagentReport, _ previous: SubagentUpdate?, _ link: ToolCallId?) async -> SubagentDelivery

    /// The report of a run that is in operation or finished. It is `nil` when the runner does not
    /// know the id.
    let parentReport: @Sendable (_ runID: ULID) async -> SubagentReport?
}

/// The queue that announces each agent run to the client.
///
/// An agent run starts in the background. The observer of its session events
/// (``AgentsComposition/makeRunEventObserver(runCallJoins:announcer:)``) must not wait. The
/// observer hands the run to `observe`, which only takes a lock. One task reads the ids of the runs
/// that have news, in order. It delivers the newest report of each run through the outlet. So the
/// announcement of a child goes out first. The gate of the session of the child (``gate(for:)``)
/// opens after it, in the same step. No update of the child can leave before its announcement.
///
/// Each run has one small state. The state holds the newest report and the report that the outlet
/// handled last. It also holds the snapshot, the link, and a flag for a blocked delivery. A report
/// that equals the handled one is not queued again. An event that comes while a delivery is in
/// flight is not lost. The consumer reads the newest report when it takes the run.
///
/// A run that an `agents` call started waits for the wire id of the call. The
/// wait runs in a task of the run, never in the task of the queue. So a run
/// whose entry does not come holds no other run. A run that no call started
/// (a run of the host) has no link and is announced at once. The wait uses no
/// timer. It ends when the entry is written, when the projection stops, or
/// when the announcer stops.
///
/// A parent run is announced before its child. A child whose parent is not
/// announced waits, and the parent is queued. A delivery that the outlet
/// cannot make blocks its run. A blocked run costs no work for a later event.
/// The next event that can change the answer (an announcement, or a new
/// session in the table) calls ``retryBlocked()``.
///
/// The end of a run is an event. The announcer watches each run that it
/// sees, and at the end of the run it queues the final report. After the
/// final report was handled, the announcer drops the state of the run.
///
/// The queue starts when the outlet is bound (``bind(_:)``). Events that come
/// before the bind wait for it. ``stop()`` ends the queue.
///
/// A class, because the surface and the agent share one queue. A `Mutex` guards the state. The task
/// of the queue holds the announcer until ``stop()`` ends the stream. The close of the session
/// calls it.
final class SubagentAnnouncer: Sendable {
    /// How far the link of a run is.
    private enum LinkProgress: Equatable, Sendable {
        /// Nobody asked yet, or the last ask found nothing now.
        case unresolved

        /// A task of the run waits for the wire id.
        case resolving

        /// The link is known.
        case resolved(SubagentLink)
    }

    /// What the queue does with a run that has news.
    private enum Step {
        /// There is nothing to do.
        case skip

        /// Start the wait for the link of the run.
        case resolve(SubagentReport)

        /// Deliver the report, with the snapshot that the client holds and
        /// the link.
        case deliver(SubagentReport, SubagentUpdate?, ToolCallId?)
    }

    /// The state of one run.
    private struct RunState {
        /// The gate of the session of the run. It opens after the first sent
        /// announcement.
        let gate = SessionAnnouncementGate(isOpen: false)

        /// The newest report that the observer gave.
        var latest: SubagentReport?

        /// The report that the outlet handled last. `nil` after a blocked
        /// delivery, so that the next try delivers the newest report.
        var handled: SubagentReport?

        /// The snapshot that the last sent update made.
        var sent: SubagentUpdate?

        /// How far the link is.
        var link = LinkProgress.unresolved

        /// The task that waits for the wire id, while it waits.
        var linkTask: Task<Void, Never>?

        /// The retry count (``State/retryEpoch``) when the last attempt began.
        /// An attempt that ends blocked, after a retry came meanwhile, does
        /// not wait: the retry event is not lost.
        var attemptEpoch = 0

        /// Whether the id of the run is in the queue.
        var isQueued = false

        /// Whether the outlet could not deliver, and the run waits for
        /// ``SubagentAnnouncer/retryBlocked()``.
        var isBlocked = false

        /// Whether the end of the run is watched.
        var isWatched = false

        /// Whether the newest report is the final report of the run.
        var isFinal = false

        /// Whether the consumer delivers the handled report now.
        var isDelivering = false

        /// Takes the run out of the queue and tells what to do with it.
        mutating func takeStep(epoch: Int) -> Step {
            isQueued = false
            guard let report = latest, !isBlocked, report != handled else {
                return .skip
            }
            var callId: ToolCallId?
            if report.completionToken != nil {
                switch link {
                case .resolving:
                    return .skip
                case .unresolved:
                    link = .resolving
                    attemptEpoch = epoch
                    return .resolve(report)
                case .resolved(let resolved):
                    callId = resolved.toolCallId
                }
            }
            attemptEpoch = epoch
            handled = report
            isDelivering = true
            return .deliver(report, sent, callId)
        }

        /// Whether the run has a report that the outlet did not handle, and
        /// nothing holds it back.
        var hasNews: Bool {
            !isBlocked && !isQueued && latest != nil && latest != handled
        }

        /// Whether the run ended and the outlet handled its final report. No
        /// delivery is in flight and no report waits in the queue.
        var isSettled: Bool {
            isFinal && !isDelivering && !isQueued && latest == handled
        }
    }

    /// The ids of the runs whose state was dropped, oldest first. The list has
    /// a limit, so a long session holds a bounded number of ids.
    private struct FinishedRuns {
        /// The most ids that the list keeps. A run that is older than this many
        /// later runs is forgotten.
        static let limit = 4096

        /// The ids, for the lookup.
        private var ids: Set<ULID> = []

        /// The ids in the order that they came, for the removal of the oldest.
        private var order: [ULID] = []

        /// Whether the id is in the list.
        func contains(_ runID: ULID) -> Bool {
            ids.contains(runID)
        }

        /// Adds an id. At the limit, the oldest id leaves the list.
        mutating func insert(_ runID: ULID) {
            guard ids.insert(runID).inserted else {
                return
            }
            order.append(runID)
            if order.count > Self.limit {
                ids.remove(order.removeFirst())
            }
        }
    }

    /// The state that the lock guards.
    private struct State {
        /// The state of each live run.
        var runs: [ULID: RunState] = [:]

        /// The task that reads the queue, or `nil` before the bind.
        var consumer: Task<Void, Never>?

        /// Whether ``SubagentAnnouncer/stop()`` ran.
        var isStopped = false

        /// How many times ``SubagentAnnouncer/retryBlocked()`` ran.
        var retryEpoch = 0

        /// The ids of the runs whose state was dropped. A late event of such a
        /// run does nothing.
        var finished = FinishedRuns()

        /// Drops the state of a run that ended, and remembers its id.
        ///
        /// - Parameter runID: The id of the run.
        /// - Returns: Whether the client knew the run: the announcement was
        ///   sent.
        mutating func prune(_ runID: ULID) -> Bool {
            let wasAnnounced = runs.removeValue(forKey: runID)?.sent != nil
            finished.insert(runID)
            return wasAnnounced
        }

        /// Blocks a run after an attempt that could not go on. When a retry
        /// came during the attempt, the run is queued again instead, so no
        /// retry event is lost. The same holds for a final report that came
        /// during the attempt: nothing else would try it.
        mutating func blockOrRetry(_ runID: ULID, in queue: AsyncStream<ULID>.Continuation) {
            guard let run = runs[runID] else {
                return
            }
            let hasNewFinalReport = run.isFinal && run.latest != run.handled
            runs[runID]?.handled = nil
            runs[runID]?.isDelivering = false
            if run.attemptEpoch == retryEpoch, !hasNewFinalReport {
                runs[runID]?.isBlocked = true
            } else {
                queueIfNew(runID, in: queue)
            }
        }

        /// Puts the id of a run in the queue, when it has news.
        mutating func queueIfNew(_ runID: ULID, in queue: AsyncStream<ULID>.Continuation) {
            guard runs[runID]?.hasNews == true else {
                return
            }
            runs[runID]?.isQueued = true
            queue.yield(runID)
        }
    }

    /// The state of the queue and of the runs.
    private let state = Mutex(State())

    /// The ids of the runs that have news, in the order that the news came.
    private let runs: AsyncStream<ULID>

    /// The end that puts an id in ``runs``.
    private let queue: AsyncStream<ULID>.Continuation

    /// Makes an announcer with an empty queue and no outlet.
    init() {
        (runs, queue) = AsyncStream.makeStream(of: ULID.self)
    }

    /// Whether ``stop()`` ran.
    var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    /// How many runs have a state now. A run that ended and was handled has
    /// none. A test reads it to see that the announcer holds nothing.
    var trackedRunCount: Int {
        state.withLock { $0.runs.count }
    }

    /// Whether the client knows the child of a run. The announcement of the run was sent, and the
    /// run is still live.
    ///
    /// - Parameter runID: The id of the run.
    /// - Returns: `true` after the first sent announcement of the run.
    func hasAnnounced(_ runID: ULID) -> Bool {
        state.withLock { $0.runs[runID]?.sent != nil }
    }

    /// The gate of the session of a run. The session takes it when the agent makes its entry. The
    /// announcer opens it after it sent the announcement. The gate does not depend on the entry. So
    /// the timing of the announcement does not matter. It can go out before, during or after the
    /// registration of the session. It always opens the one gate that the session holds.
    ///
    /// - Parameter runID: The id of the run, which is the session id.
    /// - Returns: The gate. After the stop, or after the end of the run, it is a new closed gate.
    ///   The announcer does not keep that gate, because no announcement can come. Else the session
    ///   gets the one gate of the run, also when it asks again.
    func gate(for runID: ULID) -> SessionAnnouncementGate {
        state.withLock { state in
            guard !state.isStopped, !state.finished.contains(runID) else {
                return SessionAnnouncementGate(isOpen: false)
            }
            if state.runs[runID] == nil {
                state.runs[runID] = RunState()
            }
            return state.runs[runID]?.gate ?? SessionAnnouncementGate(isOpen: false)
        }
    }

    /// Queues the report of a run, as the run is now. It is the hook of the
    /// observer of the run events. It does not wait.
    ///
    /// The first call for a run also starts to watch the end of the run. A
    /// run that waits for a retry costs only a lock: the call builds no
    /// report.
    ///
    /// - Parameter run: The run that gave an event.
    func observe(_ run: AgentRun) {
        observe(runID: run.id, watchEnd: { watchEnd(of: run) }, makeReport: { SubagentReport(run: run) })
    }

    /// Queues the report of a run. The run is a pair of closures, so a test can
    /// count the calls.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - watchEnd: Starts to watch the end of the run. It runs once for a
    ///     run.
    ///   - makeReport: Makes the report of the run, as it is now. It does not
    ///     run for a run that waits for a retry, or for a run that ended.
    func observe(runID: ULID, watchEnd: () -> Void, makeReport: () -> SubagentReport) {
        let watch = state.withLock { state -> Bool? in
            guard !state.isStopped, !state.finished.contains(runID) else {
                return nil
            }
            let known = state.runs[runID]
            if known?.isBlocked == true, known?.isWatched == true {
                return nil
            }
            state.runs[runID, default: RunState()].isWatched = true
            return known?.isWatched != true
        }
        guard let watch else {
            return
        }
        if watch {
            watchEnd()
        }
        observe(makeReport())
    }

    /// Queues a report. It does nothing in four cases. The announcer stopped, or the run ended and
    /// was dropped. The run waits for a retry, or the outlet handled this report already. A final
    /// report that the outlet handled already ends the state of the run.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - isFinal: Whether the run ended and this is its last report.
    func observe(_ report: SubagentReport, isFinal: Bool = false) {
        let runID = report.runID
        let pruned = state.withLock { state -> Bool? in
            guard !state.isStopped, !state.finished.contains(runID) else {
                return nil
            }
            state.runs[runID, default: RunState()].latest = report
            if isFinal {
                // The end of a run is an event that retries a blocked run.
                state.runs[runID]?.isFinal = true
                state.runs[runID]?.isBlocked = false
            }
            state.queueIfNew(runID, in: queue)
            guard state.runs[runID]?.isSettled == true else {
                return nil
            }
            return state.prune(runID)
        }
        if let pruned {
            didPrune(runID, wasAnnounced: pruned)
        }
    }

    /// Does what follows the drop of the state of a run. The run is out of the
    /// way of the runs that wait for it, so they get a new try.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - wasAnnounced: Whether the client knew the run.
    private func didPrune(_ runID: ULID, wasAnnounced: Bool) {
        if !wasAnnounced {
            ACPAgentTelemetry.logger(.subagentAnnouncement).notice(
                "An agent run ended and the client never learned of it. The announcer drops its state.",
                metadata: ["run_id": "\(runID)"])
        }
        retryBlocked()
    }

    /// Makes each blocked run ready for a new try. Call it when something that could unblock a run
    /// happened. This is an announcement that was sent, or a session that was made in the table.
    func retryBlocked() {
        state.withLock { state in
            guard !state.isStopped else {
                return
            }
            state.retryEpoch += 1
            for runID in state.runs.keys where state.runs[runID]?.isBlocked == true {
                state.runs[runID]?.isBlocked = false
                state.queueIfNew(runID, in: queue)
            }
        }
    }

    /// Binds the outlet and starts to deliver. A second bind, or a bind after
    /// the stop, does nothing.
    ///
    /// - Parameter outlet: Where the announcements go.
    func bind(_ outlet: SubagentOutlet) {
        state.withLock { state in
            guard state.consumer == nil, !state.isStopped else {
                return
            }
            state.consumer = Task { await self.deliverRuns(through: outlet) }
        }
    }

    /// Ends the queue, ends each wait for a link, and waits for the delivery
    /// that is running. A run that waits in the queue is not delivered, and
    /// a later report is not queued. A second call does nothing more.
    func stop() async {
        let (consumer, linkTasks) = state.withLock { state -> (Task<Void, Never>?, [Task<Void, Never>]) in
            state.isStopped = true
            return (state.consumer, state.runs.values.compactMap(\.linkTask))
        }
        queue.finish()
        consumer?.cancel()
        for task in linkTasks {
            task.cancel()
        }
        await consumer?.value
        for task in linkTasks {
            await task.value
        }
    }

    /// Watches the end of a run. At the end, the final report of the run
    /// goes into the queue. The task is never cancelled, because a cancel
    /// of the task that waits for a result cancels the run.
    ///
    /// - Parameter run: The run.
    private func watchEnd(of run: AgentRun) {
        Task {
            _ = try? await run.result()
            observe(SubagentReport(run: run), isFinal: true)
        }
    }

    /// Reads the queue until it ends or the task is cancelled.
    ///
    /// - Parameter outlet: Where the announcements go.
    private func deliverRuns(through outlet: SubagentOutlet) async {
        for await runID in runs {
            if Task.isCancelled {
                return
            }
            let step = state.withLock { state in
                state.runs[runID]?.takeStep(epoch: state.retryEpoch) ?? .skip
            }
            switch step {
            case .skip:
                break
            case .resolve(let report):
                resolveLink(of: report, through: outlet)
            case .deliver(let report, let previous, let callId):
                await deliver(report, replacing: previous, link: callId, through: outlet)
            }
        }
    }

    /// Starts the task that waits for the link of a run. The queue goes on.
    ///
    /// - Parameters:
    ///   - report: The report of the run.
    ///   - outlet: Where the link comes from.
    private func resolveLink(of report: SubagentReport, through outlet: SubagentOutlet) {
        let task = Task {
            let link = await outlet.link(report)
            finishLink(link, of: report.runID)
        }
        state.withLock { state in
            if state.isStopped {
                task.cancel()
            } else if state.runs[report.runID]?.link == .resolving {
                state.runs[report.runID]?.linkTask = task
            }
        }
    }

    /// Records the link of a run. A known link queues the run. A link that
    /// cannot be found now blocks the run, or ends it when the run ended.
    ///
    /// - Parameters:
    ///   - link: What the outlet found.
    ///   - runID: The id of the run.
    private func finishLink(_ link: SubagentLink, of runID: ULID) {
        let pruned = state.withLock { state -> Bool? in
            guard !state.isStopped, state.runs[runID]?.link == .resolving else {
                return nil
            }
            state.runs[runID]?.linkTask = nil
            if link == .unavailable {
                state.runs[runID]?.link = .unresolved
                if state.runs[runID]?.isFinal == true {
                    // No later event can change the answer for a run that ended.
                    return state.prune(runID)
                }
                state.blockOrRetry(runID, in: queue)
            } else {
                state.runs[runID]?.link = .resolved(link)
                state.queueIfNew(runID, in: queue)
            }
            return nil
        }
        if let pruned {
            didPrune(runID, wasAnnounced: pruned)
        }
    }

    /// Whether the client has no more to learn of a run. Either the announcement of the run was
    /// sent, or the run ended and its state was dropped.
    ///
    /// - Parameter runID: The id of the run.
    /// - Returns: `true` when the run needs no announcement.
    private func isSettled(_ runID: ULID) -> Bool {
        state.withLock { $0.finished.contains(runID) || $0.runs[runID]?.sent != nil }
    }

    /// Delivers a report, unless its parent run is not announced yet, and
    /// records what the outlet did.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - previous: The snapshot that the client holds, or `nil`.
    ///   - callId: The wire id of the `agents` call, or `nil`.
    ///   - outlet: Where the announcements go.
    private func deliver(
        _ report: SubagentReport, replacing previous: SubagentUpdate?, link callId: ToolCallId?,
        through outlet: SubagentOutlet
    ) async {
        guard await !waitsForParent(of: report, through: outlet) else {
            return
        }
        complete(report, with: await outlet.deliver(report, previous, callId))
    }

    /// Makes a run wait for its parent run. This holds when the caller is a run that the client
    /// does not know yet. A parent that ended counts as known. The parent goes into the queue, and
    /// its announcement retries the child.
    ///
    /// - Parameters:
    ///   - report: The report of the child.
    ///   - outlet: Where the announcements go.
    /// - Returns: `true` when the run waits for its parent.
    private func waitsForParent(of report: SubagentReport, through outlet: SubagentOutlet) async -> Bool {
        guard let caller = report.caller, caller.description != outlet.root.rawValue, !isSettled(caller),
            let parent = await outlet.parentReport(caller)
        else {
            return false
        }
        observe(parent)
        state.withLock { $0.blockOrRetry(report.runID, in: queue) }
        return true
    }

    /// Records what the outlet did with a report. A sent announcement opens
    /// the gate and retries the blocked runs. The final report, once tried,
    /// ends the state of its run. It ends it also after a blocked try.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - delivery: What the outlet did.
    private func complete(_ report: SubagentReport, with delivery: SubagentDelivery) {
        let outcome = state.withLock { state -> (wasSent: Bool, pruned: Bool?) in
            guard state.runs[report.runID] != nil else {
                return (false, nil)
            }
            state.runs[report.runID]?.isDelivering = false
            var wasSent = false
            switch delivery {
            case .sent(let snapshot):
                state.runs[report.runID]?.sent = snapshot
                state.runs[report.runID]?.gate.open()
                wasSent = true
            case .unchanged:
                break
            case .blocked:
                state.blockOrRetry(report.runID, in: queue)
            }
            // The last try for the final report ends the run, whatever the outlet said. No later
            // event can change the answer.
            if let run = state.runs[report.runID], run.isFinal, run.latest == report {
                return (wasSent, state.prune(report.runID))
            }
            return (wasSent, nil)
        }
        if let pruned = outcome.pruned {
            didPrune(report.runID, wasAnnounced: pruned)
        } else if outcome.wasSent {
            retryBlocked()
        }
    }
}
