import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The wiring of the importer (D209 (l)): the agent gives the `sessions` tool of each session an
/// ``AgentSessionImporter`` over the import roots of the host, through
/// ``CatalogContext/sessionImporter``.
///
/// Each test runs a scripted agent in the test process. The script calls `list imports` of the
/// `sessions` tool. The suite trait closes each harness of a test whose body throws.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SessionImportWiringTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "SessionImportWiringTests"

  /// The text of the prompt that makes the scripted model call the `sessions` tool.
  private static let importMarker = "LIST-IMPORTS-BY-TOOL"

  /// The name of the tool that the script calls.
  private static let sessionsName = "sessions"

  /// The arguments of the `list imports` call.
  private static let listImportsArguments = #"{"op":"list imports"}"#

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "7c1e0000-0000-4000-8000-000000000002"

  /// The working folder of the Claude Code session of the root.
  private static let claudeFolder = URL(fileURLWithPath: "/work/app", isDirectory: true)

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

  /// Makes an agent whose script calls `list imports` at the import marker.
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
          play: [.toolCall(name: sessionsName, argumentsJSON: listImportsArguments), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)",
      importRoots: importRoots)
  }

  /// Runs the import marker prompt, and gives the output of the tool calls of the session.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The output text.
  /// - Throws: The error of the prompt.
  private static func runListImports(on fixture: ScriptedPromptFixture) async throws -> String {
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: importMarker)
    return try ToolOutputText.of(run.updates, in: fixture.sessionId)
  }

  // MARK: - Tests

  @Test("list imports through the sessions tool lists a session of the import roots")
  func listImportsListsASessionOfTheRoots() async throws {
    let fixture = try await Self.toolFixture(
      name: "claude", importRoots: [.claudeCode: try Self.makeClaudeRoot()])
    defer { await fixture.close() }

    let output = try await Self.runListImports(on: fixture)

    #expect(output.contains(Self.claudeID), "\(output)")
  }

  @Test("list imports with no import roots names each source with no access")
  func listImportsWithNoRootsNamesTheSources() async throws {
    let fixture = try await Self.toolFixture(name: "no-roots", importRoots: [:])
    defer { await fixture.close() }

    let output = try await Self.runListImports(on: fixture)

    #expect(output.contains("No access to the sessions of codex"), "\(output)")
  }
}
