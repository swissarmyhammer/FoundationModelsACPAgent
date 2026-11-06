// `PromptUpdateRead` — what the update stream of one session held to the
// idle update of a prompt.
//
// One function reads the stream, for each suite of both test targets: the
// in-process suites read the answer text and the stop reason, and the suites
// that drive a spawned `acp-agent` read the stop reason. One more function
// does the steps around the read: it subscribes, sends the prompt, and reads.

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

  /// Sends one prompt in an open session, and reads the update stream of the
  /// session to the idle update of the prompt.
  ///
  /// The steps are in one order: subscribe, then send the prompt, then read.
  /// The subscription comes before the prompt, so the stream holds each update
  /// of the prompt in order. The read runs in a task beside the prompt, so a
  /// prompt that fails stops the read and does not leave it open.
  ///
  /// A caller that must act while the prompt is in flight does not use this
  /// function. `SpawnedAgentPromptDrive` keeps the prompt in its own task,
  /// because the question hook runs beside the prompt.
  ///
  /// - Parameters:
  ///   - connection: The client end of the wire.
  ///   - sessionId: The open session.
  ///   - text: The text of the prompt.
  /// - Returns: What the update stream held to the idle update.
  /// - Throws: Whatever the prompt throws.
  public static func onePrompt(
    over connection: ClientSideConnection, in sessionId: SessionId, text: String
  ) async throws -> PromptUpdateRead {
    let updates = connection.subscribe(to: sessionId).updates
    let collector = Task { await collect(from: updates) }
    do {
      _ = try await connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text))
    } catch {
      collector.cancel()
      _ = await collector.value
      throw error
    }
    return await collector.value
  }
}
