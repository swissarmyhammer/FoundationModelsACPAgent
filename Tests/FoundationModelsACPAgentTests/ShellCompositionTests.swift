import Foundation
import FoundationModels
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

  /// A scripted tool prompt that runs a shell command sends no
  /// `session/request_permission` to the client: the collector holds no
  /// notification, and no session has a pending permission request. The
  /// agent never asks the client for a permission.
  @Test
  func aScriptedToolPromptSendsNoPermissionRequest() async throws {
    let harness = try await AgentClientHarness.makeRecording()
    let collector = try #require(harness.collector)
    _ = try await harness.connection.initialize(
      AgentClientHarness.makeInitializeRequest())

    let root = Self.makeResolvedDirectory(named: "prompt")
    let registry = try await Self.makeRegistry(workingDirectory: root)
    let tool = try #require(registry.tools[ShellVerbSupport.executeVerbPath])
    let argumentsJSON = try ShellVerbSupport.executeArgumentsJSON(
      command: "printf prompt > prompt.txt", workingDirectory: root)
    let backend = ScriptedLLMContainer(
      script: [.toolCall(name: tool.name, argumentsJSON: argumentsJSON), .endPass]
    ).makeSession(instructions: nil, tools: [tool])

    _ = try await backend.respond(to: "run the command", maxTokens: nil)

    let written = root.appendingPathComponent("prompt.txt")
    #expect(try String(contentsOf: written, encoding: .utf8) == "prompt")
    #expect(await collector.updates.isEmpty)
    let pendingPermissionCounts = await MainActor.run {
      harness.client.openSessions.map(\.pendingPermissions.count)
    }
    #expect(pendingPermissionCounts.allSatisfy { $0 == 0 })
    await harness.close()
  }
}
