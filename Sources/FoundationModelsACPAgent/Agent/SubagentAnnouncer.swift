import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Synchronization

/// What the announcer knows of one agent run when it reports the run: the
/// fields that the `subagent_update` of the run is made from.
///
/// The report holds values only. So the observer of the run events can make it
/// at once, and hand it to the queue of the announcer.
struct SubagentReport: Equatable, Sendable {
    /// The id of the run. The session of a run has the id of the run, so this
    /// is the Router session id of the child.
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

    /// The completion token of the `agents` call that started the run, or
    /// `nil` for a run that no call started (a run of the host). The join
    /// table of the parent maps the token to the wire id of the call.
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

    /// The foreground state that a state of a run reports. A run in operation
    /// is `running`. A run that ended is `idle`, with the stop reason of the
    /// way it ended, the same mapping as for the end of a prompt.
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

    /// The wire id cannot be found now: the parent is not in the table, or
    /// the wait ended with no entry. The run is tried again at the next event
    /// that can change this (``SubagentAnnouncer/retryBlocked()``).
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

    /// The report of a run that is in operation or finished, or `nil` when the
    /// runner does not know the id.
    let parentReport: @Sendable (_ runID: ULID) async -> SubagentReport?
}

/// The queue that announces each agent run to the client.
///
/// An agent run starts in the background, and the observer of its session
/// events (``AgentsComposition/makeRunEventObserver(runCallJoins:announcer:)``)
/// must not wait. The observer hands the run to `observe`, which only takes a
/// lock. One task reads the ids of the runs that have news, in
/// order, and delivers the newest report of each run through the outlet. So
/// the announcement of a child goes out first. The gate of the session of the
/// child (``gate(for:)``) opens after it, in the same step. No update of the
/// child can leave before its announcement.
///
/// Each run has one small state. It holds the newest report, the report that
/// the outlet handled last, the snapshot, the link, and a flag for a blocked
/// delivery. A report that equals the handled one is not queued again. An
/// event that comes while a delivery is in flight is not lost. The consumer
/// reads the newest report when it takes the run.
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
/// A class, because the surface and the agent share one queue. A `Mutex`
/// guards the state. The task of the queue holds the announcer until
/// ``stop()`` ends the stream, and the close of the session calls it.
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
            return .deliver(report, sent, callId)
        }

        /// Whether the run has a report that the outlet did not handle, and
        /// nothing holds it back.
        var hasNews: Bool {
            !isBlocked && !isQueued && latest != nil && latest != handled
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

        /// Blocks a run after an attempt that could not go on. When a retry
        /// came during the attempt, the run is queued again instead, so no
        /// retry event is lost.
        mutating func blockOrRetry(_ runID: ULID, in queue: AsyncStream<ULID>.Continuation) {
            guard let run = runs[runID] else {
                return
            }
            runs[runID]?.handled = nil
            if run.attemptEpoch == retryEpoch {
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

    /// Whether the client knows the child of a run: the announcement of the
    /// run was sent, and the run is still live.
    ///
    /// - Parameter runID: The id of the run.
    /// - Returns: `true` after the first sent announcement of the run.
    func hasAnnounced(_ runID: ULID) -> Bool {
        state.withLock { $0.runs[runID]?.sent != nil }
    }

    /// The gate of the session of a run. The session takes it when the agent
    /// makes its entry, and the announcer opens it after it sent the
    /// announcement. The gate does not depend on the entry. So an announcement
    /// that goes out before, during or after the registration of the session
    /// opens the one gate that the session holds.
    ///
    /// - Parameter runID: The id of the run, which is the session id.
    /// - Returns: The gate. After the stop, or after the final announcement
    ///   of a run, it is a new closed gate: no announcement can come.
    func gate(for runID: ULID) -> SessionAnnouncementGate {
        state.withLock { state in
            guard !state.isStopped else {
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
        let watch = state.withLock { state -> Bool? in
            guard !state.isStopped else {
                return nil
            }
            let known = state.runs[run.id]
            if known?.isBlocked == true, known?.isWatched == true {
                return nil
            }
            state.runs[run.id, default: RunState()].isWatched = true
            return known?.isWatched != true
        }
        guard let watch else {
            return
        }
        if watch {
            watchEnd(of: run)
        }
        observe(SubagentReport(run: run))
    }

    /// Queues a report, unless the announcer stopped, the run waits for a
    /// retry, or the outlet handled this report already.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - isFinal: Whether the run ended and this is its last report.
    func observe(_ report: SubagentReport, isFinal: Bool = false) {
        state.withLock { state in
            guard !state.isStopped else {
                return
            }
            state.runs[report.runID, default: RunState()].latest = report
            if isFinal {
                // The end of a run is an event that retries a blocked run.
                state.runs[report.runID]?.isFinal = true
                state.runs[report.runID]?.isBlocked = false
            }
            state.queueIfNew(report.runID, in: queue)
        }
    }

    /// Makes each blocked run ready for a new try. Call it when something
    /// that could unblock a run happened: an announcement was sent, or a
    /// session was made in the table.
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
    /// cannot be found now blocks the run.
    ///
    /// - Parameters:
    ///   - link: What the outlet found.
    ///   - runID: The id of the run.
    private func finishLink(_ link: SubagentLink, of runID: ULID) {
        state.withLock { state in
            guard !state.isStopped, state.runs[runID]?.link == .resolving else {
                return
            }
            state.runs[runID]?.linkTask = nil
            if link == .unavailable {
                state.runs[runID]?.link = .unresolved
                state.blockOrRetry(runID, in: queue)
            } else {
                state.runs[runID]?.link = .resolved(link)
                state.queueIfNew(runID, in: queue)
            }
        }
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

    /// Makes a run wait for its parent run, when the caller is a run that the
    /// client does not know yet. The parent goes into the queue, and its
    /// announcement retries the child.
    ///
    /// - Parameters:
    ///   - report: The report of the child.
    ///   - outlet: Where the announcements go.
    /// - Returns: `true` when the run waits for its parent.
    private func waitsForParent(of report: SubagentReport, through outlet: SubagentOutlet) async -> Bool {
        guard let caller = report.caller, caller.description != outlet.root.rawValue, !hasAnnounced(caller),
            let parent = await outlet.parentReport(caller)
        else {
            return false
        }
        observe(parent)
        state.withLock { $0.blockOrRetry(report.runID, in: queue) }
        return true
    }

    /// Records what the outlet did with a report. A sent announcement opens
    /// the gate and retries the blocked runs. The final report, once handled,
    /// ends the state of its run.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - delivery: What the outlet did.
    private func complete(_ report: SubagentReport, with delivery: SubagentDelivery) {
        var wasSent = false
        state.withLock { state in
            guard state.runs[report.runID] != nil else {
                return
            }
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
            if let run = state.runs[report.runID], run.isFinal, !run.isBlocked, run.latest == run.handled {
                state.runs.removeValue(forKey: report.runID)
            }
        }
        if wasSent {
            retryBlocked()
        }
    }
}
