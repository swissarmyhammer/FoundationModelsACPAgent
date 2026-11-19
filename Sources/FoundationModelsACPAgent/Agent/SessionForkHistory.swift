import FoundationModels
import FoundationModelsACP
import FoundationModelsExtras

/// The retained history of the source of a fork at the time of the fork (D205), and the part of
/// it that the fork copies.
///
/// The session directory cuts the Router journal of the source. The agent cuts its own retained
/// ACP history at the same turn, so the client of the fork shows the turns that the model of the
/// fork knows. Both count the turns with the rule of the session directory: one turn for each
/// delivered mail whose body is a user message or a message of another session, in the order of
/// delivery. The agent reads the delivery from the records of its history
/// (``MailDeliveryRecord``): a mail is a turn when the history holds its user message (the id of
/// the user message of a model prompt is the id of its mail) or the incoming view of its message
/// from another session. Thus an action command, which delivers no mail, is no turn; a prompt
/// that waited in the queue takes the place of its delivery, not of its echo; and the result of a
/// background run, which has no such message, is no turn.
struct ForkSourceHistory: Sendable {
  /// One turn of the history.
  private struct Turn {
    /// The position of the first record of the batch that delivered the mail of the turn. A cut
    /// before the turn, or after the turn before it, is at this position.
    let start: Int

    /// The position of the message of the turn.
    let message: Int
  }

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

  /// The turns of the history, in the order of delivery.
  private var turns: [Turn] {
    let records = history.deliveryRecords
    let messages = turnMessagePositions
    var batchStarts: [MailID: Int] = [:]
    return records.compactMap { position, record in
      guard case .delivered(let mail, let batch, _) = record else { return nil }
      let start = batchStarts[batch] ?? position
      batchStarts[batch] = start
      guard let message = messages[mail.description] else { return nil }
      return Turn(start: start, message: message)
    }
  }

  /// The position of each message that can be the message of a turn, by the text of the id of
  /// its mail: each user message, and each incoming view of a message to a recipient of the
  /// source.
  private var turnMessagePositions: [String: Int] {
    var positions: [String: Int] = [:]
    for (position, entry) in history.entries.enumerated() {
      guard let key = turnMessageKey(of: entry) else { continue }
      positions[key] = positions[key] ?? position
    }
    return positions
  }

  /// The text of the id of the mail of the message of an entry, when the entry can be the
  /// message of a turn.
  ///
  /// - Parameter entry: An entry of the history.
  /// - Returns: The text of the id of the mail, or `nil` for an entry that is no such message.
  private func turnMessageKey(of entry: SessionEntry) -> String? {
    switch entry.kind {
    case .userMessage(let message):
      return message.messageId.rawValue
    case .sessionMessage(let message):
      guard case .value(let recipient) = message.recipientSessionId,
        recipients.contains(recipient)
      else {
        return nil
      }
      return MessageId.mailKey(ofIncomingView: message.messageId)
    default:
      return nil
    }
  }

  /// The position of the first record of the answer that runs now, or `nil` when no answer runs.
  /// The last completed turn never goes past it.
  private var runningAnswerStart: Int? {
    guard runsTurn else { return nil }
    let records = history.deliveryRecords
    guard
      let answer = records.last?.record.answer,
      !records.contains(where: { $0.record == .answerEnded(answer: answer) })
    else {
      return nil
    }
    return records.first { $0.record.answer == answer }?.position
  }

  /// The index of the turn that holds the entry at a position. The message of a turn is in its
  /// own turn. Each other entry is in the last turn that starts at or before it.
  ///
  /// - Parameter position: The position of an entry in the history.
  /// - Returns: The 0-based turn index, or `nil` when the entry comes before the first turn.
  func turn(holding position: Int) -> Int? {
    let turns = self.turns
    if let own = turns.firstIndex(where: { $0.message == position }) {
      return own
    }
    let started = turns.prefix { $0.start <= position }.count
    return started == 0 ? nil : started - 1
  }

