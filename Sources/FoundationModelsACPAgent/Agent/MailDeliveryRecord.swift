import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

/// One record of the mail delivery of a session in its retained history (D205).
///
/// The session directory counts the turns of a session from its Router journal: one turn for each
/// delivered mail whose body is a user message or a message of another session, in the order of
/// delivery. A fork cut inside a batch (the mail that one Router prompt delivers) rounds to the
/// edges of the batch, and the last completed turn never goes past the start of the answer that
/// runs. The retained ACP history does not show these facts: the agent echoes a user message when
/// it accepts the prompt, not when the session takes the mail, and an action command echoes a user
/// message and delivers no mail. Thus the projector of the session records each delivered mail and
/// the end of each answer in the retained history (``MailDeliveryTrack``), and the fork map reads
/// these records (``ForkSourceHistory``).
///
/// A record is an extension update kind (ACP keeps the names that start with `_` free). The
/// retained history and its file keep it, so the map is the same after a resume from disk. The
/// agent never sends it to a client, and a replay never holds it
/// (``SessionMergeEngine/replayedTranscriptUpdates``).
enum MailDeliveryRecord: Equatable, Sendable {
  /// The session took one mail for an answer.
  ///
  /// - `mail`: The mail.
  /// - `batch`: The first mail of the batch that holds the mail.
  /// - `answer`: The first mail of the answer that delivers the mail.
  case delivered(mail: MailID, batch: MailID, answer: MailID)

  /// The answer whose first mail is `answer` ended.
  case answerEnded(answer: MailID)

  /// The `sessionUpdate` value of a ``delivered(mail:batch:answer:)`` record.
  static let deliveredKind = "_mail_delivered"

  /// The `sessionUpdate` value of an ``answerEnded(answer:)`` record.
  static let answerEndedKind = "_answer_ended"

  /// The names of the members of a record.
  enum MemberName {
    /// The delivered mail.
    static let mail = "mail"

    /// The first mail of the batch.
    static let batch = "batch"

    /// The first mail of the answer.
    static let answer = "answer"
  }

  /// The first mail of the answer that the record is about.
  var answer: MailID {
    switch self {
    case .delivered(_, _, let answer), .answerEnded(let answer):
      return answer
    }
  }

  /// The update of the record.
  var update: SessionUpdate {
    switch self {
    case .delivered(let mail, let batch, let answer):
      return .unknown(
        Self.deliveredKind,
        .object([
          MemberName.mail: .string(mail.description),
          MemberName.batch: .string(batch.description),
          MemberName.answer: .string(answer.description),
        ]))
    case .answerEnded(let answer):
      return .unknown(
        Self.answerEndedKind, .object([MemberName.answer: .string(answer.description)]))
    }
  }

  /// Reads the record of an entry of a retained history.
  ///
  /// - Parameter kind: The kind of the entry.
  /// - Returns: The record, or `nil` for an entry that is no record, or a record whose members do
  ///   not read.
  init?(_ kind: SessionEntry.Kind) {
    guard case .unknown(let type, let payload) = kind, case .object(let members) = payload else {
      return nil
    }
    switch type {
    case Self.deliveredKind:
      guard let mail = Self.mailId(members[MemberName.mail]),
        let batch = Self.mailId(members[MemberName.batch]),
        let answer = Self.mailId(members[MemberName.answer])
      else {
        return nil
      }
      self = .delivered(mail: mail, batch: batch, answer: answer)
    case Self.answerEndedKind:
      guard let answer = Self.mailId(members[MemberName.answer]) else {
        return nil
      }
      self = .answerEnded(answer: answer)
    default:
      return nil
    }
  }

  /// The mail id in one member of a record.
  ///
  /// - Parameter member: The member, or `nil`.
  /// - Returns: The id, or `nil` when the member is not the text of a ULID.
  private static func mailId(_ member: FoundationModelsACP.JSONValue?) -> MailID? {
    guard case .string(let text) = member, let value = ULID(ulidString: text) else {
      return nil
    }
    return MailID(value)
  }
}

extension SessionUpdate {
  /// Whether this update is a record of the mail delivery (``MailDeliveryRecord``).
  var isMailDeliveryRecord: Bool {
    guard case .unknown(let kind, _) = self else {
      return false
    }
    return kind == MailDeliveryRecord.deliveredKind || kind == MailDeliveryRecord.answerEndedKind
  }
}

extension MessageId {
  /// The prefix of the id of the incoming view of a message from another session.
  private static let incomingViewPrefix = "in-"

