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

  /// The path of a gate file that never exists, so a script step that waits for it holds until a
  /// stop of the run ends the pass.
  ///
  /// - Parameter label: The directory label of the gate.
  /// - Returns: The path of the gate file.
  static func gateFile(label: String) -> URL {
    makeResolvedDirectory(label: "\(label)-gate").appendingPathComponent("never")
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

extension NestedAgentFixture {
  /// Resumes `root` in a new process over the same folders, and reads the wire until the trace is
  /// settled. Then it closes the connection and the input of the agent.
  ///
  /// - Parameters:
  ///   - root: The session to resume.
  ///   - workspace: The project folder.
  ///   - configHome: The configuration home.
  ///   - script: The JSON text of the script of the new process.
  ///   - label: The directory label of the script file.
  ///   - replayFrom: The replay of the request, or `nil` for a resume without replay.
  ///   - settledBy: Tells the last event to read after the response.
  ///   - timeout: The longest time that the read waits.
  /// - Returns: The trace of the wire, from the request.
  /// - Throws: The spawn, request or wait error.
  static func resumeTrace(
    of root: SessionId, workspace: URL, configHome: URL, script: String, label: String,
    replayFrom: ReplayFrom? = nil, settledBy: @escaping @Sendable (WireTraceEvent) -> Bool,
    timeout: Duration
  ) async throws -> [WireTraceEvent] {
    let connected = try await ConnectedAgent.start(
      workspace: workspace,
      environment: environment(script: script, configHome: configHome, label: label))
    let subscription = connected.connection.subscribeToAllSessions()
    let request = ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: workspace.path), sessionId: root, replayFrom: replayFrom)
    let trace = try await subscription.readResumeTrace(
      startingWith: [.resumeRequest(id: .number(1), sessionId: root)],
      settledBy: settledBy, timeout: timeout
    ) {
      _ = try await connected.connection.resumeSession(request)
    }
    await connected.connection.close()
    _ = try await connected.agent.closeStandardInputAndWait()
    return trace
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
    guard stream == session, case .toolCallUpdate(let call)? = sessionUpdate else {
      return false
    }
    return call.toolCallId == id && call.status == .value(.completed)
  }
}