  /// The number of entries of the history that a fork at a point keeps, as the session directory
  /// cuts its journal.
  ///
  /// - ``SessionForkPoint/lastCompletedTurn``: the entries before the answer that runs now, or
  ///   each entry when no answer runs.
  /// - ``SessionForkPoint/afterTurn(_:)``: the entries before the next turn of a later batch, and
  ///   never past the start of the answer that runs now.
  /// - ``SessionForkPoint/beforeTurn(_:)``: the entries before the batch of the turn.
  ///
  /// - Parameter point: The point of the fork.
  /// - Returns: The number of entries, or `nil` when the history has no turn with the index of
  ///   the point.
  func end(of point: SessionForkPoint) -> Int? {
    let starts = turns.map(\.start)
    let historyEnd = runningAnswerStart ?? history.entries.count
    switch point {
    case .lastCompletedTurn:
      return historyEnd
    case .afterTurn(let turn):
      guard starts.indices.contains(turn) else { return nil }
      return min(starts.first { $0 > starts[turn] } ?? historyEnd, historyEnd)
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

  /// Whether a point names a turn of the answer that runs now:
  /// ``SessionForkPoint/afterTurn(_:)`` of a turn whose batch starts at or after the start of
  /// that answer.
  ///
  /// - Parameter point: The point of the fork.
  /// - Returns: `true` when the point is after a running turn.
  func isAfterRunningTurn(_ point: SessionForkPoint) -> Bool {
    let turns = self.turns
    guard case .afterTurn(let turn) = point, turns.indices.contains(turn),
      let running = runningAnswerStart
    else {
      return false
    }
    return turns[turn].start >= running
  }

  /// The history that a fork at a point copies (``SessionMergeEngine/copiedHistory(endingAt:)``).
  /// The state of the source (its commands, its options, its usage and its children) is not
  /// copied: the fork has its own.
  ///
  /// - Parameter end: The number of entries that the fork keeps (``end(of:)``).
  /// - Returns: The copied history.
  func copiedHistory(endingAt end: Int) -> SessionMergeEngine {
    history.copiedHistory(endingAt: end)
  }
}

extension SessionMergeEngine {
  /// Each record of the mail delivery of this history, with its position, in order.
  var deliveryRecords: [(position: Int, record: MailDeliveryRecord)] {
    entries.enumerated().compactMap { position, entry in
      MailDeliveryRecord(entry.kind).map { (position, $0) }
    }
  }

  /// The history of the first entries of this history, each with its id and its merged state,
  /// with no session state, in the order that the model of a fork knows them.
  ///
  /// The agent echoes a user message when it accepts the prompt, and the session takes the mail
  /// later. So a user message that a record of the history delivers moves to its record: the copy
  /// keeps it when the record is in the copy, and else not. A user message with no record (the
  /// echo of an action command, or a prompt that left the queue before the session took it) stays
  /// where it is: the client of the source showed it there, and the model never saw it.
  ///
  /// - Parameter end: The number of entries to keep.
  /// - Returns: The copied history.
  func copiedHistory(endingAt end: Int) -> SessionMergeEngine {
    let replay = transcriptUpdates
    var userMessages: [String: SessionUpdate] = [:]
    for (entry, update) in zip(entries, replay) {
      guard case .userMessage(let message) = entry.kind else { continue }
      userMessages[message.messageId.rawValue] = update
    }
    let delivered = Set(
      deliveryRecords.compactMap { item -> String? in
        guard case .delivered(let mail, _, _) = item.record else { return nil }
        return mail.description
      })
    let updates = zip(entries.prefix(end), replay).flatMap { entry, update -> [SessionUpdate] in
      switch (entry.kind, MailDeliveryRecord(entry.kind)) {
      case (.userMessage(let message), _) where delivered.contains(message.messageId.rawValue):
        return []
      case (_, .delivered(let mail, _, _)?):
        return [userMessages[mail.description], update].compactMap { $0 }
      default:
        return [update]
      }
    }
    return SessionMergeEngine(replaying: updates)
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
