import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// A session surface that fails after it built its registry gives back what
/// the build took (task ^2zm9hbk).
///
/// The surface composes in the `open` mode with the shell on, so its build
/// leases the shell store of the working directory. The sandbox probe turns
/// on at the first conflict-version read of the agent registry. That read
/// comes inside `AgentsComposition.compose`, after the build. Then
/// `AgentEnvironment.make` refuses the `open` mode of the skills registry, and
/// the surface fails.
///
/// A shell store lease stays until something releases it. The test holds a
/// lease of its own on the same store. After the failure it releases its
/// lease and leases the store again. When the surface released its lease,
/// the store of the second lease is a new store.
@Suite struct FailedSessionSurfaceTests {
  /// The prefix of the directory labels of this suite.
  private static let label = "FailedSessionSurfaceTests"

  /// The id of the project agent, whose file the load of the agent registry
  /// reads.
  private static let projectAgentID = "reader"

  /// A configuration with the shell on, and with no code context and no
  /// marketplace.
  ///
  /// - Returns: The configuration.
  private static func makeShellConfiguration() -> AgentConfiguration {
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.codeContext = .disabled
    return configuration
  }

  /// A surface whose agent environment fails after the build of the
  /// registry releases the shell store lease of the build.
  @Test func aFailedSurfaceReleasesTheShellStoreLeaseOfItsBuild() async throws {
    let sandbox = SandboxSwitch()
    let workingDirectory = makeResolvedDirectory(label: "\(Self.label)-shell")
    try AgentFolderFixture.writeProjectAgent(id: Self.projectAgentID, in: workingDirectory)
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: workingDirectory, configuration: Self.makeShellConfiguration(),
      mode: .open, sandboxProbe: sandbox.probe,
      agentConflictVersions: SandboxingConflictSource(sandbox: sandbox))
    let storeDirectory = context.settingsFolders.home.shellStoreDirectory(of: workingDirectory)
    let held = try await ShellStores.shared.acquire(directory: storeDirectory)

    await #expect(throws: ToolModeError.openModeInSandbox) {
      _ = try await ToolCatalog.sessionSurface(context: context)
    }
    await held.release()
    let next = try await ShellStores.shared.acquire(directory: storeDirectory)
    await next.release()

    #expect(next.store !== held.store)
  }
}

/// A conflict source of an agent registry that turns a sandbox switch on at
/// its first conflict-version read, and gives no conflict version and no
/// change.
private final class SandboxingConflictSource: AgentConflictVersionSource {
  /// The switch that the first read turns on.
  private let sandbox: SandboxSwitch

  /// Makes a source over `sandbox`.
  ///
  /// - Parameter sandbox: The switch that the first read turns on.
  init(sandbox: SandboxSwitch) {
    self.sandbox = sandbox
  }

  /// Turns the switch on, and gives no conflict version.
  ///
  /// - Parameter url: The URL of the agent file.
  /// - Returns: An empty list.
  func conflictVersions(of url: URL) -> [AgentConflictVersion] {
    sandbox.isSandboxed = true
    return []
  }

  /// Gives a stream that gives no value.
  ///
  /// - Parameter roots: The roots of the registry, which the source does not
  ///   follow.
  /// - Returns: A stream that ends at once.
  func changes(under roots: [URL]) -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}
