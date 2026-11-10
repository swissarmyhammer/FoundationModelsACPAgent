import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The shell composition: the catalog mounts the shell capability with no
/// sandbox (ACPA-19).
///
/// The proof is filesystem truth: a command writes a file inside the
/// working directory, and a command writes a file outside the session root
/// set. Both files are on disk afterwards, because no sandbox confines the
/// command. The agent also sends no permission request for a command.
@Suite(.closesHarnesses) struct ShellCompositionTests {
  // MARK: - Fixtures

  /// A throwaway directory under `/private/tmp`, labeled with this
  /// suite's name and the directory's role.
  ///
  /// - Parameter name: The directory's role.
  /// - Returns: The created directory.
  private static func makeResolvedDirectory(named name: String) -> URL {
    FoundationModelsACPAgentTestSupport.makeResolvedDirectory(
      label: "ShellCompositionTests-\(name)")
  }

  /// Builds the registry the catalog composes over `workingDirectory`,
  /// with the shell store redirected into a throwaway directory.
  ///
  /// The `codeContext:` section is off. This suite does not test the
  /// code context, and each build with the section on starts a
  /// `CodeContext` that runs until the test process ends.
  ///
  /// - Parameter workingDirectory: The session working directory.
  /// - Returns: The built registry.
  /// - Throws: Whatever the catalog build throws.
  private static func makeRegistry(workingDirectory: URL) async throws -> MultiTool.Registry {
    var configuration = AgentConfiguration()
    configuration.tools.codeContext = .disabled
    configuration.tools.shell = .enabled(
      ShellToolOptions(storeDirectory: makeResolvedDirectory(named: "store")))
    return try await CatalogRegistryFixture.makeRegistry(
      workingDirectory: workingDirectory, configuration: configuration)
  }

  // MARK: - Filesystem truth

  /// A command runs in the working directory: the file it writes is on
  /// disk afterwards, with the written content.
  @Test
  func aCommandWritesInsideTheWorkingDirectory() async throws {
    let root = Self.makeResolvedDirectory(named: "write-in")
    let registry = try await Self.makeRegistry(workingDirectory: root)

    _ = try await ShellVerbSupport.invokeExecute(
      in: registry, command: "printf inside > inside.txt", workingDirectory: root)

    let written = root.appendingPathComponent("inside.txt")
    #expect(try String(contentsOf: written, encoding: .utf8) == "inside")
  }

  /// A command writes outside the session root set: no sandbox confines
  /// the shell, so the file is on disk afterwards.
  @Test
  func aCommandWritesOutsideTheRootSet() async throws {
    let root = Self.makeResolvedDirectory(named: "write-out-root")
    let outside = Self.makeResolvedDirectory(named: "write-out-target")
    let registry = try await Self.makeRegistry(workingDirectory: root)
    let written = outside.appendingPathComponent("outside.txt")

    _ = try await ShellVerbSupport.invokeExecute(
      in: registry, command: "printf outside > '\(written.path)'", workingDirectory: root)

    #expect(try String(contentsOf: written, encoding: .utf8) == "outside")
  }

  // MARK: - No permission request

  /// The marker of the prompt that runs the command.
  private static let promptMarker = "Run the prompt command"

  /// The name of the file that the command of the prompt writes.
  private static let promptFileName = "prompt.txt"

  /// The text that the command of the prompt writes.
  private static let promptFileText = "prompt"

  /// The script of the prompt: the prompt with the marker calls `runCode`,
  /// and the snippet runs one shell command that writes
  /// ``promptFileName`` in the session working directory. Each other pass
  /// ends with no output.
  ///
  /// - Returns: The script.
  /// - Throws: When the arguments of the `runCode` call cannot be encoded.
  private static func makePromptScript() throws -> [ScriptedPassStep] {
    let command = "printf \(promptFileText) > \(promptFileName)"
    let snippet = #"return await tools.shell.execute({ command: "\#(command)" });"#
    return try ScriptedPromptFixture.makeToolPromptScript(
      code: snippet, onPromptContaining: promptMarker)
  }

  /// A scripted tool prompt that runs a shell command in the agent sends
  /// no `session/request_permission` to the client.
  ///
  /// The fixture opens a session with `session/new` on the harness
  /// connection, and the prompt goes through `session/prompt` on the same
  /// connection. The file of the command is on disk afterwards, so the
  /// prompt ran. The client recorded no permission request, and the open
  /// session has no pending permission request. The session must be open,
  /// so the zero count cannot come from an empty session list.
  @Test
  func aScriptedToolPromptSendsNoPermissionRequest() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.makePromptScript(), label: "ShellCompositionTests-prompt")
    let recorder = try #require(fixture.harness.elicitations)

    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.promptMarker)

    let permissionRequests = await recorder.permissions
    let pendingPermissionCounts = await MainActor.run {
      fixture.harness.client.openSessions
        .filter { $0.sessionId == fixture.sessionId }
        .map(\.pendingPermissions.count)
    }
    await fixture.close()

    let written = fixture.cwd.appendingPathComponent(Self.promptFileName)
    let writtenText = try String(contentsOf: written, encoding: .utf8)
    #expect(writtenText == Self.promptFileText)
    #expect(permissionRequests.isEmpty)
    #expect(pendingPermissionCounts == [0])
  }
}
