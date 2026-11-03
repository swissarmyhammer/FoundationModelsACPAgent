import FoundationModelsACP
import FoundationModelsRouter
import Synchronization

/// The join of each tool run of one session to the SDK tool call that started
/// it, keyed by the completion token of the run (task ^9xk3xf4).
///
/// One tool run has two ids. Router joins them on the
/// `toolInvocation(record, toolCallID:)` event of the open record. Two
/// consumers send updates of one run, and both must use one wire id:
///
/// - ``ACPEventTranslator`` reads the `SessionEvent` stream of the session. It
///   writes the join when it handles the open record, and it sends each run
///   update on the id that this table gives (``toolCallId(for:)``).
/// - ``TerminalStream`` reads the host-owned shell output stream. It does not
///   see the open record. It reads the id of its `Terminal` announce from this
///   table (``announceToolCallId(for:)``).
///
/// The two streams have no common order: a shell chunk can come before the
/// projection handled the open record. Then the run waits for its entry: the
/// terminal stream keeps only the fact that the run has output, and the table
/// tells it when the entry is written (``observeJoins(_:)``). The terminal
/// stream sends one announce only after that. It never sends on the
/// completion token and later on the SDK id.
///
/// The first write for a run is final. A later write for the same run changes
/// nothing. Thus each consumer reads the same entry, and each run has one wire
/// id. No time decides an entry. Each entry comes from an event of the run
/// itself, or from the stop of the projection:
///
/// - the open record of a root run (``record(toolCallID:for:)``),
/// - the settlement of a root run (``seal(_:)``),
/// - the open record of a run of an agent run (``recordAgentRunEvent(_:)``,
///   task ^zbcrex8). An agent run (the `agents` tool) uses the shell
///   capability of the root session, but its tool records go to the event
///   stream of the agent run, not to the root prompt. The run event observer
///   of the agent environment gives each of those events to this table. The
///   agent run sends no wire update of its tool runs, so "no join" is the
///   correct entry for them.
/// - the stop of the projection (``closeProjection()``): each waiting run
///   gets "no join". A run whose first event comes while no projection is
///   open gets "no join" at once. This rule stays: no translator writes an
///   entry for a root run after the ``SessionProjector`` of the session
///   stopped. Without the rule, such a run would wait until the shell output
///   stream ends.
///
/// The end of an agent run writes no entry. Thus a root run that starts just
/// after an agent run ended keeps the SDK id of its own open record, also
/// when its first chunk comes before the projection handled the end of the
/// agent run.
///
/// The session surface owns one table (``SessionSurface/runCallJoins``),
/// because the terminal stream and the agent environment live for the whole
/// session, as the projector does. An entry stays for the life of the
/// session: a background run can settle in a later prompt, or with no prompt
/// open. An entry is
/// one short string for each run.
///
/// `ACPEventTranslator` reads the table from synchronous code, thus a `Mutex`
/// keeps the state, as ``RetainedHistory`` does.
final class RunCallJoinTable: Sendable {
    /// Receives the completion token of each waiting run whose entry was
    /// written.
    typealias JoinObserver = @Sendable (String) -> Void

    /// The join of one run.
    private enum Join: Equatable, Sendable {
        /// Router joined the run to the SDK tool call with this id.
        case joined(toolCallID: String)

        /// No SDK tool call joined the run. The run keeps its completion token.
        case unjoined
    }

    /// One caller that waits for the entry of a run
    /// (``RunCallJoinTable/awaitToolCallId(for:)``).
    private struct EntryWaiter {
        /// The completion token of the run.
        let token: String

        /// Resumes the caller when the entry is written, when the projection
        /// stops, or when the caller is cancelled.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The entries and the waiting runs, under one lock.
    private struct State {
        /// The join of each run that has an entry, keyed by the completion
        /// token of the run.
        var joins: [String: Join] = [:]

        /// The completion tokens of the runs whose events wait for an entry.
        var waitingRuns: Set<String> = []

