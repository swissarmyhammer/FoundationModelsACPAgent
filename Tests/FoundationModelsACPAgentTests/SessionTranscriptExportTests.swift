import ACPMarkdown
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The export of a session as Markdown from its retained history (D202).
///
/// The agent gives a ``AgentTranscriptExporter`` to the `sessions` tool and to the `sessions`
/// endpoint. The exporter renders the same transcript updates that a `session/resume` replays, with
/// the renderer of FoundationModelsACP. Each test puts a sample history into a session of a
/// scripted agent, or delivers a real message to it. The suite trait closes each harness of a test
/// whose body throws.
@Suite(.closesHarnesses) struct SessionTranscriptExportTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "SessionTranscriptExportTests"

  /// The text of the thought in the sample history.
  private static let thoughtText = "EXPORT-THOUGHT the user wants the build."

  /// The corrective of a session that has no history in this server.
  private static let noHistoryCorrective =
    "This server has no history of the session. Use Export as Markdown… in the app."

  /// The sample history, one `session/update` payload for each line: a user message, a thought,
  /// an agent message, a tool call with a diff, a terminal and a plan.
  private static let sampleLines = [
    #"{"content": [{"text": "Build the app.", "type": "text"}], "messageId": "u1", "sessionUpdate": "user_message"}"#,
    #"{"content": {"text": "\#(thoughtText)", "type": "text"}, "messageId": "th1", "sessionUpdate": "agent_thought_chunk"}"#,
    #"{"content": {"text": "I fix the build.", "type": "text"}, "messageId": "a1", "sessionUpdate": "agent_message_chunk"}"#,
    #"{"plan": {"entries": [{"content": "Fix the build", "priority": "high", "status": "in_progress"}], "planId": "plan-1", "type": "items"}, "sessionUpdate": "plan_update"}"#,
    #"{"content": [{"changes": [{"operation": "modify", "path": "/p/a.swift"}], "patch": {"format": "git_patch", "text": "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-let a = 1\n+let a = 2\n"}, "type": "diff"}], "kind": "edit", "sessionUpdate": "tool_call_update", "status": "completed", "title": "Edit a.swift", "toolCallId": "c1"}"#,
    #"{"command": "swift build", "sessionUpdate": "terminal_update", "terminalId": "term-1"}"#,
    #"{"data": "QnVpbGQgY29tcGxldGUhCg==", "sessionUpdate": "terminal_output_chunk", "terminalId": "term-1"}"#,
    #"{"exitStatus": {"exitCode": 0}, "sessionUpdate": "terminal_update", "terminalId": "term-1"}"#,
    #"{"plan": {"entries": [{"content": "Fix the build", "priority": "high", "status": "completed"}], "planId": "plan-1", "type": "items"}, "sessionUpdate": "plan_update"}"#,
  ]

  /// The text of a directory message from another session.
  private static let messageText = "EXPORT-MESSAGE please read the plan."

  /// The reply of the target to the directory message.
  private static let replyText = "EXPORT-REPLY"

  /// The title of the session that sends the directory message.
  private static let sourceTitle = "Plan the export"

  /// The text of the prompt that makes the scripted model call the `sessions` tool.
  private static let exportMarker = "EXPORT-BY-TOOL"

  /// The name of the `sessions` tool and of its endpoint.
  private static let sessionsName = "sessions"

  /// The file that the `export session` call writes, in the folder of the session.
  private static let exportFileName = "export-by-tool.md"

  /// The query of the `export` field of one session, with no thoughts.
  private static let exportQuery =
    "query($id: ID!) { session(id: $id) { export(format: MARKDOWN, thoughts: false) } }"

  // MARK: - Helpers

  /// The sample history as session updates.
  ///
  /// - Returns: The updates, in order.
  /// - Throws: The error of a line that does not decode.
  private static func sampleUpdates() throws -> [SessionUpdate] {
    try sampleLines.map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
  }

  /// Puts the sample history into the retained history of a session, as the sink of the session
  /// records each update that it sends.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - agent: The agent of the session.
  private static func seed(_ sessionId: SessionId, on agent: RoutedACPAgent) async throws {
    for update in try sampleUpdates() {
      await agent.recordInHistory(update, of: sessionId)
    }
  }

  /// Opens a scripted agent with one session that holds the sample history.
  ///
  /// - Parameters:
  ///   - name: The label of the test.
  ///   - script: The steps of the scripted model.
  /// - Returns: The fixture.
  private static func seededFixture(
    name: String, script: [ScriptedPassStep] = [.endPass]
  ) async throws -> ScriptedPromptFixture {
    let fixture = try await ScriptedPromptFixture.make(script: script, label: "\(label)-\(name)")
    try await seed(fixture.sessionId, on: fixture.harness.agent)
    return fixture
  }

  /// The Markdown that the exporter of `agent` gives for a session.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - agent: The agent.
  ///   - includeThoughts: True to include the thoughts.
  /// - Returns: The Markdown.
  private static func export(
    _ sessionId: SessionId, on agent: RoutedACPAgent, includeThoughts: Bool = false
  ) async throws -> String {
    try await AgentTranscriptExporter(agent: agent).markdown(
      of: try sessionId.ulid(), includeThoughts: includeThoughts)
  }

  /// Closes the agent of `fixture`, which writes the history file of its session, and opens a
  /// second agent over the same working directory.
  ///
  /// - Parameters:
  ///   - fixture: The first fixture.
  ///   - name: The label of the test.
  /// - Returns: The second fixture.
  private static func restart(
    _ fixture: ScriptedPromptFixture, name: String
  ) async throws -> ScriptedPromptFixture {
    await fixture.close()
    return try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-\(name)-second", workingDirectory: fixture.cwd)
  }

  /// Whether an update makes a transcript entry, and is not a state update.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for an update of the transcript.
  private static func isTranscriptUpdate(_ update: SessionUpdate) -> Bool {
    !SessionMergeEngine(replaying: [update]).transcriptUpdates.isEmpty
  }

  // MARK: - The source of the history

  @Test("the export of a live session is the same text as the export after a restart")
  func theLiveExportIsTheExportAfterARestart() async throws {
    let fixture = try await Self.seededFixture(name: "restart")
    let live = try await Self.export(fixture.sessionId, on: fixture.harness.agent)
    let second = try await Self.restart(fixture, name: "restart")
    defer { await second.close() }

    let restarted = try await Self.export(fixture.sessionId, on: second.harness.agent)

    #expect(restarted == live)
  }

  @Test("the export is the render of the updates that a replay of the session sends")
  func theExportIsTheRenderOfTheReplay() async throws {
    let fixture = try await Self.seededFixture(name: "replay")
    defer { await fixture.close() }
    let agent = fixture.harness.agent
    let summary = try #require(
      try await agent.sessionDirectory.summary(of: try fixture.sessionId.ulid()))
    let exported = try await Self.export(fixture.sessionId, on: agent)
    let countBefore = await fixture.collector.updates.count

    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId,
        replayFrom: .start(ReplayFromStart())))
    let replay = await fixture.collector.updates.dropFirst(countBefore)
      .filter { $0.sessionId == fixture.sessionId }.map(\.update)
      .filter(Self.isTranscriptUpdate)

    #expect(
      exported
        == SessionMarkdown.render(
          updates: replay, options: .init(title: summary.title, agentName: summary.agentName)))
  }

  @Test("a session with no history gives the corrective")
  func aSessionWithNoHistoryGivesTheCorrective() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-no-history")
    let second = try await Self.restart(fixture, name: "no-history")
    defer { await second.close() }

    await #expect {
      _ = try await Self.export(fixture.sessionId, on: second.harness.agent)
    } throws: { error in
      String(describing: error) == Self.noHistoryCorrective
    }
  }

  // MARK: - The options

  @Test("an export with the thoughts includes a thought")
  func anExportWithTheThoughtsIncludesAThought() async throws {
    let fixture = try await Self.seededFixture(name: "thoughts-on")
    defer { await fixture.close() }

    let exported = try await Self.export(
      fixture.sessionId, on: fixture.harness.agent, includeThoughts: true)

    #expect(exported.contains(Self.thoughtText))
  }

  @Test("an export with no thoughts leaves a thought out")
  func anExportWithNoThoughtsLeavesAThoughtOut() async throws {
    let fixture = try await Self.seededFixture(name: "thoughts-off")
    defer { await fixture.close() }

    let exported = try await Self.export(fixture.sessionId, on: fixture.harness.agent)

    #expect(!exported.contains(Self.thoughtText))
  }

  // MARK: - A message from another session

  @Test("a delivered message from another session has the heading From and the title")
  func aDeliveredMessageHasTheHeadingFromAndTheTitle() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.onPrompt(containing: Self.messageText, play: [.textDelta(Self.replyText), .endPass]), .endPass],
      label: "\(Self.label)-message")
    defer { await fixture.close() }
    let directory = fixture.harness.agent.sessionDirectory
    let source = try await fixture.harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(
        cwd: makeResolvedDirectory(label: "\(Self.label)-message-source"))
    ).sessionId
    let sourceULID = try source.ulid()
    _ = try await directory.setTitle(Self.sourceTitle, of: sourceULID)
    _ = try await directory.send(
      OutgoingSessionMessage(
        from: .session(sourceULID), to: .session(try fixture.sessionId.ulid()),
        text: Self.messageText, sourceSession: sourceULID))
    let target = fixture.sessionId
    _ = try await fixture.collector.wait(for: "the target replied") { updates in
      updates.contains { $0.sessionId == target && $0.update.agentMessageText == Self.replyText }
    }

    let exported = try await Self.export(target, on: fixture.harness.agent)

    #expect(exported.contains("## From \(Self.sourceTitle)"))
  }

  // MARK: - The tool and the endpoint

  @Test("the export field of the sessions endpoint gives the same text as the export session tool")
  func theEndpointFieldGivesTheTextOfTheTool() async throws {
    let folder = makeResolvedDirectory(label: "\(Self.label)-tool-files")
    let argumentsPath = folder.appendingPathComponent("export.json").path
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: Self.exportMarker,
          play: [.toolCallFromFile(name: Self.sessionsName, path: argumentsPath), .endPass]),
        .endPass,
      ],
      label: "\(Self.label)-tool")
    defer { await fixture.close() }
    let agent = fixture.harness.agent
    let target = try await fixture.harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: fixture.cwd)
    ).sessionId
    try await Self.seed(target, on: agent)
    try #"{"op":"export session","id":"\#(target.rawValue)","path":"\#(Self.exportFileName)"}"#
      .write(toFile: argumentsPath, atomically: true, encoding: .utf8)

    _ = try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.exportMarker)
    let written = try String(
      contentsOf: fixture.cwd.appendingPathComponent(Self.exportFileName), encoding: .utf8)
    let reply = try await SessionsGraph.endpoint(of: agent.sessionDirectory).execute(
      query: Self.exportQuery, variables: ["id": .string(target.rawValue)], operationName: nil,
      viewer: nil)

    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any], "\(reply)")
    let session = try #require(data["session"] as? [String: Any], "\(reply)")
    #expect(session["export"] as? String == written)
  }
}
