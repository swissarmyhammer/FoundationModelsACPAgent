import Foundation
import FoundationModelsACP

/// The output of the tool calls of a session, as one text, for a test that reads what a tool
/// gave the model.
enum ToolOutputText {
  /// The JSON text of the outputs of the tool calls of one session: the `rawOutput` and the
  /// `content` of each tool call update, and never the `rawInput`. A slash is not escaped, so a
  /// link reads as it is.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - sessionId: The session.
  /// - Returns: The texts, joined.
  /// - Throws: The error of an encode.
  static func of(
    _ updates: [UpdateSessionNotification], in sessionId: SessionId
  ) throws -> String {
    try updates.filter { $0.sessionId == sessionId }.compactMap { notification -> String? in
      guard case .toolCallUpdate(let update) = notification.update else {
        return nil
      }
      return try encodedText(of: update.rawOutput) + encodedText(of: update.content)
    }.joined()
  }

  /// The JSON text of the value of a patch field, or empty when it has none.
  ///
  /// - Parameter field: The field.
  /// - Returns: The text.
  /// - Throws: The error of the encode.
  private static func encodedText<Value: Encodable>(of field: PatchField<Value>) throws -> String {
    guard case .value(let value) = field else {
      return ""
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
