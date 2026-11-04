import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - Tier 3: the re-drive of an interrupted nested run across two processes
//
// The first `acp-agent-stub acp` starts a child run through the `agents` tool, and the child holds
// its pass at a gate. The test kills the agent with `SIGKILL`: the `agents` call stays open in the
// recording, and the run is an orphan. A second `acp-agent-stub acp` over the same folders resumes
// the root session. It must start the child again after the response, and the end of the child must
// complete the original `agents` call of the root. Only two spawned binaries prove that the
// recording survives the process, and that the re-drive uses the real wire.

/// The re-drive of an interrupted nested run after a cold resume, with real processes.
@Suite(.timeLimit(.minutes(3)))
struct RedriveInterruptedRunsProcessTests {
  // MARK: - Constants

  /// The id of the agent that the root session starts.
  private static let childAgent = "helper"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-REDRIVE-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-REDRIVE-MARKER"

  /// The text that the child plays before it holds at the gate.
  private static let childStartedText = "CHILD-STARTED-TEXT"

  /// The text that the child plays when the second process starts it again.
  private static let redriveText = "CHILD-REDRIVEN-TEXT"

  /// The start of the first message of a restored run.
  private static let restoredRunMessage = "The process stopped while you worked"

  /// The seconds that the test waits for the wire to show the re-drive.
  private static let redriveWaitSeconds = 60

  // MARK: - Fixtures

