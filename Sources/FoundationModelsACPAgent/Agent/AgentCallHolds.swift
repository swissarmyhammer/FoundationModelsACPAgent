import FoundationModelsACP
import Synchronization

/// The holds on the final status of the `agents` calls of one surface.
///
/// An `agents` call starts a child session. The client removes the child when
/// the linked tool call reaches a final status, so the final status of the
/// call must come after the last update of the child and after its final
/// `idle` state. The announcer holds the call from the first event of its run
/// (``hold(_:)``). A final status of a held call waits in this object
/// (``deferFinal(_:joinedTo:)``). The end of the child releases it
/// (``release(_:)``), and the release gives the held updates back, in order.
///
/// A run is keyed by the completion token of its `agents` call. The tool call
/// id of the call is the wire id that the join table of the session gives for
/// the token. One object serves each session of one surface, because the
/// observer of the runs of the surface holds the call and each session
/// projects the calls that its own runs make.
///
/// A `Mutex` guards the state. The check of a hold and the store of a held
/// status are one locked step, so a release cannot slip between them.
final class AgentCallHolds: Sendable {
    /// The held updates of each held run, keyed by the completion token. A key
    /// with an empty list is a hold with nothing held yet.
    private let held = Mutex<[String: [ToolCallUpdate]]>([:])

    /// Makes an object with no hold.
    init() {}

    /// Holds the final status of the call of a run. A run that is held
    /// already keeps what it holds.
    ///
    /// - Parameter token: The completion token of the call that started the
    ///   run.
    func hold(_ token: String) {
        held.withLock { held in
            if held[token] == nil {
                held[token] = []
            }
        }
    }

    /// Ends the hold of a run.
    ///
    /// - Parameter token: The completion token of the call that started the
    ///   run.
    /// - Returns: The updates that the hold kept, in order. Each one carries
    ///   a final status only. An empty list for a run that held nothing.
    func release(_ token: String) -> [ToolCallUpdate] {
        held.withLock { $0.removeValue(forKey: token) ?? [] }
    }

    /// Keeps the final status of an update when its call is held.
    ///
    /// - Parameters:
    ///   - update: The update of a tool call.
    ///   - joinedTo: The wire id that the join table gives a completion token.
    /// - Returns: The part of the update to send now. This is the update
    ///   itself when it holds no final status or when its call is not held.
    ///   It is `nil` when only the held status was in it.
    func deferFinal(_ update: ToolCallUpdate, joinedTo wireId: (String) -> ToolCallId) -> ToolCallUpdate? {
        guard case .value(let status) = update.status, Self.isFinal(status) else {
            return update
        }
        let isDeferred = held.withLock { held -> Bool in
            guard let token = held.keys.first(where: { wireId($0) == update.toolCallId }) else {
                return false
            }
            held[token, default: []].append(ToolCallUpdate(toolCallId: update.toolCallId, status: update.status))
            return true
        }
        guard isDeferred else {
            return update
        }
        var rest = update
        rest.status = .unchanged
        return rest == ToolCallUpdate(toolCallId: update.toolCallId) ? nil : rest
    }

    /// Whether a status ends a tool call.
    ///
    /// - Parameter status: The status.
    /// - Returns: `true` for `completed`, `failed` and `cancelled`.
    private static func isFinal(_ status: ToolCallStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:
            true
        case .pending, .inProgress, .paused, .unknown:
            false
        }
    }
}
