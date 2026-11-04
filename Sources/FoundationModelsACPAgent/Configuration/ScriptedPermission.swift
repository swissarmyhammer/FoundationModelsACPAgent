import Foundation
import FoundationModelsACP
import FoundationModelsExtras

/// The permission request of a ``ScriptedPassStep/permission(title:)`` step.
///
/// The scripted model cannot reach the connection of the session from inside
/// its backend. The step therefore rides the path of the `elicit` step
/// (``ScriptedElicitation``): it plays one `runCode` call whose snippet asks
/// a form question with one required text field named ``answerField``. The
/// ``ElicitationRelay`` of the session knows this field. It does not send
/// `elicitation/create` for the question. It sends `session/request_permission`
/// under the session id of the relay, which is the child id for a child run,
/// and it keeps the claims, the cancel and the user wait of the question.
/// The relay then maps the outcome back to an answer of the question:
///
/// - A selected option is an accepted answer, and the field holds the id of
///   the option. The snippet returns that id, and the pass goes on.
/// - A cancelled outcome is a cancel. The snippet returns the refusal of
///   ``ScriptedElicitation``, and the pass ends.
///
/// A client that does not answer form questions cannot answer the step: the
/// relay applies the same capability gate to it as to an `elicit` step.
enum ScriptedPermission {
  /// The name of the one form field that marks a question as a permission
  /// request. An accepted answer holds the id of the selected option here.
  static let answerField = "scriptedPermission"

  /// The id of the option that allows the operation one time.
  static let allowOptionId = "allow"

  /// The id of the option that rejects the operation one time.
  static let rejectOptionId = "reject"

  /// The label of the option that allows the operation one time.
  static let allowOptionName = "Allow once"

  /// The label of the option that rejects the operation one time.
  static let rejectOptionName = "Reject once"

  /// The reason of the decline for a selected option that the request did
  /// not offer.
  static let unknownOptionReason = "the selected option was not offered"

  /// The options that each request offers, in order.
  static var options: [PermissionOption] {
    [
      PermissionOption(
        kind: .allowOnce, name: allowOptionName,
        optionId: PermissionOptionId(rawValue: allowOptionId)),
      PermissionOption(
        kind: .rejectOnce, name: rejectOptionName,
        optionId: PermissionOptionId(rawValue: rejectOptionId)),
    ]
  }

  /// The arguments of the `runCode` call that asks for permission.
  ///
  /// - Parameter title: The title of the request.
  /// - Returns: The arguments, as JSON.
  /// - Throws: The encoding error.
  static func runCodeArguments(asking title: String) throws -> String {
    let arguments = [NoOpToolCall.snippetProperty: try snippet(asking: title)]
    return String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
  }

  /// The snippet that asks for permission and returns the id of the
  /// selected option. It returns a refusal when the user selects nothing, and
  /// when the sandbox has no `elicit` global.
  ///
  /// - Parameter title: The title of the request.
  /// - Returns: The source of the snippet.
  /// - Throws: The encoding error of the title.
  private static func snippet(asking title: String) throws -> String {
    let literal = String(decoding: try JSONEncoder().encode(title), as: UTF8.self)
    let marker = ScriptedElicitation.refusalMarker
    let unavailable = ScriptedElicitation.Refusal.unavailable.rawValue
    return """
      if (typeof elicit !== "function") { return "\(marker)\(unavailable)"; }
      const reply = await elicit({ message: \(literal), requestedSchema: { type: "object", \
      properties: { \(answerField): { type: "string" } }, required: ["\(answerField)"] } });
      return reply.action === "accept" ? reply.content.\(answerField) : "\(marker)" + reply.action;
      """
  }

  /// Whether a question is the question of a permission step.
  ///
  /// - Parameter request: The question that the run posted.
  /// - Returns: `true` for a form question that has the field ``answerField``.
  static func isPermission(_ request: ElicitationRequest) -> Bool {
    request.requestedSchema?.properties[answerField] != nil
  }

  /// The wire request for a permission question.
  ///
  /// - Parameters:
  ///   - request: The question that the run posted.
  ///   - sessionId: The session of the relay. The request names it.
  /// - Returns: The request to send to the client.
  static func wireRequest(
    for request: ElicitationRequest, sessionId: SessionId
  ) -> RequestPermissionRequest {
    RequestPermissionRequest(options: options, sessionId: sessionId, title: request.message)
  }

  /// Maps the answer of the client to the answer of the question.
  ///
  /// - Parameter response: The answer of the client, or `nil` when the
  ///   request failed.
  /// - Returns: An accept with the selected option id, a decline for an
  ///   option that was not offered, and a cancel for every other outcome.
  static func answer(from response: RequestPermissionResponse?) -> ElicitationResponse {
    switch response?.outcome {
    case .selected(let selected):
      let optionId = selected.optionId.rawValue
      guard options.contains(where: { $0.optionId.rawValue == optionId }) else {
        return .decline(reason: unknownOptionReason)
      }
      return .accept(content: [answerField: .string(optionId)])
    default:
      return .cancel
    }
  }
}
