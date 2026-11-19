import Foundation
import FoundationModelsACP

/// One record of the date at which the retained history of a session first held a message entry
/// (D207 (a)).
///
/// The ACP wire gives no date, so the transcript search takes the date of a chunk from the
/// history. The retained history (``RetainedHistory``) records the date of each new user message
/// and of each new message between sessions: these are the entries that start a turn. The search
/// gives each entry the date of the last dated entry at or before it
/// (``SessionMergeEngine/recordedEntryDates``), so each chunk of a turn has the date of its turn.
///
/// A record is an extension update kind (ACP keeps the names that start with `_` free), as a
/// record of the mail delivery (``MailDeliveryRecord``). The retained history and its file keep
/// it, so the same history always gives the same dates. The agent never sends it to a client,
/// and a replay never holds it (``SessionMergeEngine/replayedTranscriptUpdates``).
struct EntryDateRecord: Equatable, Sendable {
  /// The `sessionUpdate` value of a record.
  static let kind = "_entry_dated"

  /// The names of the members of a record.
  enum MemberName {
    /// The text form of the id of the dated entry (`SessionEntry.ID.searchHitID`).
    static let entry = "entry"

    /// The date, as ISO 8601 text with fractional seconds.
    static let date = "date"
  }

  /// The format of the date in a record: ISO 8601 with fractional seconds, so a date reads back
  /// to the millisecond.
  private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// The dated entry.
  let entry: SessionEntry.ID

  /// The date at which the history first held the entry.
  let date: Date

  /// Makes a record.
  ///
  /// - Parameters:
  ///   - entry: The dated entry.
  ///   - date: The date at which the history first held the entry.
  init(entry: SessionEntry.ID, date: Date) {
    self.entry = entry
    self.date = date
  }

  /// Reads the record of an entry of a retained history.
  ///
  /// - Parameter kind: The kind of the entry.
  /// - Returns: The record, or `nil` for an entry that is no record, or a record whose members do
  ///   not read.
  init?(_ kind: SessionEntry.Kind) {
    guard case .unknown(Self.kind, .object(let members)) = kind,
      case .string(let entryText)? = members[MemberName.entry],
      case .string(let dateText)? = members[MemberName.date],
      let entry = SessionEntry.ID(searchHitID: entryText),
      let date = try? Date(dateText, strategy: Self.dateFormat)
    else {
      return nil
    }
    self.init(entry: entry, date: date)
  }

  /// The update of the record.
  var update: SessionUpdate {
    .unknown(
      Self.kind,
      .object([
        MemberName.entry: .string(entry.searchHitID),
        MemberName.date: .string(date.formatted(Self.dateFormat)),
      ]))
  }
}

extension SessionUpdate {
  /// Whether this update is a record of the date of an entry (``EntryDateRecord``).
  var isEntryDateRecord: Bool {
    guard case .unknown(let kind, _) = self else {
      return false
    }
    return kind == EntryDateRecord.kind
  }
}

extension SessionEntry {
  /// Whether the retained history records the date at which it first held this entry: a user
  /// message or a message between sessions, the entries that start a turn.
  var isDatedInHistory: Bool {
    switch kind {
    case .userMessage, .sessionMessage:
      return true
    case .agentMessage, .agentThought, .toolCall, .terminal, .plan, .compaction, .unknown:
      return false
    }
  }
}

extension SessionMergeEngine {
  /// The date of each entry of this history that the history dated: the date of the last dated
  /// entry at or before it (``EntryDateRecord``). An entry before the first dated entry, and a
  /// record, has no date.
  var recordedEntryDates: [SessionEntry.ID: Date] {
    let recorded = Dictionary(
      entries.compactMap { EntryDateRecord($0.kind) }.map { ($0.entry, $0.date) },
      uniquingKeysWith: { first, _ in first })
    return
      entries
      .filter { EntryDateRecord($0.kind) == nil }
      .reduce(into: (current: Date?.none, dates: [SessionEntry.ID: Date]())) { state, entry in
        state.current = recorded[entry.id] ?? state.current
        state.dates[entry.id] = state.current
      }
      .dates
  }
}
