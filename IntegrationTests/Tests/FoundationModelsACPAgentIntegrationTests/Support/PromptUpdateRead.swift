// `PromptUpdateRead` — what the update stream of one session held to the
// idle update of a prompt.
//
// `SpawnedAgentPromptDrive` reads the stop reason of a prompt with it.

import Foundation
import FoundationModelsACP

/// What the update stream of a session held to the first idle update.
struct PromptUpdateRead {
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
      case .stateUpdate(.idle(let idle)):
        read.stopReason = idle.stopReason
        return read
      default:
        break
      }
    }
    return read
  }
}