  /// The id of the incoming view of a message from another session, in the transcript of the
  /// session that got it: the key of the message (the text of the id of its mail) with a prefix.
  ///
  /// - Parameter key: The key of the message.
  /// - Returns: The id.
  static func incomingView(of key: String) -> MessageId {
    MessageId(rawValue: "\(incomingViewPrefix)\(key)")
  }

  /// The key of the message of an incoming view (``incomingView(of:)``).
  ///
  /// - Parameter id: The id of a view.
  /// - Returns: The key, or `nil` for an id that is not the id of an incoming view.
  static func mailKey(ofIncomingView id: MessageId) -> String? {
    guard id.rawValue.hasPrefix(incomingViewPrefix) else { return nil }
    return String(id.rawValue.dropFirst(incomingViewPrefix.count))
  }
}

/// Makes the delivery records (``MailDeliveryRecord``) of the outputs of one Router session.
///
/// The pump of a Router session sends one `mailDelivered` event for each mail of a batch, one
/// after the other, before any other event of the answer. Mail that joins a running answer comes
/// the same way, after other events of the answer. Thus a `mailDelivered` event that directly
/// follows a `mailDelivered` event is in the same batch, and each other one starts a batch. The
/// session runs one answer at a time: the first mail after the end of an answer (`answered` or
/// `answerFailed`) starts the next answer.
struct MailDeliveryTrack: Sendable {
  /// The first mail of the batch of the last event, or `nil` when the last event was no
  /// `mailDelivered` event.
  private var batch: MailID?

  /// The first mail of the answer that runs, or `nil` when no answer runs.
  private var answer: MailID?

  /// Reads one event of the Router session, and gives its record.
  ///
  /// - Parameter event: The event.
  /// - Returns: The record of a delivered mail or of the end of an answer, or `nil` for each other
  ///   event.
  mutating func record(of event: SessionEvent) -> MailDeliveryRecord? {
    guard case .mailDelivered(let mail) = event else {
      batch = nil
      return answerEnd(at: event)
    }
    let batch = self.batch ?? mail
    let answer = self.answer ?? mail
    self.batch = batch
    self.answer = answer
    return .delivered(mail: mail, batch: batch, answer: answer)
  }

  /// The record of the end of the answer that runs, when `event` ends it.
  ///
  /// - Parameter event: An event that is no `mailDelivered` event.
  /// - Returns: The record, or `nil` when the event ends no answer that the track knows.
  private mutating func answerEnd(at event: SessionEvent) -> MailDeliveryRecord? {
    switch event {
    case .answered, .answerFailed:
      guard let answer else {
        return nil
      }
      self.answer = nil
      return .answerEnded(answer: answer)
    default:
      return nil
    }
  }
}

extension SessionMergeEngine {
  /// This history of an earlier build, with the records of the mail delivery that the fork map of
  /// that build counted: each user message whose id is the id of a mail, and each incoming view of
  /// a message from another session, is a delivered mail in a batch and an answer of its own. The
  /// answer of each turn ends before the next turn, and the answer of the last turn ends at the
  /// end of the history: a restore ends each answer that the process did not end.
  ///
  /// - Returns: The history with the records.
  func withEarlierBuildDeliveryRecords() -> SessionMergeEngine {
    var updates: [SessionUpdate] = []
    var lastAnswer: MailID?
    for (entry, update) in zip(entries, transcriptUpdates) {
      updates.append(update)
      guard let mail = Self.earlierBuildMail(of: entry) else { continue }
      if let lastAnswer {
        updates.insert(
          MailDeliveryRecord.answerEnded(answer: lastAnswer).update, at: updates.count - 1)
      }
      updates.append(MailDeliveryRecord.delivered(mail: mail, batch: mail, answer: mail).update)
      lastAnswer = mail
    }
    if let lastAnswer {
      updates.append(MailDeliveryRecord.answerEnded(answer: lastAnswer).update)
    }
    return SessionMergeEngine(replaying: updates + stateUpdates)
  }

  /// The mail of an entry of a history of an earlier build: the mail of a user message whose id
  /// is the text of a ULID, or of an incoming view of a message from another session.
  ///
  /// - Parameter entry: An entry.
  /// - Returns: The mail, or `nil` for an entry that delivered no mail.
  private static func earlierBuildMail(of entry: SessionEntry) -> MailID? {
    let key: String?
    switch entry.kind {
    case .userMessage(let message):
      key = message.messageId.rawValue
    case .sessionMessage(let message):
      key = MessageId.mailKey(ofIncomingView: message.messageId)
    default:
      key = nil
    }
    return key.flatMap(ULID.init(ulidString:)).map(MailID.init)
  }
}
