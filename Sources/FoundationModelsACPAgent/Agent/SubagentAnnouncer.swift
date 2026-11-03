import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Synchronization

/// What the announcer knows of one agent run when it reports the run: the
/// fields that the `subagent_update` of the run is made from.
///
/// The report holds values only, so the observer of the run events can make it
/// at once and hand it to the queue of the announcer.
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

    /// The folder that holds the recording folder of the run, or `nil` for a
    /// run with no recording. The Router writes the record of the session of
    /// the run there, and the record names the tool call that started the run.
    let recordingRoot: URL?

    /// Makes a report from its parts.
    ///
    /// - Parameters:
    ///   - runID: The id of the run.
    ///   - caller: The session that started the run, or `nil`.
    ///   - title: The display title of the child.
    ///   - description: The description of the agent, or `nil`.
    ///   - state: The foreground state of the run.
    ///   - recordingRoot: The folder that holds the recording folder of the
    ///     run, or `nil`.
    init(
        runID: ULID, caller: ULID?, title: String, description: String?, state: StateUpdate,
        recordingRoot: URL? = nil
    ) {
        self.runID = runID
        self.caller = caller
        self.title = title
        self.description = description
        self.state = state
        self.recordingRoot = recordingRoot
    }

    /// Makes the report of a run, as the run is now.
    ///
    /// - Parameter run: The agent run.
    init(run: AgentRun) {
        self.init(
            runID: run.id, caller: run.caller, title: run.agent.id, description: run.agent.description,
            state: Self.state(of: run.state), recordingRoot: run.recordingDirectory?.deletingLastPathComponent())
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

/// What an outlet did with a report.
enum SubagentDelivery: Equatable, Sendable {
    /// The outlet sent an update. The value is the full snapshot of the child
    /// after the update, which the next delivery of the run replaces.
    case sent(SubagentUpdate)

    /// The report changes nothing that the client knows, so the outlet sent
    /// nothing.
    case unchanged

    /// The outlet could not send: the parent is closed, has no connection, or
    /// the client does not know it yet. The report is delivered again at the
    /// next observation of the run.
    case blocked
}

/// What the announcer needs from the agent: where the announcements go, and
/// how to reach the agent. The agent makes one outlet for the root session of
/// the surface (``RoutedACPAgent/makeSubagentOutlet(root:runner:)``).
struct SubagentOutlet: Sendable {
    /// The ACP id of the root session of the surface. A run with no caller
    /// belongs to it.
    let root: SessionId

    /// Sends the announcement of a report, as a patch of the snapshot that
    /// the earlier delivery of the run made.
    let deliver: @Sendable (_ report: SubagentReport, _ previous: SubagentUpdate?) async -> SubagentDelivery

    /// Tells the agent that the client knows a child now, so it opens the gate
    /// of the session of that child.
    let announced: @Sendable (_ child: SessionId) async -> Void

    /// The report of a run that is in operation or finished, or `nil` when the
    /// runner does not know the id.
    let parentReport: @Sendable (_ runID: ULID) async -> SubagentReport?
}

/// The ordered queue that announces each agent run to the client.
///
/// An agent run starts in the background, and the observer of its session
/// events (``AgentsComposition/makeRunEventObserver(runCallJoins:announcer:)``)
/// must not wait. The observer hands the run to ``observe(_:)``, which only
/// takes a lock and puts the report in a queue. One task reads the queue in
/// order and delivers each report through the outlet. So the announcement of
/// a child goes out first, and the gate of the session of the child opens
/// after it (``SubagentOutlet/announced``), in the same step of the queue. No
/// update of the child can leave before its announcement.
///
/// A report of a run that did not change is not queued again, thus a run
/// sends one full announcement and then only patches of changed fields. A
/// report whose parent run is not announced yet is delivered after the report
/// of the parent (a child of a child comes after the child).
///
/// The queue starts when the outlet is bound (``bind(_:)``). Reports that come
/// before the bind wait for it. ``stop()`` ends the queue: a report that is
/// still waiting is not delivered.
///
/// A class, because the surface and the agent share one queue. A `Mutex`
/// guards the state. The task of the queue holds the announcer until
/// ``stop()`` ends the stream, and the close of the session calls it.
final class SubagentAnnouncer: Sendable {
    /// The state that the lock guards.
    private struct State {
        /// The last report that went into the queue, for each run. An equal
        /// report is not queued again.
        var queued: [ULID: SubagentReport] = [:]

        /// The snapshot that the last sent update of each run made.
        var sent: [ULID: SubagentUpdate] = [:]

        /// The task that reads the queue, or `nil` before the bind.
        var consumer: Task<Void, Never>?

        /// Whether ``SubagentAnnouncer/stop()`` ran.
        var isStopped = false
    }

    /// The state of the queue and of the runs.
    private let state = Mutex(State())

    /// The reports, in the order that the observer gave them.
    private let reports: AsyncStream<SubagentReport>

    /// The end that puts a report in ``reports``.
    private let queue: AsyncStream<SubagentReport>.Continuation

    /// Makes an announcer with an empty queue and no outlet.
    init() {
        (reports, queue) = AsyncStream.makeStream(of: SubagentReport.self)
    }

    /// Whether ``stop()`` ran.
    var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    /// Whether the client knows the child of a run: the announcement of the
    /// run was sent.
    ///
    /// - Parameter runID: The id of the run.
    /// - Returns: `true` after the first sent announcement of the run.
    func hasAnnounced(_ runID: ULID) -> Bool {
        state.withLock { $0.sent[runID] != nil }
    }

    /// Queues the report of a run, as the run is now. It is the hook of the
    /// observer of the run events. It does not wait.
    ///
    /// - Parameter run: The run that gave an event.
    func observe(_ run: AgentRun) {
        observe(SubagentReport(run: run))
    }

    /// Queues a report, unless it equals the last report of its run, or the
    /// announcer stopped.
    ///
    /// - Parameter report: The report.
    func observe(_ report: SubagentReport) {
        state.withLock { state in
            guard !state.isStopped, state.queued[report.runID] != report else {
                return
            }
            state.queued[report.runID] = report
            queue.yield(report)
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
            state.consumer = Task { await self.deliverReports(through: outlet) }
        }
    }

    /// Ends the queue and waits for the report that is in delivery. A report
    /// that waits in the queue is not delivered, and a later report is not
    /// queued. A second call does nothing more.
    func stop() async {
        let consumer = state.withLock { state -> Task<Void, Never>? in
            state.isStopped = true
            return state.consumer
        }
        queue.finish()
        consumer?.cancel()
        await consumer?.value
    }

    /// Reads the queue until it ends or the task is cancelled.
    ///
    /// - Parameter outlet: Where the announcements go.
    private func deliverReports(through outlet: SubagentOutlet) async {
        for await report in reports {
            if Task.isCancelled {
                return
            }
            await deliver(report, through: outlet)
        }
    }

    /// Delivers a report after the report of its parent run, when the client
    /// does not know the parent yet, and records what the outlet did.
    ///
    /// - Parameters:
    ///   - report: The report.
    ///   - outlet: Where the announcements go.
    private func deliver(_ report: SubagentReport, through outlet: SubagentOutlet) async {
        await deliverParent(of: report, through: outlet)
        let previous = state.withLock { $0.sent[report.runID] }
        switch await outlet.deliver(report, previous) {
        case .sent(let snapshot):
            state.withLock { $0.sent[report.runID] = snapshot }
            await outlet.announced(SessionId(rawValue: report.runID.description))
        case .unchanged:
            break
        case .blocked:
            forgetQueued(report)
        }
    }

    /// Delivers the report of the parent run of `report`, when the caller is a
    /// run that the client does not know yet.
    ///
    /// - Parameters:
    ///   - report: The report of the child.
    ///   - outlet: Where the announcements go.
    private func deliverParent(of report: SubagentReport, through outlet: SubagentOutlet) async {
        guard let caller = report.caller, caller.description != outlet.root.rawValue, !hasAnnounced(caller),
            let parent = await outlet.parentReport(caller)
        else {
            return
        }
        state.withLock { $0.queued[parent.runID] = parent }
        await deliver(parent, through: outlet)
    }

    /// Makes the next observation of a run queue its report again: the
    /// outlet could not send it.
    ///
    /// - Parameter report: The report that the outlet could not send.
    private func forgetQueued(_ report: SubagentReport) {
        state.withLock { state in
            if state.queued[report.runID] == report {
                state.queued.removeValue(forKey: report.runID)
            }
        }
    }
}
