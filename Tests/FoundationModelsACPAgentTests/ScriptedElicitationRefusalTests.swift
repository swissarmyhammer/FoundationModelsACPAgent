import Testing

@testable import FoundationModelsACPAgent

/// The read of the output of a scripted question: any output that carries
/// the refusal marker is a refusal, and never an answer.
struct ScriptedElicitationRefusalTests {
  /// An action name that the snippet could send, and that is no
  /// ``ScriptedElicitation/Refusal``.
  private static let unknownAction = "dismissed"

  /// A refusal with an unknown action name is read as a cancel, so the pass
  /// ends with a refusal text and does not go on with the marker as the
  /// answer.
  @Test func anUnknownActionIsReadAsACancel() {
    let output = ScriptedElicitation.refusalMarker + Self.unknownAction

    #expect(ScriptedElicitation.refusal(inOutput: output) == .cancel)
  }

  /// An output with no marker is an answer, and no refusal.
  @Test func anOutputWithNoMarkerIsAnAnswer() {
    #expect(ScriptedElicitation.refusal(inOutput: "blue") == nil)
  }

  /// A refusal with a known name keeps its name.
  @Test func aKnownNameKeepsItsRefusal() {
    let output = ScriptedElicitation.refusalMarker + ScriptedElicitation.Refusal.decline.rawValue

    #expect(ScriptedElicitation.refusal(inOutput: output) == .decline)
  }
}
