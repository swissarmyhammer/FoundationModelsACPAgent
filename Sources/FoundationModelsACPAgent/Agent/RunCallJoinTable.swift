import FoundationModelsACP
import Synchronization

/// The join of each tool run of one session to the SDK tool call that started
/// it, keyed by the completion token of the run (task ^9xk3xf4).
///
/// One tool run has two ids. Router joins them on the
/// `toolInvocation(record, toolCallID:)` event of the open record. Two
/// consumers send updates of one run, and both must use one wire id:
///
/// - ``EventProjection`` reads the `SessionEvent` stream of the prompt. It
///   writes the join when it handles the open record, and it sends each run
///   update on the id that this table gives (``toolCallId(for:)``).
/// - ``TerminalStream`` reads the host-owned shell output stream. It does not
///   see the open record. It reads the id of its `Terminal` announce from this
///   table (``announceToolCallId(for:)``).
///
/// The two streams have no common order: a shell chunk can come before the
/// projection handled the open record. Then the run waits for its entry: the
/// terminal stream keeps the events of that run, and the table tells it when
/// the entry is written (``observeJoins(_:)``). The terminal stream sends one
/// announce only after that. It never sends on the completion token and later
/// on the SDK id.
///
/// The first write for a run is final. A later write for the same run changes
/// nothing. Thus each consumer reads the same entry, and each run has one wire
/// id. No time decides an entry. Only the consumers of the event stream of the
/// root prompt write one:
///
/// - the open record of the run (``record(toolCallID:for:)``),
/// - the settlement of the run (``seal(_:)``),
/// - the end of the prompt (``closePrompt()``): each waiting run gets "no join".
///   A run whose first event comes while no prompt is open gets "no join" at
///   once, because no projection writes an entry then.
/// - the end of an agent run (``runDidEnd(tool:)``): each waiting run gets
///   "no join". An agent run (the `agents` tool) uses the shell capability of
///   the root session, but its tool records go to the event stream of the
///   agent run, which FoundationModelsAgents reads in a private loop. No code
///   of this package sees them, so no projection writes an entry for a shell
///   run of an agent run. The agent run sends no wire update of its tool runs,
///   so "no join" is the correct entry for them.
///
/// Known limit of the agent-run write: a root run that starts just after an
/// agent run ended, and whose first chunk comes before the projection handled
/// its open record, also gets "no join". Exact entries for the runs of an
/// agent run need FoundationModelsAgents to give the host the tool records of
/// each run.
///
/// The session owns one table, because the terminal stream lives for the whole
/// session and each prompt makes a new projection. An entry stays for the life
/// of the session: a background run can settle in a later prompt. An entry is
/// one short string for each run.
///
/// `EventProjection` reads the table from synchronous code, thus a `Mutex`
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

        /// Whether a root prompt is open, so that a projection can write an
        /// entry.
        var isPromptOpen = false
    }

    /// The name of the `agents` tool of the session, or `nil` when the
    /// session has no `agents` tool. The end of a run of this tool ends an
    /// agent run (``runDidEnd(tool:)``).
    let agentsToolName: String?

    /// The state of the table.
    private let state = Mutex(State())

    /// Makes an empty table.
    ///
    /// - Parameter agentsToolName: The name of the `agents` tool of the
    ///   session, or `nil` when the session has no `agents` tool.
    init(agentsToolName: String? = nil) {
        self.agentsToolName = agentsToolName
    }

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

    /// Records that a root prompt is open. Call it before the prompt starts
    /// its Router stream, so that a run of the prompt waits for the entry that
    /// the projection writes.
    func openPrompt() {
        state.withLock { $0.isPromptOpen = true }
    }

    /// Records that the root prompt ended, and writes "no join" for each
    /// waiting run: no projection writes an entry after this point.
    func closePrompt() {
        state.withLock { $0.isPromptOpen = false }
        sealWaitingRuns()
    }

    /// Writes "no join" for each waiting run when `tool` is the `agents`
    /// tool: a run of that tool ended, so an agent run ended. The projection
    /// calls it for each close record and for each settlement.
    ///
    /// - Parameter tool: The tool of the run that ended.
    func runDidEnd(tool: String) {
        guard tool == agentsToolName else {
            return
        }
        sealWaitingRuns()
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

    /// The wire id of the `Terminal` announce of a run, or `nil` when the run
    /// must wait for its entry.
    ///
    /// A run with an entry gets the id of the entry. A run with no entry while
    /// no prompt is open gets "no join" at once. Else the run waits, and the
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
            guard state.isPromptOpen else {
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

    /// Writes "no join" for each waiting run.
    private func sealWaitingRuns() {
        for token in state.withLock({ Array($0.waitingRuns) }) {
            seal(token)
        }
    }

    /// Writes `join` for a run that has no entry yet, and tells the observer
    /// when the run waited for it. A run that has an entry keeps it.
    ///
    /// - Parameters:
    ///   - join: The entry to write.
    ///   - token: The completion token of the run.
    private func store(_ join: Join, for token: String) {
        let observer = state.withLock { state -> JoinObserver? in
            guard state.joins[token] == nil else {
                return nil
            }
            state.joins[token] = join
            guard state.waitingRuns.remove(token) != nil else {
                return nil
            }
            return state.joinObserver
        }
        observer?(token)
    }
}
