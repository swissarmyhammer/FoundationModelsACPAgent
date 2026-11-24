import FoundationModelsACP

/// The completion of a history file with the Router journal of its session
/// (``RecordedHistoryRebuild``). A resume and an export read the file through it, so the replay
/// holds the full transcript in the order of the model.
///
/// The merge does two things:
///
/// - **The order of the model.** A file of a build before ACPAgent 5f5af47a can hold the
///   thoughts of a turn after its tool calls and its answer: that build showed each thought at
///   the end of the submission. When the file does not record the order of the model
///   (``SessionHistoryFile/Read/recordsModelOrder``), the thoughts, the agent messages and the
///   tool calls of each turn take the order of the rebuilt journal. A turn starts at a user
///   message, and no entry goes to another turn. An entry keeps its id and its content. An entry
///   that the journal does not give (for example the reply of an action command) keeps its place.
/// - **The missing turns.** A build before ACPAgent 44850640 wrote the file only at the end of a
///   turn, so a stop of the process during a turn lost that turn from the file. Each turn of the
///   journal that starts with a user mail, that the file does not hold, and that comes after the
///   last such turn that the file holds, goes at the end of the transcript of the file. A file
///   that holds no turn of a user mail gets no turn. A file
///   that does not record the mail delivery gets no turn: the ids of its user messages are not
///   the ids of the mail.
///
/// A thought or an agent message of the file is the same item as an entry of the journal when
/// the two texts are the same with no white space, or when the text of the file holds the text
/// of the journal: a build before ACPAgent 5f5af47a kept one agent message over the tool calls
/// of a turn. A tool call is the same item when the id is the same.
enum RecordedHistoryMerge {
  /// The history of `read`, completed with `rebuilt`.
  ///
  /// - Parameters:
  ///   - read: The history in the file, with the facts of its build.
  ///   - rebuilt: The history that the journal of the session gives.
  /// - Returns: The completed history. It is the history of the file when the file holds each
  ///   turn of the journal in the order of the model.
  static func merged(_ read: SessionHistoryFile.Read, with rebuilt: RecordedHistoryRebuild.Rebuilt)
    -> SessionMergeEngine
  {
    var items = Array(zip(read.history.entries, read.history.transcriptUpdates))
    if !read.recordsModelOrder {
      items = inModelOrder(items, journal: rebuilt.history.entries)
    }
    var missing: [SessionUpdate] = []
    if read.recordsMailDelivery {
      missing = missingTurns(of: items.map(\.0), in: rebuilt)
    }
    guard !read.recordsModelOrder || !missing.isEmpty else {
      return read.history
    }
    return SessionMergeEngine(
      replaying: items.map(\.1) + missing + read.history.stateUpdates)
  }

  // MARK: - The order of the model

  /// The items of a file, with the thoughts, the agent messages and the tool calls of each turn
  /// in the order of `journal`.
  ///
  /// - Parameters:
  ///   - items: The entries of the file with their updates, in file order.
  ///   - journal: The entries of the rebuilt journal, in the order of the model.
  /// - Returns: The items in the new order.
  private static func inModelOrder(
    _ items: [(SessionEntry, SessionUpdate)], journal: [SessionEntry]
  ) -> [(SessionEntry, SessionUpdate)] {
    var finder = JournalPositions(journal)
    let positions = items.map { finder.position(of: $0.0) }
    var ordered = items
    var start = 0
    for index in items.indices.dropFirst() + [items.count]
    where index == items.count || isUserMessage(items[index].0) {
      let slots = (start..<index).filter { positions[$0] != nil }
      let sorted = slots.sorted { (positions[$0] ?? 0, $0) < (positions[$1] ?? 0, $1) }
      for (slot, source) in zip(slots, sorted) {
        ordered[slot] = items[source]
      }
      start = index
    }
    return ordered
  }

  /// The positions of the items of the rebuilt journal that a file entry is the same item as.
  /// Each position goes to one file entry at most, in file order.
  private struct JournalPositions {
    /// The key and the position of each thought, agent message and tool call of the journal.
    private let keys: [(key: ItemKey, position: Int)]

    /// The positions that a file entry took.
    private var taken: Set<Int> = []

    /// Makes the positions of `journal`.
    ///
    /// - Parameter journal: The entries of the rebuilt journal.
    init(_ journal: [SessionEntry]) {
      keys = journal.enumerated().compactMap { position, entry in
        ItemKey(entry).map { (key: $0, position: position) }
      }
    }

