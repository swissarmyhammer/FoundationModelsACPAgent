import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient

/// A spawned `acp-agent-stub acp` with a connected and initialized client. The one place that
/// spawns the agent, connects the model, and runs `initialize` for the nested-agent suites.
struct ConnectedAgent {
  /// The spawned agent.
  let agent: SpawnedACPAgent

  /// The model of the client connection. It lives as long as the connection, because the
  /// connection routes its events through it.
  let model: ConnectionModel

  /// The client side of the wire.
  let connection: ClientSideConnection

  /// Spawns the agent, connects the model over its transport, and initializes it.
  ///
  /// - Parameters:
  ///   - workspace: The project folder, and the working directory of the agent.
  ///   - environment: The environment pairs of the agent (``NestedAgentFixture/environment(script:configHome:label:)``).
  /// - Returns: The running agent with its connection.
  /// - Throws: The spawn error, or the `initialize` error with the stderr of the agent. A failed
  ///   `initialize` kills the agent.
  static func start(workspace: URL, environment: [String: String]) async throws -> ConnectedAgent {
    let agent = try SpawnedACPAgent.start(workspace: workspace, environment: environment)
    let model = await ConnectionModel()
    let connection = await model.connect(over: agent.transport)
    do {
      _ = try await model.initialize(AgentClientHarness.makeInitializeRequest())
    } catch {
      agent.abandon()
      throw agent.report(error)
    }
    return ConnectedAgent(agent: agent, model: model, connection: connection)
  }
}