  /// The script of the first process: the root starts the child, and the child holds.
  ///
  /// - Parameter gate: The path of a file that never exists, so the child never goes on.
  /// - Returns: The JSON text of the script.
  private static func firstScript(gate: URL) -> String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(childPrompt)"},
       "passes":[[{"text":"\(childStartedText)"},{"gate":"\(gate.path)"}]]},
      {"match":{"promptContains":"\(rootPrompt)"},
       "passes":[[
         {"toolCall":{"name":"agents","arguments":
           {"op":"start agent","name":"\(childAgent)","prompt":"\(childPrompt)"}}}]]}
    ]}
    """
  }

  /// The script of the second process: a restored run answers its first message.
  private static var secondScript: String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(restoredRunMessage)"},
       "passes":[[{"text":"\(redriveText)"}]]}
    ]}
    """
  }

  /// Writes the agent folder of the child in the project folder.
  private static func writeChildAgent(in workspace: URL) throws {
    let folder = workspace.appendingPathComponent(".agents/agents/\(childAgent)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let document =
      "---\nname: \(childAgent)\ndescription: The helper test agent.\n---\n\nDo the task.\n"
    try document.write(
      to: folder.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
  }

  /// The environment of a spawned agent: the script, and the configuration home.
  private static func environment(script: String, configHome: URL, label: String) throws
    -> [String: String]
  {
    let file = try TierThreeFixture.writeStubScript(script, label: label)
    return try TierThreeFixture.stubScriptEnvironment(file: file)
      .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
  }

  /// What the first process recorded.
  private struct Recording {
    /// The root session.
    let root: SessionId

    /// The child session.
    let child: SessionId

    /// The id of the `agents` call that the root started in the first process.
    let call: ToolCallId
  }

  /// Runs the first process: the root starts the child, the child plays its first text, and then
  /// the agent is killed.
  ///
  /// - Parameters:
  ///   - workspace: The project folder.
  ///   - configHome: The configuration home.
  /// - Returns: The ids of the two sessions.
  /// - Throws: The spawn, request or wait error.
  private static func recordInterruptedRun(workspace: URL, configHome: URL) async throws
    -> Recording
  {
    let label = "RedriveInterruptedRunsProcessTests-first"
    let gate = makeResolvedDirectory(label: "\(label)-gate").appendingPathComponent("never")
    let agent = try SpawnedACPAgent.start(
      workspace: workspace,
      environment: try environment(
        script: firstScript(gate: gate), configHome: configHome, label: label))
    let model = await ConnectionModel()
    let connection = await model.connect(over: agent.transport)
    _ = try await model.initialize(AgentClientHarness.makeInitializeRequest())
    let session = try await model.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
    let root = session.sessionId
    let events = connection.subscribeToAllSessions().events
    let prompt = Task {
      try await connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    }
    var child: SessionId?
    var call: ToolCallId?
    for await sequenced in events {
      guard case .update(let stream, let update) = WireTraceEvent(sequenced) else {
        continue
      }
      if stream != root, update.agentMessageText.contains(childStartedText) {
        child = stream
      }
      if stream == root, case .toolCallUpdate(let started) = update, call == nil {
        call = started.toolCallId
      }
      if child != nil, call != nil {
        break
      }
    }
    // A kill leaves the runs open in the recording. A close of the wire would cancel the open prompt
    // of the root, and with it the child, and a cancelled child is a finished one.
    _ = try await agent.killAndWait()
    prompt.cancel()
    await connection.close()
    return Recording(
      root: root, child: try #require(child), call: try #require(call))
  }

  // MARK: - The contract

  /// The second process starts the child again after the response, and the end of the child
  /// completes the original `agents` call of the root.
  @Test
  func theSecondProcessStartsTheChildAgainAndCompletesTheOriginalCall() async throws {
    let workspace = makeResolvedDirectory(label: "RedriveInterruptedRunsProcessTests-repo")
    let configHome = makeResolvedDirectory(label: "RedriveInterruptedRunsProcessTests-config")
    try Self.writeChildAgent(in: workspace)
    let recording = try await Self.recordInterruptedRun(workspace: workspace, configHome: configHome)

    let trace = try await Self.resume(recording, workspace: workspace, configHome: configHome)

    let responseIndex = trace.firstIndex(where: \.isResumeResponse)
    let redriveIndex = trace.firstIndex {
      $0.isAgentText(containing: Self.redriveText, on: recording.child)
    }
    let response = try #require(responseIndex)
    let redrive = try #require(redriveIndex)
    let completion = trace.firstIndex {
      $0.isCompletedCall(recording.call, on: recording.root)
    }
    #expect(redrive > response)
    #expect(completion != nil)
  }

  /// Resumes the root in a second process, and reads the wire until the child played the text of
  /// the re-drive and the original call of the root completed.
  ///
  /// - Parameters:
  ///   - recording: What the first process recorded.
  ///   - workspace: The project folder.
  ///   - configHome: The configuration home.
  /// - Returns: The trace of the wire.
  /// - Throws: The spawn, request or wait error.
  private static func resume(
    _ recording: Recording, workspace: URL, configHome: URL
  ) async throws -> [WireTraceEvent] {
    let label = "RedriveInterruptedRunsProcessTests-second"
    let agent = try SpawnedACPAgent.start(
      workspace: workspace,
      environment: try environment(script: secondScript, configHome: configHome, label: label))
    let model = await ConnectionModel()
    let connection = await model.connect(over: agent.transport)
    _ = try await model.initialize(AgentClientHarness.makeInitializeRequest())
    let subscription = connection.subscribeToAllSessions()
    let first = WireTraceEvent.resumeRequest(id: .number(1), sessionId: recording.root)
    let request = ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: workspace.path), sessionId: recording.root)
    let trace = try await subscription.readResumeTrace(
      startingWith: [first],
      settledBy: { event in event.isCompletedCall(recording.call, on: recording.root) },
      timeout: .seconds(redriveWaitSeconds)
    ) {
      _ = try await connection.resumeSession(request)
    }
    await connection.close()
    _ = try await agent.closeStandardInputAndWait()
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
  fileprivate func isCompletedCall(_ id: ToolCallId, on session: SessionId) -> Bool {
    if case .update(let stream, .toolCallUpdate(let call)) = self {
      return stream == session && call.toolCallId == id && call.status == .value(.completed)
    }
    return false
  }
}
