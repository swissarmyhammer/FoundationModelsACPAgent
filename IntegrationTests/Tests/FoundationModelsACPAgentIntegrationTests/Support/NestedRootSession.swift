import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

/// A spawned `acp-agent-stub acp` with a connected client, one root session, and the prompt of
/// that session in flight. The wire of every session of the tree comes in one stream.
struct NestedRootSession {
  /// The project folder, and the working directory of the agent.
  let workspace: URL

  /// The spawned agent.
  let agent: SpawnedACPAgent

  /// The model of the client connection. It lives as long as the session, because the connection
  /// routes its events through it.
  let model: ConnectionModel

  /// The client side of the wire.
  let connection: ClientSideConnection

  /// The root session.
  let root: SessionId

  /// The events of all sessions, in wire order.
  let subscription: SessionEventSubscription

  /// The prompt of the root session. It ends when the root goes idle, or when the wire fails.
  let prompt: Task<PromptResponse, any Error>

  /// Spawns the agent, opens the root session, and sends the prompt.
  ///
  /// - Parameters:
  ///   - workspace: The project folder, and the working directory of the agent.
  ///   - environment: The environment pairs of the agent (``NestedAgentFixture/environment(script:configHome:label:)``).
  ///   - text: The text of the prompt.
  /// - Returns: The running session.
  /// - Throws: The spawn or request error.
  static func start(workspace: URL, environment: [String: String], prompt text: String)
    async throws -> NestedRootSession
  {
    let connected = try await ConnectedAgent.start(workspace: workspace, environment: environment)
    let (agent, model, connection) = (connected.agent, connected.model, connected.connection)
    let session = try await model.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
    let root = session.sessionId
    let subscription = connection.subscribeToAllSessions()
    let prompt = Task {
      try await connection.prompt(AgentClientHarness.makePromptRequest(sessionId: root, text: text))
    }
    return NestedRootSession(
      workspace: workspace, agent: agent, model: model, connection: connection, root: root,
      subscription: subscription, prompt: prompt)
  }

  /// Ends the client side: cancels the prompt of the root, closes the connection, and reads how the
  /// prompt ended. The kill or the orderly quit of the agent stays with the caller, because the
  /// tests end the process in different ways.
  ///
  /// The prompt may have returned its response, or the cancel here may have ended it
  /// (`CancellationError`), or the end of the wire may have ended it (`ConnectionError.closed`:
  /// the kill, the end of the agent, or the close here). Any other end is a failure of the root
  /// that the trace does not show, so it is recorded as an issue of the test.
  func closeClientSide() async {
    prompt.cancel()
    await connection.close()
    if case .failure(let error) = await prompt.result, !Self.isExpectedPromptEnd(error) {
      Issue.record(error, "The prompt of the root session failed before the end of the test.")
    }
  }

  /// Whether `error` is an end of the root prompt that the end of the test causes: the cancel of
  /// the prompt task, or the close of the connection.
  ///
  /// - Parameter error: The error that the prompt threw.
  /// - Returns: `true` for `CancellationError` and `ConnectionError.closed`. A peer error, a
  ///   timeout and every other error give `false`.
  static func isExpectedPromptEnd(_ error: any Error) -> Bool {
    error is CancellationError || (error as? ConnectionError) == .closed
  }
}