    /// The position in the journal of the first item that `entry` is the same item as and that
    /// no earlier file entry took.
    ///
    /// - Parameter entry: An entry of the file.
    /// - Returns: The position, or `nil` when no item of the journal is the same item.
    mutating func position(of entry: SessionEntry) -> Int? {
      guard let key = ItemKey(entry),
        let found = keys.first(where: { !taken.contains($0.position) && key.holds($0.key) })
      else {
        return nil
      }
      taken.insert(found.position)
      return found.position
    }
  }

  /// What makes a thought, an agent message or a tool call the same item in a file and in the
  /// journal.
  private enum ItemKey {
    /// A thought, with its text with no white space.
    case thought(String)

    /// An agent message, with its text with no white space.
    case message(String)

    /// A tool call, with its id.
    case toolCall(ToolCallId)

    /// The key of an entry.
    ///
    /// - Parameter entry: An entry.
    /// - Returns: The key, or `nil` for an entry of another kind.
    init?(_ entry: SessionEntry) {
      switch entry.kind {
      case .agentThought(let message):
        self = .thought(Self.text(of: message))
      case .agentMessage(let message):
        self = .message(Self.text(of: message))
      case .toolCall(let call):
        self = .toolCall(call.toolCallId)
      default:
        return nil
      }
    }

    /// Whether the item of a file with this key is the item of the journal with `other`.
    ///
    /// - Parameter other: The key of an item of the journal.
    /// - Returns: True for the same tool call, or for a thought or a message whose text is the
    ///   text of `other` or holds it.
    func holds(_ other: ItemKey) -> Bool {
      switch (self, other) {
      case (.thought(let file), .thought(let journal)), (.message(let file), .message(let journal)):
        file == journal || (!journal.isEmpty && file.contains(journal))
      case (.toolCall(let file), .toolCall(let journal)):
        file == journal
      default:
        false
      }
    }

    /// The text of the text blocks of a message, with no white space.
    ///
    /// - Parameter message: A message.
    /// - Returns: The text.
    private static func text(of message: SessionEntry.Message) -> String {
      message.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
      }.joined().filter { !$0.isWhitespace }
    }
  }

  // MARK: - The missing turns

  /// The updates of each turn of `rebuilt` that starts with a user mail, that `entries` do not
  /// hold, and that comes after the last such turn that `entries` hold. A file that holds no
  /// such turn gets no turn: a build before ACPAgent 44850640 wrote no file before the end of
  /// the first turn, and a file with no turn of a user mail holds other state (for example the
  /// calls of a restored run) that a turn of the journal must not end.
  ///
  /// - Parameters:
  ///   - entries: The entries of the file.
  ///   - rebuilt: The rebuilt journal.
  /// - Returns: The updates of the turns, in journal order. Each turn holds its records of the
  ///   delivery and of the end of the answer.
  private static func missingTurns(
    of entries: [SessionEntry], in rebuilt: RecordedHistoryRebuild.Rebuilt
  ) -> [SessionUpdate] {
    let held = Set(entries.compactMap(userMessageId))
    let journal = Array(zip(rebuilt.history.entries, rebuilt.history.transcriptUpdates))
    let starts = journal.indices.filter { index in
      userMessageId(of: journal[index].0).map(rebuilt.mailMessageIds.contains) == true
    }
    guard
      let lastHeld = starts.lastIndex(where: {
        userMessageId(of: journal[$0].0).map(held.contains) == true
      })
    else {
      return []
    }
    let missingStarts = starts.dropFirst(lastHeld + 1)
    return missingStarts.flatMap { start -> [SessionUpdate] in
      let end =
        journal.indices.dropFirst(start + 1).first { isUserMessage(journal[$0].0) }
        ?? journal.count
      return journal[start..<end].map(\.1)
    }
  }

  // MARK: - The entries

  /// Whether `entry` is a user message.
  ///
  /// - Parameter entry: An entry.
  /// - Returns: True for a user message.
  private static func isUserMessage(_ entry: SessionEntry) -> Bool {
    userMessageId(of: entry) != nil
  }

  /// The id of a user message.
  ///
  /// - Parameter entry: An entry.
  /// - Returns: The id, or `nil` for an entry of another kind.
  private static func userMessageId(of entry: SessionEntry) -> MessageId? {
    guard case .userMessage(let message) = entry.kind else { return nil }
    return message.messageId
  }
}
