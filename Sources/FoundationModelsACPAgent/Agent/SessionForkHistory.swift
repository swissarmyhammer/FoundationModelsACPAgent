import FoundationModels
import FoundationModelsACP

/// The retained history of the source of a fork at the time of the fork (D205), and the part of
/// it that the fork copies.
///
/// The session directory cuts the history of the Router journal of the source. The agent cuts
/// its own retained ACP history at the same turn, so the client of the fork shows the turns that
/// the model of the fork knows. Both count the turns with the same rule
/// (``SessionMergeEngine/turnStarts(receivedBy:)``).
struct ForkSourceHistory: Sendable {
  /// The retained history of the source, as the agent read it for the fork.
  let history: SessionMergeEngine

  /// The ids that an incoming message of the history names as its recipient: the source, and
  /// each session that the source is a fork of.
  let recipients: Set<SessionId>

  /// Whether the source runs a turn: its last state is `running` or `requires_action`.
  let runsTurn: Bool

  /// The source history as it is now, with the state of its last turn from the history.
  ///
  /// - Parameters:
  ///   - history: The retained history of the source.
  ///   - recipients: The ids that an incoming message names as its recipient.
  /// - Returns: The source history.
  static func snapshot(of history: SessionMergeEngine, recipients: Set<SessionId>)
    -> ForkSourceHistory
  {
    ForkSourceHistory(
      history: history, recipients: recipients, runsTurn: Self.runsTurn(history.agentState))
  }

  /// Whether a state is the state of a turn that runs.
  ///
  /// - Parameter state: The last state of a session, or `nil`.
  /// - Returns: `true` for `running` and `requires_action`.
  private static func runsTurn(_ state: StateUpdate?) -> Bool {
    switch state {
    case .running, .requiresAction:
      return true
    case .idle, .unknown, nil:
      return false
    }
  }

  /// The position in the history of the entry that starts each turn.
  private var turnStarts: [Int] {
    history.turnStarts(receivedBy: recipients)
  }

  /// The index of the turn that holds the entry at a position, with the turn count of the
  /// recipients of the source (``SessionMergeEngine/turn(holding:receivedBy:)``).
  ///
  /// - Parameter position: The position of an entry in the history.
  /// - Returns: The 0-based turn index, or `nil` when the entry comes before the first turn.
  func turn(holding position: Int) -> Int? {
    history.turn(holding: position, receivedBy: recipients)
  }

  /// The number of entries of the history that a fork at a point keeps.
  ///
  /// - ``SessionForkPoint/lastCompletedTurn``: each entry, or the entries before the last turn
  ///   when the source runs a turn.
  /// - ``SessionForkPoint/afterTurn(_:)``: the entries before the next turn.
  /// - ``SessionForkPoint/beforeTurn(_:)``: the entries before the turn.
  ///
  /// - Parameter point: The point of the fork.
  /// - Returns: The number of entries, or `nil` when the history has no turn with the index of
  ///   the point.
  func end(of point: SessionForkPoint) -> Int? {
    let starts = turnStarts
    switch point {
    case .lastCompletedTurn:
      return runsTurn ? (starts.last ?? history.entries.count) : history.entries.count
    case .afterTurn(let turn):
      guard starts.indices.contains(turn) else { return nil }
      return starts.indices.contains(turn + 1) ? starts[turn + 1] : history.entries.count
    case .beforeTurn(let turn):
      guard starts.indices.contains(turn) else { return nil }
      return starts[turn]
    }
  }

  /// Whether a fork at a point keeps no entry after the last completed compaction of the
  /// history. A compaction folds each turn before it, so a fork at such a point cuts in the
  /// folded turns, and the session directory refuses it.
  ///
  /// - Parameter point: The point of the fork.
  /// - Returns: `true` when the point is in the folded turns.
  func isFolded(_ point: SessionForkPoint) -> Bool {
    guard let compaction = history.lastCompactionPosition, let end = end(of: point) else {
      return false
    }
    return end <= compaction
  }

  /// Whether a point names the turn that runs now: ``SessionForkPoint/afterTurn(_:)`` of the
  /// last turn while the source runs a turn.
  ///
  /// - Parameter point: The point of the fork.
  /// - Returns: `true` when the point is after the running turn.
  func isAfterRunningTurn(_ point: SessionForkPoint) -> Bool {
    guard runsTurn, case .afterTurn(let turn) = point else {
      return false
    }
    return turn == turnStarts.count - 1
  }

  /// The history that a fork at a point copies: the first entries of the history, each with its
  /// id and its merged state. The state of the source (its commands, its options, its usage and
  /// its children) is not copied: the fork has its own.
  ///
  /// - Parameter end: The number of entries that the fork keeps (``end(of:)``).
  /// - Returns: The copied history.
  func copiedHistory(endingAt end: Int) -> SessionMergeEngine {
    history.copiedHistory(endingAt: end)
  }
}

extension SessionMergeEngine {
  /// The history of the first entries of this history, each with its id and its merged state,
  /// with no session state.
  ///
  /// - Parameter end: The number of entries to keep.
  /// - Returns: The copied history.
  func copiedHistory(endingAt end: Int) -> SessionMergeEngine {
    SessionMergeEngine(replaying: transcriptUpdates.prefix(end))
  }

  /// The position of the last completed compaction entry, or `nil` when the history has none.
  var lastCompactionPosition: Int? {
    entries.lastIndex { entry in
      guard case .compaction(let compaction) = entry.kind else { return false }
      return compaction.status == .completed
    }
  }

  /// The number of entries that a fork keeps when the agent knows only the transcript of the
  /// fork: a fork that the `fork session` operation of the `sessions` tool made through the
  /// session directory (D205). The ACP id of a tool call is the id of the call in the transcript
  /// (``ACPEventTranslator``), so the tool calls of the fork transcript name the tool calls that
  /// the fork keeps.
  ///
  /// The fork ends before the first tool call that comes after the last tool call that the fork
  /// keeps, and that the fork does not keep: the call that forked, which the session directory
  /// cuts before. When the fork keeps no tool call of this history, the search starts after the
  /// last completed compaction, because the compaction removed the earlier calls from the fork
  /// transcript.
  ///
  /// - Parameter kept: The ids of the tool calls of the fork transcript.
  /// - Returns: The number of entries, or `nil` when no tool call is left out. Such a fork did not
  ///   fork at a tool call of this history, so the tool calls do not tell its cut.
  func forkEnd(keepingToolCalls kept: Set<String>) -> Int? {
    let calls = entries.indices.compactMap { position -> (position: Int, id: String)? in
      guard case .toolCall(let id) = entries[position].id else { return nil }
      return (position, id.rawValue)
    }
    let lastKept = calls.last { kept.contains($0.id) }?.position
    let searchStart = (lastKept ?? lastCompactionPosition).map { $0 + 1 } ?? 0
    let firstLeftOut = calls.first { $0.position >= searchStart && !kept.contains($0.id) }
    return firstLeftOut?.position
  }
}

extension Transcript {
  /// The id of each tool call of the transcript.
  var toolCallIds: Set<String> {
    Set(
      self.flatMap { entry -> [String] in
        guard case .toolCalls(let calls) = entry else { return [] }
        return calls.map(\.id)
      })
  }
}
