// `PromptUpdateRead` — what the update stream of one session held to the
// idle update of a prompt.
//
// One function reads the stream, for each suite of both test targets: the
// in-process suites read the answer text and the stop reason, and the suites
// that drive a spawned `acp-agent` read the stop reason.

import FoundationModelsACP
import FoundationModelsACPClient

/// What the update stream of a session held to the first idle update.
public struct PromptUpdateRead: Sendable {
  /// The text of each agent message chunk, joined in arrival order.
  public var text = ""

  /// The stop reason of the idle update, or `nil` when the stream ended
  /// with no idle update. That is, the connection stopped before the
  /// prompt ended.
  public var stopReason: StopReason?

  /// Creates a read that holds no update.
  public init() {}

  /// Reads `stream` to the first idle update. The request markers of the
  /// stream do not end the read.
  ///
  /// - Parameter stream: The update stream of the session. Subscribe to it
  ///   before the prompt, so it holds each update of the prompt in order.
  /// - Returns: What the stream held.
  public static func collect(from stream: AsyncStream<SessionStreamEvent>) async -> PromptUpdateRead {
    var read = PromptUpdateRead()
    for await case .update(let update) in stream {
      if case .stateUpdate(.idle(let idle)) = update {
        read.stopReason = idle.stopReason
        return read
      }
      read.text += update.agentMessageText
    }
    return read
  }
}
