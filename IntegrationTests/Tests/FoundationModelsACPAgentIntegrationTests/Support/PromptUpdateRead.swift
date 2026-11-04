// `PromptUpdateRead` — what the update stream of one session held to the
// idle update of a prompt.
//
// `ClientInteropTests` reads the answer text of a prompt, and
// `ScriptedElicitProcessTests` reads the text, the output of the tool calls
// and the stop reason of a prompt. Both read the stream the same way, so the
// loop stands here and the two suites cannot drift apart.

import Foundation
import FoundationModelsACP

/// What the update stream of a session held to the first idle update.
struct PromptUpdateRead {
  /// The text of the agent message chunks, joined in arrival order.
  var text = ""

  /// The answering fields of the tool call updates, as JSON text.
  var toolOutput = ""

  /// The stop reason of the idle update, or `nil` when the stream ended
  /// with no idle update. That is, the connection stopped before the
  /// prompt ended.
  var stopReason: StopReason?

  /// Reads `stream` to the first idle update.
  ///
  /// - Parameter stream: The update stream of the session. Subscribe to it
  ///   before the prompt, so it holds each update of the prompt in order.
  /// - Returns: What the stream held.
  static func collect(from stream: AsyncStream<SessionStreamEvent>) async -> PromptUpdateRead {
    var read = PromptUpdateRead()
    for await case .update(let update) in stream {
      switch update {
      case .agentMessageChunk(let chunk):
        if case .text(let content) = chunk.content { read.text += content.text }
      case .toolCallUpdate(let call):
        read.toolOutput += answerText(of: call)
      case .stateUpdate(.idle(let idle)):
        read.stopReason = idle.stopReason
        return read
      default:
        break
      }
    }
    return read
  }

  /// The JSON text of the `rawOutput` and the `content` of a tool call
  /// update.
  ///
  /// - Parameter call: The update.
  /// - Returns: The text, or an empty text when the update has neither.
  private static func answerText(of call: ToolCallUpdate) -> String {
    [encoded(call.rawOutput), encoded(call.content)].joined()
  }

  /// The JSON text of the value of a patch field, or empty when it has
  /// none.
  ///
  /// - Parameter field: The patch field.
  /// - Returns: The JSON text.
  private static func encoded<Value: Encodable>(_ field: PatchField<Value>) -> String {
    guard case .value(let value) = field, let data = try? JSONEncoder().encode(value) else {
      return ""
    }
    return String(decoding: data, as: UTF8.self)
  }
}
