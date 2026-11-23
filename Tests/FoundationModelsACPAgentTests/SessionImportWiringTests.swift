import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The wiring of the import roots (D209, D212): the agent gives the `sessions` tool of each
/// session an ``AgentSessionImporter`` over the import roots of the host, as the host of the
/// external sessions (``CatalogContext/externalSessionHost``).
///
/// The host can replace the import roots of the running agent
/// (``RoutedACPAgent/setImportRoots(_:)``, ``ComposedAgent/setImportRoots(_:)``): a sandboxed app
/// gets the access to a root after the launch, and the next call of the importer reads the new
/// roots.
///
/// Each tool test runs a scripted agent in the test process. The script calls
/// `list external sessions` of the `sessions` tool. The other tests compose the agent over the
/// stub model, and call its importer as the host of the external sessions. The list never waits
/// for the index of external sessions, thus each test waits until the index is idle before it
/// lists. The suite trait closes each harness of a test whose body throws.
@Suite(.closesHarnesses) struct SessionImportWiringTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "SessionImportWiringTests"

  /// The text of the prompt that makes the scripted model call the `sessions` tool.
  private static let importMarker = "LIST-EXTERNAL-SESSIONS-BY-TOOL"

  /// The name of the tool that the script calls.
  private static let sessionsName = "sessions"

  /// The arguments of the `list external sessions` call.
  private static let listExternalArguments = #"{"op":"list external sessions"}"#

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "7c1e0000-0000-4000-8000-000000000002"

  /// The working folder of the Claude Code session of the root.
  private static let claudeFolder = URL(fileURLWithPath: "/work/app", isDirectory: true)

  /// The dotfolder name of the composed agent of the suite.
  private static let dotfolderName = "session-import-wiring-host"

  /// The most sessions of a page of the external sessions that holds each fixture session.
  private static let pageLimit = 10

  // MARK: - Fixtures

  /// Makes a Claude Code root with one session.
  ///
  /// - Returns: The root (`~/.claude`).
  /// - Throws: The error of the write.
  private static func makeClaudeRoot() throws -> URL {
    let root = makeResolvedDirectory(label: label).appendingPathComponent(".claude", isDirectory: true)
    try ImportSessionFiles.writeClaudeCode(id: claudeID, folder: claudeFolder, in: root)
    return root
  }

  /// Makes an agent whose script calls `list external sessions` at the import marker.
  ///
  /// - Parameters:
  ///   - name: The label of the test.
  ///   - importRoots: The import roots of the host.
  /// - Returns: The fixture.
  /// - Throws: The error of the fixture.
  private static func toolFixture(name: String, importRoots: [ImportSourceAgent: URL])
    async throws -> ScriptedPromptFixture
  {
    try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: importMarker,
          play: [.toolCall(name: sessionsName, argumentsJSON: listExternalArguments), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)",
      importRoots: importRoots)
  }

  /// Composes the agent over the stub model with no import root, as a sandboxed app starts it.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The composed agent.
  /// - Throws: The error of the composition.
  private static func composeWithNoRoots(name: String) async throws -> ComposedAgent {
    try await composeStubAgent(name: dotfolderName, label: "\(label)-\(name)")
  }

  /// The first page of the external sessions of an agent, for each source agent and each
  /// folder.
  ///
  /// - Parameter agent: The agent.
  /// - Returns: The page.
  /// - Throws: The error of the importer.
  private static func firstExternalPage(of agent: RoutedACPAgent) async throws
    -> ExternalSessionPage
  {
    let host: any ExternalSessionHost = agent.sessionImporter
    return try await host.externalSessions(ExternalSessionQuery(limit: pageLimit))
  }

  /// Runs the import marker prompt, and gives the output of the tool calls of the session.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The output text.
  /// - Throws: The error of the prompt.
  private static func runListExternalSessions(on fixture: ScriptedPromptFixture) async throws
    -> String
  {
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: importMarker)
    return try ToolOutputText.of(run.updates, in: fixture.sessionId)
  }

  // MARK: - Tests

  @Test("list external sessions through the sessions tool lists a session of the import roots")
  func listExternalSessionsListsASessionOfTheRoots() async throws {
    let fixture = try await Self.toolFixture(
      name: "claude", importRoots: [.claudeCode: try Self.makeClaudeRoot()])
    defer { await fixture.close() }

    let output = try await Self.runListExternalSessions(on: fixture)

    #expect(output.contains(Self.claudeID), "\(output)")
  }

  @Test("list external sessions with no import roots names each source with no access")
  func listExternalSessionsWithNoRootsNamesTheSources() async throws {
    let fixture = try await Self.toolFixture(name: "no-roots", importRoots: [:])
    defer { await fixture.close() }

    let output = try await Self.runListExternalSessions(on: fixture)

    #expect(output.contains("No access to the sessions of codex"), "\(output)")
  }

  @Test("list external sessions after setImportRoots on the agent lists a session of the new root")
  func listExternalSessionsAfterSetImportRootsListsTheNewRoot() async throws {
    let fixture = try await Self.toolFixture(name: "set-roots", importRoots: [:])
    defer { await fixture.close() }

    await fixture.harness.agent.setImportRoots([.claudeCode: try Self.makeClaudeRoot()])

    let output = try await Self.runListExternalSessions(on: fixture)
    #expect(output.contains(Self.claudeID), "\(output)")
  }

  @Test("the external sessions after setImportRoots on the composed agent list the new root")
  func composedSetImportRootsListsTheNewRoot() async throws {
    let composed = try await Self.composeWithNoRoots(name: "composed-set-roots")

    await composed.setImportRoots([.claudeCode: try Self.makeClaudeRoot()])
    await composed.agent.sessionImporter.index.waitUntilIdle()

    let page = try await Self.firstExternalPage(of: composed.agent)
    #expect(page.sessions.map(\.sourceID) == [Self.claudeID])
  }

  @Test("the external sessions of a composed agent with no import roots name each source")
  func composedWithNoRootsNamesEachSourceAsUnreadable() async throws {
    let composed = try await Self.composeWithNoRoots(name: "composed-no-roots")

    let page = try await Self.firstExternalPage(of: composed.agent)

    #expect(page.unreadableSources == ImportSourceAgent.allCases.map(\.rawValue))
  }

  @Test("a continue of a composed agent with no import roots gives sourceUnreadable")
  func composedWithNoRootsRefusesAContinue() async throws {
    let composed = try await Self.composeWithNoRoots(name: "composed-no-roots-import")
    let host: any ExternalSessionHost = composed.agent.sessionImporter
    let request = ExternalSessionContinueRequest(
      session: ExternalSessionID(
        source: ImportSourceAgent.claudeCode.rawValue, sourceID: Self.claudeID))

    await #expect(
      throws: ExternalSessionError.sourceUnreadable(source: ImportSourceAgent.claudeCode.rawValue)
    ) {
      try await host.continueExternalSession(request)
    }
  }
}
