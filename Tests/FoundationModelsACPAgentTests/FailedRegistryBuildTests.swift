import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// A registry build that fails after it connected its MCP servers shuts
/// those servers down (task ^0rma59k).
///
/// The build runs in the `open` mode, and the sandbox probe tells that the
/// process is sandboxed. The build connects the stdio server first. Then
/// `buildRegistry()` refuses the `open` mode, and the build fails.
///
/// The server command is a shell that writes its process id to a file and
/// then becomes the `mcp-test-server` executable (`exec`), so the process
/// id is the id of the server. The test waits for the exit of that process.
/// The wait uses no clock: a server that does not exit holds the test until
/// the time limit cancels the wait.
@Suite struct FailedRegistryBuildTests {
  /// The prefix of the directory labels of this suite.
  private static let label = "FailedRegistryBuildTests"

  /// The name of the stdio server.
  private static let serverName = "leaky"

  /// The shell that starts the server.
  private static let shellCommand = "/bin/sh"

  /// The flag of the shell that runs its next argument as a script.
  private static let shellScriptFlag = "-c"

  /// The `--mode` flag and value of the `mcp-test-server` executable, which
  /// answer each call with its arguments.
  private static let echoModeArguments = "--mode echo"

  /// Makes a context in the `open` mode with a sandboxed probe and one stdio
  /// server, which writes its process id to `pidFile`.
  ///
  /// - Parameter pidFile: The file of the process id of the server.
  /// - Returns: The context.
  /// - Throws: Whatever the location of the server executable or the
  ///   context throws.
  private static func makeContext(pidFile: URL) async throws -> CatalogContext {
    let server = try BuiltProductLocator.mcpTestServerURL().path
    let script = "echo $$ > '\(pidFile.path)'; exec '\(server)' \(echoModeArguments)"
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.shell = .disabled
    configuration.tools.codeContext = .disabled
    configuration.tools.mcp = .enabled(servers: [
      MCPServerConfiguration(
        name: serverName,
        transport: .stdio(command: shellCommand, args: [shellScriptFlag, script], env: [:]))
    ])
    return try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeResolvedDirectory(label: "\(label)-work"),
      configuration: configuration, mode: .open, sandboxProbe: .fixed(true))
  }

  /// A build that fails after it connected a stdio server ends the process
  /// of that server.
  @Test
  func aFailedBuildEndsTheProcessOfItsConnectedServer() async throws {
    let pidFile = makeResolvedDirectory(label: "\(Self.label)-pid")
      .appendingPathComponent("server.pid", isDirectory: false)
    let context = try await Self.makeContext(pidFile: pidFile)

    await #expect(throws: ToolModeError.openModeInSandbox) {
      _ = try await ToolCatalog.makeRegistry(context: context)
    }
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

    let exited = await ProcessExitWatch.waitForExit(of: pid) { ProcessState.hasExited(pid) }

    #expect(exited)
  }
}
