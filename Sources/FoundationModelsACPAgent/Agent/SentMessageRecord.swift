import Foundation
import FoundationModelsExtras

/// The typed record that the `agents` tool attaches to the tool-call report of each message that
/// it sends as mail (`send agent`, and `send caller` over the mail route of a restored run).
///
/// The record holds the id of the mail, the direction and the receiver. It holds no text of the
/// message. The text is in the arguments of the same tool call.
struct SentMessageRecord: Codable, Equatable, Sendable {
  /// The name of the record type in ``ToolCallAttachment/schemaName``. The `agents` tool owns the
  /// name.
  static let schemaName = "FoundationModelsAgents.AgentMessageSent"

  /// Where a message went.
  enum Direction: String, Codable, Sendable {
    /// From a caller to a run that it started.
    case toChild

    /// From a run to the session that started it.
    case toCaller
  }

  /// The ULID of the mail in the session of the receiver.
  let mailId: String

  /// Where the message went.
  let direction: Direction

  /// The id of the run that got the message. `nil` for a message to a caller.
  let receiverRunId: String?

  /// The ULID of the session that got the mail.
  let receiverSessionId: String
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