        /// The receiver of the tokens of the waiting runs whose entry was
        /// written, or `nil` when no terminal stream reads the table.
        var joinObserver: JoinObserver?

        /// Whether the projector of the session reads its events, so that
        /// its translator can write an entry.
        var isProjectionOpen = false

        /// The callers that wait for the entry of a run, by their ticket.
        var entryWaiters: [Int: EntryWaiter] = [:]

        /// The ticket of the next caller that waits for an entry.
        var nextTicket = 0
    }

    /// The state of the table.
    private let state = Mutex(State())

    /// Writes the join of the open record of a run, when the run has no entry
    /// yet.
    ///
    /// - Parameters:
    ///   - toolCallID: The SDK tool-call id that Router joined to the run, or
    ///     `nil` when no SDK call joined the run.
    ///   - token: The completion token of the run.
    func record(toolCallID: String?, for token: String) {
        store(toolCallID.map { Join.joined(toolCallID: $0) } ?? .unjoined, for: token)
    }

    /// Writes "no join" for a run that has no entry yet. A run that has an
    /// entry keeps it.
    ///
    /// - Parameter token: The completion token of the run.
    func seal(_ token: String) {
        store(.unjoined, for: token)
    }

    /// Records that the projector of the session reads its events. Call it
    /// before the projector takes its first Router subscription, so that a
    /// run waits for the entry that the translator writes.
    func openProjection() {
        state.withLock { $0.isProjectionOpen = true }
    }

    /// Records that the projector of the session stopped, and writes
    /// "no join" for each
    /// waiting run: no projection writes an entry after this point.
    func closeProjection() {
        state.withLock { $0.isProjectionOpen = false }
        sealWaitingRuns()
    }

    /// Writes "no join" for the run of an open record in the event stream of
    /// an agent run. Each other event writes nothing.
    ///
    /// The run event observer of the agent environment calls this
    /// synchronously in the follow loop of each agent run
    /// (``AgentsComposition/makeRunEventObserver(runCallJoins:)``). Thus it
    /// only takes the lock, and it does not wait.
    ///
    /// An agent run sends no wire update of its tool runs, so a tool run of an
    /// agent run keeps its completion token, also when Router of the agent run
    /// joined the record to an SDK call of the agent run.
    ///
    /// - Parameter output: One session output of an agent run.
    func recordAgentRunEvent(_ output: SessionOutput) {
        guard case .toolInvocation(let record, _) = output.event, record.closedAt == nil else {
            return
        }
        seal(record.correlationID)
    }

    /// Sets the receiver of the tokens of the waiting runs whose entry was
    /// written. The terminal stream of the session is the one receiver.
    ///
    /// - Parameter observer: The receiver, or `nil` to remove it.
    func observeJoins(_ observer: JoinObserver?) {
        state.withLock { $0.joinObserver = observer }
    }

    /// The wire id of a run, as the entry gives it now: the joined SDK id, or
    /// the completion token when the run has no join.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The tool call id.
    func toolCallId(for token: String) -> ToolCallId {
        Self.toolCallId(of: state.withLock { $0.joins[token] }, token: token)
    }

    /// The wire id of a run, after the entry of the run was written.
    ///
    /// A caller that must name the wire id of a tool call that the projection
    /// sends reads it here: the observer of an agent run can see the first
    /// event of a run before the projection handled the open record of the
    /// `agents` call that started it. A run with an entry gives it at once.
    /// While no projection is open, no entry can come, so the run gets
    /// "no join" at once, the same rule as ``announceToolCallId(for:)``. Else
    /// the call waits until the entry is written. The stop of the projection
    /// (``closeProjection()``) and the cancel of the calling task end the wait,
    /// so the wait never outlives the session. No time decides the entry.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The tool call id, as ``toolCallId(for:)`` gives it after the
    ///   wait.
    func awaitToolCallId(for token: String) async -> ToolCallId {
        await awaitEntry(for: token)
        return toolCallId(for: token)
    }

