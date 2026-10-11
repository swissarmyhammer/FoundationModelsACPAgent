import FoundationModelsACP
import Logging
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
/// projection handled the open record. Then the terminal stream waits for the
/// entry, and sends one announce only after that. It never sends on the
/// completion token and later on the SDK id.
///
/// The first write for a run is final. A later write for the same run changes
/// nothing. Thus each consumer reads the same entry, and each run has one wire
/// id. These events stop a wait, and each one writes "no join" when the run has
/// no entry yet:
///
/// - the settlement of the run (``seal(_:)``),
/// - the end of the prompt (``sealWaitingRuns()``),
/// - the cancellation of the waiting task,
/// - the end of ``joinWaitBound``. A shell run of an agent run uses the shell
///   capability of the root session, but its records go to the event stream of
///   the agent run, not to the projection of the root prompt. Without this
///   bound, such a run would stop the terminal stream of the session until the
///   root prompt ends.
///
/// The session owns one table, because the terminal stream lives for the whole
/// session and each prompt makes a new projection. An entry stays for the life
/// of the session: a background run can settle in a later prompt. An entry is
/// one short string for each run.
///
/// `EventProjection` reads the table from synchronous code, thus a `Mutex`
/// keeps the state, as ``RetainedHistory`` does.
final class RunCallJoinTable: Sendable {
    /// The seconds ``joinWaitBound`` is built from.
    private static let joinWaitBoundSeconds = 1

    /// The longest time that the terminal stream waits for the join of a run.
    /// At the end of the bound, the table writes "no join" for the run, and
    /// the run keeps its completion token as its wire id.
    ///
    /// The projection usually handles the open record before the shell process
    /// writes its first byte, so the usual wait is zero. The bound stops the
    /// wait for a run that no projection of this session sees.
    static let joinWaitBound: Duration = .seconds(joinWaitBoundSeconds)

    /// The join of one run.
    private enum Join: Equatable, Sendable {
        /// Router joined the run to the SDK tool call with this id.
        case joined(toolCallID: String)

        /// No SDK tool call joined the run. The run keeps its completion token.
        case unjoined
    }

    /// The entries and the waiting announces, under one lock.
    private struct State {
        /// The join of each run that has an entry, keyed by the completion
        /// token of the run.
        var joins: [String: Join] = [:]

        /// The announces that wait for the entry of a run, keyed by the
        /// completion token of the run.
        var waiters: [String: [CheckedContinuation<Join, Never>]] = [:]
    }

    /// The state of the table.
    private let state = Mutex(State())

    /// Writes the join of the open record of a run, when the run has no entry
    /// yet, and resumes each announce that waits for it.
    ///
    /// - Parameters:
    ///   - toolCallID: The SDK tool-call id that Router joined to the run, or
    ///     `nil` when no SDK call joined the run.
    ///   - token: The completion token of the run.
    func record(toolCallID: String?, for token: String) {
        store(toolCallID.map { Join.joined(toolCallID: $0) } ?? .unjoined, for: token)
    }

    /// Writes "no join" for a run that has no entry yet, and resumes each
    /// announce that waits for it. A run that has an entry keeps it.
    ///
    /// - Parameter token: The completion token of the run.
    func seal(_ token: String) {
        store(.unjoined, for: token)
    }

    /// Writes "no join" for each run that an announce waits for. The end of a
    /// prompt calls it: no projection writes a join after that.
    func sealWaitingRuns() {
        for token in state.withLock({ Array($0.waiters.keys) }) {
            seal(token)
        }
    }

    /// The wire id of a run, as the entry gives it now: the joined SDK id, or
    /// the completion token when the run has no join.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The tool call id.
    func toolCallId(for token: String) -> ToolCallId {
        Self.toolCallId(of: state.withLock { $0.joins[token] }, token: token)
    }

    /// The wire id of the `Terminal` announce of a run. When the run has no
    /// entry yet, it waits for the entry first, at most ``joinWaitBound``.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The tool call id.
    func announceToolCallId(for token: String) async -> ToolCallId {
        Self.toolCallId(of: await join(of: token), token: token)
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

    /// The entry of a run. When the run has none yet, it waits until a write
    /// gives one. The end of ``joinWaitBound`` and the cancellation of the
    /// caller each write "no join", so the wait always ends.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The entry of the run.
    private func join(of token: String) async -> Join {
        if let join = state.withLock({ $0.joins[token] }) {
            return join
        }
        let bound = Task { await self.sealAtBound(token) }
        defer { bound.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let join = enqueue(continuation, for: token) {
                    continuation.resume(returning: join)
                }
            }
        } onCancel: {
            seal(token)
        }
    }

    /// Waits for ``joinWaitBound``, and then writes "no join" for the run.
    /// A cancelled wait writes nothing.
    ///
    /// - Parameter token: The completion token of the run.
    private func sealAtBound(_ token: String) async {
        do {
            try await Task.sleep(for: Self.joinWaitBound)
        } catch {
            return
        }
        ACPAgentTelemetry.logger(.promptExecution).debug(
            "No projection joined a shell run in the wait bound. The terminal announce goes on the completion token.",
            metadata: [ACPAgentTelemetry.LogMetadataKey.toolCallId: "\(token)"])
        seal(token)
    }

    /// Adds `continuation` to the waiters of a run, or gives the entry when
    /// the run has one. The check and the add are one locked operation, so a
    /// write between them cannot be lost.
    ///
    /// - Parameters:
    ///   - continuation: The waiting announce.
    ///   - token: The completion token of the run.
    /// - Returns: The entry of the run, or `nil` when the continuation waits.
    private func enqueue(_ continuation: CheckedContinuation<Join, Never>, for token: String) -> Join? {
        state.withLock { state in
            if let join = state.joins[token] {
                return join
            }
            state.waiters[token, default: []].append(continuation)
            return nil
        }
    }

    /// Writes `join` for a run that has no entry yet, and resumes each
    /// announce that waits for the run. A run that has an entry keeps it.
    ///
    /// - Parameters:
    ///   - join: The entry to write.
    ///   - token: The completion token of the run.
    private func store(_ join: Join, for token: String) {
        let waiters = state.withLock { state -> [CheckedContinuation<Join, Never>] in
            guard state.joins[token] == nil else {
                return []
            }
            state.joins[token] = join
            return state.waiters.removeValue(forKey: token) ?? []
        }
        for waiter in waiters {
            waiter.resume(returning: join)
        }
    }
}
