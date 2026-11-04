import Foundation
import FoundationModelsExtras

/// The typed record that the `agents` tool attaches to the tool-call report of each message that
/// it sends as mail (`send agent`, and `send caller` over the mail route of a restored run).
///
/// The record holds the id of the mail and the receiver. It holds no text of the
/// message. The text is in the arguments of the same tool call.
struct SentMessageRecord: Equatable, Sendable {
  /// The name of the record type in ``ToolCallAttachment/schemaName``. The `agents` tool owns the
  /// name.
  static let schemaName = "FoundationModelsAgents.AgentMessageSent"

  /// Who got a message.
  enum Receiver: Equatable, Sendable {
    /// A run that a caller started. The case holds the id of the run.
    case run(id: String)

    /// The session that started the run.
    case caller
  }

  /// The ULID of the mail in the session of the receiver.
  let mailId: String

  /// Who got the message.
  let receiver: Receiver

  /// The ULID of the session that got the mail.
  let receiverSessionId: String
}

/// The wire shape of the record: the keys `mailId`, `direction`, `receiverRunId` and
/// `receiverSessionId`. The peer client reads them. `receiverRunId` is absent for a message to a
/// caller. A document with the wrong pairing of `direction` and `receiverRunId` does not decode.
extension SentMessageRecord: Codable {
  /// The values of the key `direction` on the wire.
  private enum Direction: String, Codable {
    /// From a caller to a run that it started.
    case toChild

    /// From a run to the session that started it.
    case toCaller
  }

  private enum CodingKeys: String, CodingKey {
    case mailId
    case direction
    case receiverRunId
    case receiverSessionId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mailId = try container.decode(String.self, forKey: .mailId)
    receiverSessionId = try container.decode(String.self, forKey: .receiverSessionId)
    let runId = try container.decodeIfPresent(String.self, forKey: .receiverRunId)
    switch try container.decode(Direction.self, forKey: .direction) {
    case .toChild:
      guard let runId else {
        throw DecodingError.keyNotFound(
          CodingKeys.receiverRunId,
          .init(
            codingPath: container.codingPath,
            debugDescription: "A message to a child names the run that got it."))
      }
      receiver = .run(id: runId)
    case .toCaller:
      guard runId == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .receiverRunId, in: container,
          debugDescription: "A message to a caller names no run.")
      }
      receiver = .caller
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mailId, forKey: .mailId)
    try container.encode(receiverSessionId, forKey: .receiverSessionId)
    switch receiver {
    case .run(let id):
      try container.encode(Direction.toChild, forKey: .direction)
      try container.encode(id, forKey: .receiverRunId)
    case .caller:
      try container.encode(Direction.toCaller, forKey: .direction)
    }
  }
}

extension SentMessageRecord {
  /// Reads the record of an attachment.
  ///
  /// - Parameter attachment: An attachment of a tool-call report.
  /// - Returns: The record. `nil` when the attachment is not a sent-message record, or when its
  ///   document does not decode.
  init?(attachment: ToolCallAttachment) {
    guard attachment.schemaName == Self.schemaName,
      let record = try? JSONDecoder().decode(Self.self, from: Data(attachment.contentJSON.utf8))
    else {
      return nil
    }
    self = record
  }
}