    /// The wire id of the `Terminal` announce of a run, or `nil` when the run
    /// must wait for its entry.
    ///
    /// A run with an entry gets the id of the entry. A run with no entry while
    /// no projection is open gets "no join" at once. Else the run waits, and the
    /// observer (``observeJoins(_:)``) gets its token when its entry is
    /// written. The check and the wait are one locked operation, so a write
    /// between them cannot be lost.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The tool call id, or `nil` when the run waits.
    func announceToolCallId(for token: String) -> ToolCallId? {
        let join = state.withLock { state -> Join? in
            if let join = state.joins[token] {
                return join
            }
            guard state.isProjectionOpen else {
                state.joins[token] = .unjoined
                return .unjoined
            }
            state.waitingRuns.insert(token)
            return nil
        }
        return join.map { Self.toolCallId(of: $0, token: token) }
    }

    /// The wire id that `join` gives a run.
    ///
    /// - Parameters:
    ///   - join: The entry of the run, or `nil` when it has none.
    ///   - token: The completion token of the run.
    /// - Returns: The tool call id.
    private static func toolCallId(of join: Join?, token: String) -> ToolCallId {
        guard case .joined(let toolCallID)? = join else {
            return ToolCallId(rawValue: token)
        }
        return ToolCallId(rawValue: toolCallID)
    }

    /// Writes "no join" for each waiting run, and for each run that a caller
    /// of ``awaitToolCallId(for:)`` waits for.
    private func sealWaitingRuns() {
        let tokens = state.withLock { state in
            state.waitingRuns.union(state.entryWaiters.values.map(\.token))
        }
        for token in tokens {
            seal(token)
        }
    }

    /// Waits until the run has an entry, until no projection can write one,
    /// or until the calling task is cancelled.
    ///
    /// - Parameter token: The completion token of the run.
    private func awaitEntry(for token: String) async {
        let ticket = state.withLock { state in
            defer { state.nextTicket += 1 }
            return state.nextTicket
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !admitWaiter(EntryWaiter(token: token, continuation: continuation), ticket: ticket) {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.entryWaiters.removeValue(forKey: ticket) }?.continuation.resume()
        }
    }

    /// Records a caller that waits for an entry, unless the wait is over
    /// already. The check and the record are one locked step, so a write or a
    /// cancel between them cannot be lost.
    ///
    /// - Parameters:
    ///   - waiter: The caller.
    ///   - ticket: The ticket of the caller.
    /// - Returns: `true` when the caller waits, and `false` when its wait is
    ///   over: the run has an entry, no projection is open, or the task is
    ///   cancelled.
    private func admitWaiter(_ waiter: EntryWaiter, ticket: Int) -> Bool {
        state.withLock { state in
            if state.joins[waiter.token] != nil || Task.isCancelled {
                return false
            }
            guard state.isProjectionOpen else {
                state.joins[waiter.token] = .unjoined
                return false
            }
            state.entryWaiters[ticket] = waiter
            return true
        }
    }

    /// Writes `join` for a run that has no entry yet, tells the observer when
    /// the run waited for it, and ends the wait of each caller of
    /// ``awaitToolCallId(for:)`` for it. A run that has an entry keeps it.
    ///
    /// - Parameters:
    ///   - join: The entry to write.
    ///   - token: The completion token of the run.
    private func store(_ join: Join, for token: String) {
        let (observer, waiters) = state.withLock { state -> (JoinObserver?, [EntryWaiter]) in
            guard state.joins[token] == nil else {
                return (nil, [])
            }
            state.joins[token] = join
            let tickets = state.entryWaiters.filter { $0.value.token == token }.map(\.key)
            let waiters = tickets.compactMap { state.entryWaiters.removeValue(forKey: $0) }
            guard state.waitingRuns.remove(token) != nil else {
                return (nil, waiters)
            }
            return (state.joinObserver, waiters)
        }
        observer?(token)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
