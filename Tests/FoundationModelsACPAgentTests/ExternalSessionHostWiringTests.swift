import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The host of the external sessions (D212 step 3): the agent gives its ``AgentSessionImporter``
/// to the `sessions` tool and endpoint of each session as an `ExternalSessionHost`
/// (``CatalogContext/externalSessionHost``).
///
/// The tool tests run a scripted agent in the test process: the script calls an external session
/// operation of the `sessions` tool. The host tests call the host of the agent. Each test waits
/// until the index is idle first, because a query never waits for the build of the index.
@Suite(.closesHarnesses) struct ExternalSessionHostWiringTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "ExternalSessionHostWiringTests"

  /// The text of the prompt that makes the scripted model list the external sessions.
  private static let listMarker = "LIST-EXTERNAL-BY-TOOL"

  /// The text of the prompt that makes the scripted model read the external session.
  private static let readMarker = "READ-EXTERNAL-BY-TOOL"

  /// The name of the tool that the script calls.
  private static let sessionsName = "sessions"

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "7c1e0000-0000-4000-8000-000000000003"

  /// The working folder of the Claude Code session of the root.
  private static let claudeFolder = URL(fileURLWithPath: "/work/app", isDirectory: true)

  /// The external session of the root.
  private static let session = ExternalSessionID(
    source: ImportSourceAgent.claudeCode.rawValue, sourceID: claudeID)

  // MARK: - Fixtures

  /// Makes a Claude Code root with one session that has an answer.
  ///
  /// - Returns: The root (`~/.claude`).
  /// - Throws: The error of the write.
  private static func makeClaudeRoot() throws -> URL {
    let root = makeResolvedDirectory(label: label).appendingPathComponent(".claude", isDirectory: true)
    try ImportSessionFiles.writeClaudeCode(
      id: claudeID, folder: claudeFolder, withAnswer: true, in: root)
    return root
  }

  /// Makes an agent whose script calls the `list external sessions` and the
  /// `read external session` operations at their markers.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The fixture, with its index idle.
  /// - Throws: The error of the fixture.
  private static func fixture(name: String) async throws -> ScriptedPromptFixture {
    let readArguments =
      #"{"op":"read external session","source":"claude-code","id":"\#(claudeID)"}"#
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: listMarker,
          play: [
            .toolCall(name: sessionsName, argumentsJSON: #"{"op":"list external sessions"}"#),
            .endPass,
          ]),
        .onPrompt(
          containing: readMarker,
          play: [.toolCall(name: sessionsName, argumentsJSON: readArguments), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)",
      importRoots: [.claudeCode: try makeClaudeRoot()])
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    return fixture
  }

  /// Runs a marker prompt, and gives the output of the tool calls of the session.
  ///
  /// - Parameters:
  ///   - marker: The text of the prompt.
  ///   - fixture: The fixture.
  /// - Returns: The output text.
  /// - Throws: The error of the prompt.
  private static func run(_ marker: String, on fixture: ScriptedPromptFixture) async throws
    -> String
  {
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: marker)
    return try ToolOutputText.of(run.updates, in: fixture.sessionId)
  }

  // MARK: - The tool

  @Test("list external sessions through the sessions tool lists the session of the root")
  func theToolListsTheExternalSession() async throws {
    let fixture = try await Self.fixture(name: "list")
    defer { await fixture.close() }

    let output = try await Self.run(Self.listMarker, on: fixture)

    #expect(output.contains(Self.claudeID), "\(output)")
  }

  @Test("read external session through the sessions tool gives the text of the session")
  func theToolReadsTheExternalSession() async throws {
    let fixture = try await Self.fixture(name: "read")
    defer { await fixture.close() }

    let output = try await Self.run(Self.readMarker, on: fixture)

    #expect(output.contains(ImportSessionFiles.claudeCodeQuestion), "\(output)")
  }

  // MARK: - The host

  @Test("the updates of an external session give the user message of the file")
  func theUpdatesGiveTheUserMessage() async throws {
    let fixture = try await Self.fixture(name: "updates")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter

    var entries: [SessionTranscriptEntry] = []
    for try await batch in host.externalSessionUpdates(of: Self.session) {
      entries += batch.entries
    }

    let user = try #require(entries.first { $0.kind == "user_message_chunk" }, "\(entries)")
    guard case .object(let fields) = user.payload, case .object(let content)? = fields["content"]
    else {
      Issue.record("the user entry has no content: \(user)")
      return
    }
    #expect(content["text"] == .string(ImportSessionFiles.claudeCodeQuestion))
  }

  @Test("the updates of a session that the index does not hold end with unknownSession")
  func theUpdatesOfAnUnknownSessionEndWithTheError() async throws {
    let fixture = try await Self.fixture(name: "unknown")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let unknown = ExternalSessionID(source: ImportSourceAgent.claudeCode.rawValue, sourceID: "none")

    await #expect(throws: ExternalSessionError.unknownSession(unknown)) {
      for try await _ in host.externalSessionUpdates(of: unknown) {}
    }
  }

  @Test("continue of an external session makes a new session in the folder")
  func theContinueMakesANewSession() async throws {
    let fixture = try await Self.fixture(name: "continue")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let folder = makeResolvedDirectory(label: "\(Self.label)-continue-folder")

    let summary = try await host.continueExternalSession(
      ExternalSessionContinueRequest(session: Self.session, folder: folder, name: "Continued"))

    #expect(summary.title == "Continued")
    #expect(summary.workingDirectory.standardizedFileURL == folder.standardizedFileURL)
  }

  @Test("continue of a session that the index does not hold gives unknownSession")
  func theContinueOfAnUnknownSessionGivesTheError() async throws {
    let fixture = try await Self.fixture(name: "continue-unknown")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let unknown = ExternalSessionID(source: ImportSourceAgent.claudeCode.rawValue, sourceID: "none")

    await #expect(throws: ExternalSessionError.unknownSession(unknown)) {
      _ = try await host.continueExternalSession(
        ExternalSessionContinueRequest(session: unknown, folder: makeResolvedDirectory(label: Self.label)))
    }
  }

  @Test("a rebuild of the index of a source reads the session again and gives the same row")
  func theRebuildGivesTheSameRow() async throws {
    let fixture = try await Self.fixture(name: "rebuild")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let query = ExternalSessionQuery(limit: 10)
    let before = try await host.externalSessions(query)

    try await host.rebuildExternalSessionIndex(source: ImportSourceAgent.claudeCode.rawValue)
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    let after = try await host.externalSessions(query)

    #expect(after.sessions.map(\.id) == [Self.session])
    #expect(after.sessions == before.sessions)
  }

  @Test("a rebuild of a source with no access gives sourceUnreadable")
  func theRebuildOfASourceWithNoAccessGivesTheError() async throws {
    let fixture = try await Self.fixture(name: "rebuild-no-access")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let codex = ImportSourceAgent.codex.rawValue

    await #expect(throws: ExternalSessionError.sourceUnreadable(source: codex)) {
      try await host.rebuildExternalSessionIndex(source: codex)
    }
    await #expect(throws: ExternalSessionError.sourceUnreadable(source: "none")) {
      try await host.rebuildExternalSessionIndex(source: "none")
    }
  }

  @Test("the counts of the host count the typed session of the root and of its folder")
  func theCountsCountTheTypedSession() async throws {
    let fixture = try await Self.fixture(name: "counts")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter

    let root = try await host.externalSessionCounts(source: nil, folder: nil)
    let folder = try await host.externalSessionCounts(source: nil, folder: Self.claudeFolder)
    let other = try await host.externalSessionCounts(
      source: nil, folder: URL(fileURLWithPath: "/work/other", isDirectory: true))

    #expect(root.typedCount == 1)
    #expect(root.automatedCount == 0)
    #expect(root.indexState.isComplete)
    #expect(folder.typedCount == 1)
    #expect(other.typedCount == 0)
  }
}
