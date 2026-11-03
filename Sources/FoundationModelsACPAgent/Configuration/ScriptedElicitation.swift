import Foundation

/// The question of a ``ScriptedPassStep/elicit(message:)`` step.
///
/// The scripted model cannot reach the elicitation API of the session from
/// inside its backend: only a tool in a call gets the `ToolContext` of the
/// session. The step therefore plays one `runCode` call of the session. The
/// snippet of that call uses the `elicit` global of the sandbox. This is
/// the path that each tool of the session uses to ask the user. The
/// question is a form with one required text field named `answer`.
///
/// The `runCode` tool is a tool of the root session and of each child
/// session. So the question of a child session goes out under its own
/// session id, with no special case for a child.
///
/// An accepted answer is the output of the call. A question that gets no
/// answer makes the snippet return a refusal. A refusal is the marker
/// ``refusalMarker`` followed by the name of a ``Refusal``. The backend
/// reads it and ends the pass with the text of the refusal.
enum ScriptedElicitation {
  /// The text that begins the value of a snippet that got no answer.
  static let refusalMarker = "SCRIPTED-ELICIT-REFUSED:"

  /// Why a question got no answer.
  enum Refusal: String, CaseIterable {
    /// The user declined the question.
    case decline

    /// The user cancelled the question, or the question ended.
    case cancel

    /// The session has no `elicit` global, because no user can answer.
    case unavailable

    /// The text that ends the pass.
    var text: String {
      switch self {
      case .decline: ScriptedElicitation.declinedText
      case .cancel: ScriptedElicitation.cancelledText
      case .unavailable: ScriptedElicitation.unavailableText
      }
    }
  }

  /// The text that ends a pass whose question the user declined.
  static let declinedText = "The user declined the question."

  /// The text that ends a pass whose question the user cancelled.
  static let cancelledText = "The user cancelled the question."

  /// The text that ends a pass in a session where no user can answer.
  static let unavailableText = "The question cannot be asked: no user can answer in this session."

  /// The arguments of the `runCode` call that asks `message`.
  ///
  /// - Parameter message: The message of the question.
  /// - Returns: The arguments, as JSON.
  /// - Throws: The encoding error.
  static func runCodeArguments(asking message: String) throws -> String {
    let arguments = [NoOpToolCall.snippetProperty: try snippet(asking: message)]
    return String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
  }

  /// The snippet that asks `message` and returns the answer text. It
  /// returns a refusal when the user gives no answer, and when the
  /// sandbox has no `elicit` global.
  ///
  /// - Parameter message: The message of the question.
  /// - Returns: The source of the snippet.
  /// - Throws: The encoding error of the message.
  private static func snippet(asking message: String) throws -> String {
    let literal = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    return """
      if (typeof elicit !== "function") { return "\(refusalMarker)\(Refusal.unavailable.rawValue)"; }
      const reply = await elicit(\(literal));
      return reply.action === "accept" ? reply.content : "\(refusalMarker)" + reply.action;
      """
  }

  /// Reads the output of the `runCode` call of a question.
  ///
  /// - Parameter output: The output of the call.
  /// - Returns: The refusal that the output holds, or `nil` for an answer.
  static func refusal(inOutput output: String) -> Refusal? {
    guard let marker = output.range(of: refusalMarker) else { return nil }
    let name = output[marker.upperBound...]
    return Refusal.allCases.first { name.hasPrefix($0.rawValue) }
  }
}
