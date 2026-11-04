import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

/// The shared setup of the suites that run nested agents in a spawned `acp-agent-stub`: the agent
/// folders in the project folder, and the environment of a process that plays a script.
enum NestedAgentFixture {
  /// The tool list of an agent that can start agents of its own.
  static let agentsToolName = "agents"

  /// Writes the agent folder of one agent in the project folder.
  ///
  /// - Parameters:
  ///   - name: The id of the agent.
  ///   - tools: The `tools` line of the agent, or `nil` for the default tools.
  ///   - workspace: The project folder.
  /// - Throws: The directory-creation or write error.
  static func writeAgent(named name: String, tools: String? = nil, in workspace: URL) throws {
    try AgentFolderFixture.writeProjectAgent(
      id: name, in: workspace, extraKeys: tools.map { ["tools: \($0)"] } ?? [])
  }

  /// The environment of a spawned agent: the script, and the configuration home.
  ///
  /// - Parameters:
  ///   - script: The JSON text of the script (`ScriptedStubScript`).
  ///   - configHome: The configuration home.
  ///   - label: The directory label of the script file.
  /// - Returns: The environment pairs to give a spawned agent.
  /// - Throws: The directory-creation or write error.
  static func environment(script: String, configHome: URL, label: String) throws
    -> [String: String]
  {
    let file = try TierThreeFixture.writeStubScript(script, label: label)
    return try TierThreeFixture.stubScriptEnvironment(file: file)
      .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
  }
}

extension WireTraceEvent {
  /// Whether this event is a `tool_call_update` of the call `id` with the status `completed` on
  /// the stream of `session`. A call that ended as `lost` has another status.
  ///
  /// - Parameters:
  ///   - id: The id of the call.
  ///   - session: The session.
  /// - Returns: `true` for the completed call on that stream.
  func isCompletedCall(_ id: ToolCallId, on session: SessionId) -> Bool {
    if case .update(let stream, .toolCallUpdate(let call)) = self {
      return stream == session && call.toolCallId == id && call.status == .value(.completed)
    }
    return false
  }
}
