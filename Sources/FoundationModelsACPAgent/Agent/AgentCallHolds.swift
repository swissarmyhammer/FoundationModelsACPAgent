import FoundationModelsACP
import Synchronization

/// The holds on the final status of the `agents` calls of one surface.
///
/// An `agents` call starts a child session. The client removes the child when the linked tool call
/// reaches a final status. The final status of the call must come last. It must come after the
/// last update of the child. It must also come after the final `idle` state of the child.
///
/// The parent session places the hold when it sees the open record of the call (``hold(_:)``). A
/// final status of a held call waits in this object (``deferFinal(_:joinedTo:)``). The end of the
/// child releases it (``release(_:)``), and the release gives the held updates back, in order.
///
/// A run is keyed by the completion token of its `agents` call. The join table of the session gives
/// the wire id of the call for the token. One object serves each session of one surface. The
/// parent session places the hold of its own calls. The end of the child releases it.
///
/// The hold and the end can come in either order. A release for a token that has no hold remembers
/// the token. A later hold for that token is not placed. So a hold never outlives its run.
///
/// A call that returns while its run exists keeps the final status (``settleReturnedCall(_:)``). A
/// call that returns with no run has no child traffic to wait for, and it gives the status out.
///
/// A `Mutex` guards the state. The check of a hold and the store of a held status are one locked
/// step. So a release cannot slip between them.
final class AgentCallHolds: Sendable {
  /// What a final status of a call became.
  struct Deferral: Sendable {
    /// The part of the update to send now, or `nil` when only the held status was in it.
    let update: ToolCallUpdate?

    /// The token of the call whose final status the object kept, or `nil` when it kept nothing.
    let heldToken: String?
  }

  /// The most ended tokens that the object remembers.
  private static let endedLimit = 4096

  /// The state that the lock guards.
  private struct State {
    /// The name of the tool whose calls start a child, or `nil` before the bind.
    var toolName: String?

    /// Finds the run that a call started, and reports it as observed. `nil` before the bind.
    var adoptRun: (@Sendable (String) async -> Void)?

    /// The held updates of each held call, keyed by the completion token. A key with an empty
    /// list is a hold with nothing held yet.
    var held: [String: [ToolCallUpdate]] = [:]

    /// The tokens of the calls whose run the announcer observed, and whose run did not end.
    var runs: Set<String> = []

    /// The tokens whose run ended. A hold for such a token is not placed.
    var ended = RecentIDSet<String>(limit: AgentCallHolds.endedLimit)

    /// Remembers that the run of `token` ended, and takes its held updates.
    ///
    /// - Parameter token: The completion token of the call that started the run.
    /// - Returns: The updates that the hold kept, in order. Empty for a run that held nothing.
    mutating func endHold(_ token: String) -> [ToolCallUpdate] {
      ended.insert(token)
      return held.removeValue(forKey: token) ?? []
    }
  }

  /// The state, under its lock.
  private let state = Mutex(State())

  /// Makes an object with no hold.
  init() {}

  /// The number of calls that are held now.
  var heldCount: Int {
    state.withLock { $0.held.count }
  }

  /// Sets the tool whose calls the object holds, and how to find the run of a call.
  ///
  /// - Parameters:
  ///   - toolName: The name of the `agents` tool.
  ///   - adoptRun: Finds the run that the call with this token started, if the runner knows one.
  ///     It reports the run as observed (``runObserved(_:)``). It does nothing when there is none.
  func bind(toolName: String, adoptRun: @escaping @Sendable (String) async -> Void) {
    state.withLock {
      $0.toolName = toolName
      $0.adoptRun = adoptRun
    }
  }

  /// Whether the calls of a tool start a child, so the object holds them.
  ///
  /// - Parameter tool: The name of the tool.
  /// - Returns: `true` for the tool that the bind named.
  func holdsCalls(of tool: String) -> Bool {
    state.withLock { $0.toolName == tool }
  }

  /// Tells that the announcer observed the run of a call. The final status of the call then waits
  /// for the end of the run.
  ///
  /// - Parameter token: The completion token of the call that started the run.
  func runObserved(_ token: String) {
    state.withLock { state in
      if !state.ended.contains(token) {
        state.runs.insert(token)
      }
    }
  }

  /// Holds the final status of the call of a run. A call that is held already keeps what it
  /// holds. A call whose run ended is not held.
  ///
  /// - Parameter token: The completion token of the call that started the run.
  /// - Returns: `true` when the call is held now. `false` when its run ended already.
  @discardableResult
  func hold(_ token: String) -> Bool {
    state.withLock { state in
      guard !state.ended.contains(token) else {
        return false
      }
      if state.held[token] == nil {
        state.held[token] = []
      }
      return true
    }
  }

  /// Ends the hold of a run, and remembers that the run ended.
  ///
  /// - Parameter token: The completion token of the call that started the run.
  /// - Returns: The updates that the hold kept, in order. Each one carries a final status only.
  ///   An empty list for a run that held nothing.
  func release(_ token: String) -> [ToolCallUpdate] {
    state.withLock { state in
      state.runs.remove(token)
      return state.endHold(token)
    }
  }

  /// Ends each hold. The updates that the holds kept go nowhere.
  func releaseAll() {
    state.withLock { state in
      state.held.removeAll()
      state.runs.removeAll()
    }
  }

  /// Keeps the final status of an update when its call is held.
  ///
  /// - Parameters:
  ///   - update: The update of a tool call.
  ///   - wireId: The wire id that the join table gives a completion token.
  /// - Returns: The part of the update to send now, and the token of a call that the object kept.
  func deferFinal(_ update: ToolCallUpdate, joinedTo wireId: (String) -> ToolCallId) -> Deferral {
    guard case .value(let status) = update.status, Self.isFinal(status) else {
      return Deferral(update: update, heldToken: nil)
    }
    let token = state.withLock { state -> String? in
      guard let token = state.held.keys.first(where: { wireId($0) == update.toolCallId }) else {
        return nil
      }
      state.held[token, default: []].append(
        ToolCallUpdate(toolCallId: update.toolCallId, status: update.status))
      return token
    }
    guard let token else {
      return Deferral(update: update, heldToken: nil)
    }
    var rest = update
    rest.status = .unchanged
    return Deferral(
      update: rest == ToolCallUpdate(toolCallId: update.toolCallId) ? nil : rest, heldToken: token)
  }

  /// Decides what happens to a call that returned and kept its final status. When the announcer
  /// observed the run, the end of the child releases the status. When it did not, the runner may
  /// know a run that gave no event yet, and the object adopts it. When no run exists, no child
  /// traffic can follow, and the status is released now.
  ///
  /// - Parameter token: The completion token of the call that returned.
  /// - Returns: The updates to send now, in order. Empty when the end of the child sends them.
  func settleReturnedCall(_ token: String) async -> [ToolCallUpdate] {
    let adoptRun = state.withLock { state -> (@Sendable (String) async -> Void)? in
      state.runs.contains(token) ? nil : state.adoptRun
    }
    await adoptRun?(token)
    return state.withLock { state in
      guard state.held[token] != nil, !state.runs.contains(token) else {
        return []
      }
      return state.endHold(token)
    }
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
