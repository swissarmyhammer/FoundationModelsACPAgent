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
  /// One implementation serves each question step: the `elicit` step asks the
  /// plain question, and the `permission` step (``ScriptedPermission``)
  /// asks a form question with its own schema and its own accepted value.
  ///
  /// - Parameters:
  ///   - message: The message of the question.
  ///   - requestedSchema: The source of the schema of a form question, or
  ///     `nil` for the plain question.
  ///   - acceptedValue: The source of the expression that gives the output
  ///     of an accepted answer. The expression reads the `reply` variable.
  /// - Returns: The arguments, as JSON.
  /// - Throws: The encoding error.
  static func runCodeArguments(
    asking message: String, requestedSchema: String? = nil,
    acceptedValue: String = defaultAcceptedValue
  ) throws -> String {
    let source = try snippet(
      asking: message, requestedSchema: requestedSchema, acceptedValue: acceptedValue)
    let arguments = [NoOpToolCall.snippetProperty: source]
    return String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
  }

  /// The expression that gives the output of an accepted plain question.
  static let defaultAcceptedValue = "reply.content"

  /// The snippet that asks `message` and returns the answer. It returns a
  /// refusal when the user gives no answer, and when the sandbox has no
  /// `elicit` global.
  ///
  /// - Parameters:
  ///   - message: The message of the question.
  ///   - requestedSchema: The source of the schema of a form question, or
  ///     `nil` for the plain question.
  ///   - acceptedValue: The source of the output of an accepted answer.
  /// - Returns: The source of the snippet.
  /// - Throws: The encoding error of the message.
  private static func snippet(
    asking message: String, requestedSchema: String?, acceptedValue: String
  ) throws -> String {
    let literal = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    let question =
      requestedSchema.map { "{ message: \(literal), requestedSchema: \($0) }" } ?? literal
    return """
      if (typeof elicit !== "function") { return "\(refusalMarker)\(Refusal.unavailable.rawValue)"; }
      const reply = await elicit(\(question));
      return reply.action === "accept" ? \(acceptedValue) : "\(refusalMarker)" + reply.action;
      """
  }

  /// Reads the output of the `runCode` call of a question.
  ///
  /// - Parameter output: The output of the call.
  /// - Returns: The refusal that the output holds, or `nil` for an answer.
  ///   An output that carries the marker is always a refusal. A name that is
  ///   no ``Refusal`` is read as ``Refusal/cancel``: the user gave no
  ///   answer, and the pass must not go on with the marker as the answer.
  static func refusal(inOutput output: String) -> Refusal? {
    guard let marker = output.range(of: refusalMarker) else { return nil }
    let name = output[marker.upperBound...]
    return Refusal.allCases.first { name.hasPrefix($0.rawValue) } ?? .cancel
  }
}
