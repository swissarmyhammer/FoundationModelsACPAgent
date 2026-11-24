import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// A session composition that fails after the load of its agent registry
/// stops that registry (task ^22h3kvw).
///
/// A loaded registry follows the `changes(under:)` stream of its conflict
/// source until it stops to watch. A registry also stops to watch when it is
/// released. So each test gives the registry a
/// ``ProbingConflictVersionSource`` with a ``ReloadHold``: the hold keeps a
/// reload of the registry, and the reload keeps the registry, while the
/// composition fails. Thus only a stop of the registry ends its stream.
///
/// The waits use no clock. A registry that still watches keeps its stream,
/// and then the time limit ends the test.
@Suite struct FailedSessionCompositionTests {
  /// The prefix of the directory labels of this suite.
  private static let label = "FailedSessionCompositionTests"

  /// The id of the project agent, whose file each build of the registry
  /// reads.
  private static let projectAgentID = "reader"

  /// The value of the `agent` option that names no agent of the catalog.
  private static let unknownAgentID = "no-such-agent"

  /// A configuration with no tool group that starts a child process and no
  /// marketplace, thus a surface in the `open` mode starts no process.
  ///
  /// - Returns: The configuration.
  private static func makeChildlessConfiguration() -> AgentConfiguration {
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.shell = .disabled
    configuration.tools.codeContext = .disabled
    return configuration
  }

  /// Makes a working directory whose project layer holds one agent file.
  ///
  /// - Parameter name: The end of the directory label.
  /// - Returns: The working directory.
  /// - Throws: Whatever the write of the agent file throws.
  private static func makeWorkingDirectory(_ name: String) throws -> URL {
    let workingDirectory = makeResolvedDirectory(label: "\(label)-\(name)")
    try AgentFolderFixture.writeProjectAgent(id: projectAgentID, in: workingDirectory)
    return workingDirectory
  }

  /// Makes a stub agent in the `open` mode whose sessions read the agent
  /// conflict versions from `source`, with the sandbox probe of `sandbox`.
  ///
  /// - Parameters:
  ///   - source: The conflict source of the agent registry of each session.
  ///   - sandbox: The switch that the sandbox probe of the agent reads.
  /// - Returns: The agent.
  /// - Throws: Whatever the stub agent start throws.
  private static func makeAgent(
    source: ProbingConflictVersionSource, sandbox: SandboxSwitch
  ) async throws -> RoutedACPAgent {
    try await makeStubAgent(
      name: label, cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
      configuration: makeChildlessConfiguration(), mode: .open,
      sandboxProbe: sandbox.probe, agentConflictVersions: source)
  }

  /// Composes one session of `agent` over `workingDirectory`.
  ///
  /// - Parameters:
  ///   - agent: The agent of the session.
  ///   - workingDirectory: The working directory of the session.
  ///   - requestedAgent: The value of the `agent` option, or `nil` for none.
  /// - Throws: Whatever the settings load or the session composition throws.
  private static func composeSession(
    of agent: RoutedACPAgent, in workingDirectory: URL, requestedAgent: String? = nil
  ) async throws {
    let loaded = try await agent.loadSessionContext(workingDirectory: workingDirectory)
    let composition = try await agent.composeSession(
      from: loaded, workingDirectory: workingDirectory, additionalRoots: [], clientMCPServers: [],
      userPresence: .headless, requestedAgent: requestedAgent)
    await composition.surface.shutdown()
  }

  /// Runs a composition that fails, and counts the live change streams of
  /// `source` while `hold` keeps a reload of the registry.
  ///
  /// The composition runs in a task of its own: after the stop of the
  /// registry, the composition waits for the end of the kept reload. When
  /// the streams ended, the hold lets the reload continue, and the
  /// composition gives its error. On each exit, also when a wait throws,
  /// the helper releases the hold and cancels the task of the composition,
  /// so no thread stays in the hold.
  ///
  /// - Parameters:
  ///   - composition: The composition, which loads the registry over
  ///     `source` and then fails.
  ///   - expectedError: The error of the composition.
  ///   - source: The conflict source of the registry.
  ///   - hold: The hold of `source`.
  /// - Returns: The count of live streams at the end of the wait.
  /// - Throws: When a wait is cancelled.
  private static func liveStreamsAfterFailure<Failure: Error & Equatable>(
    of composition: @escaping @Sendable () async throws -> Void, expecting expectedError: Failure,
    source: ProbingConflictVersionSource, hold: ReloadHold
  ) async throws -> Int {
    let failed = Task { try await composition() }
    defer {
      hold.release()
      failed.cancel()
    }
    _ = try await hold.isHoldingReload.wait(for: "the kept reload") { $0 }
    let live = try await source.liveChangeStreams.wait(for: "the end of each stream") { $0 == 0 }
    hold.release()
    await #expect(throws: expectedError) { try await failed.value }
    return live
  }

  /// A session whose `agent` option names no agent fails after the load of
  /// the agent registry. The failure stops the registry.
  @Test
  func anUnknownSessionAgentStopsTheAgentRegistry() async throws {
    let hold = ReloadHold()
    let source = ProbingConflictVersionSource(reloadHold: hold)
    let agent = try await Self.makeAgent(source: source, sandbox: SandboxSwitch())
    let workingDirectory = try Self.makeWorkingDirectory("unknown-agent")

    let live = try await Self.liveStreamsAfterFailure(
      of: {
        try await Self.composeSession(
          of: agent, in: workingDirectory, requestedAgent: Self.unknownAgentID)
      },
      expecting: RequestError.invalidConfigOptionValue(id: ConfigOptions.agentOptionId),
      source: source, hold: hold)

    #expect(live == 0)
  }

  /// A session surface that fails after the load of the agent registry (the
  /// `open` mode in a sandboxed process) stops the registry.
  @Test
  func aFailedSessionSurfaceStopsTheAgentRegistry() async throws {
    let hold = ReloadHold()
    let source = ProbingConflictVersionSource(reloadHold: hold)
    let sandbox = SandboxSwitch()
    let agent = try await Self.makeAgent(source: source, sandbox: sandbox)
    let workingDirectory = try Self.makeWorkingDirectory("surface")
    sandbox.isSandboxed = true

    let live = try await Self.liveStreamsAfterFailure(
      of: { try await Self.composeSession(of: agent, in: workingDirectory) },
      expecting: ToolModeError.openModeInSandbox, source: source, hold: hold)

    #expect(live == 0)
  }

  /// A composition of the `agents` tool that loads its own registry, and
  /// whose agent environment then fails (the `open` mode in a sandboxed
  /// process), stops that registry.
  @Test
  func aFailedAgentEnvironmentStopsTheRegistryThatTheCompositionLoaded() async throws {
    let hold = ReloadHold()
    let source = ProbingConflictVersionSource(reloadHold: hold)
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: Self.makeWorkingDirectory("environment"),
      configuration: Self.makeChildlessConfiguration(), mode: .sandboxed,
      sandboxProbe: .fixed(true), agentConflictVersions: source)
    let skills = SkillsSource(
      registry: SkillsRegistry(roots: [], mode: .open), marketplaces: nil)

    let live = try await Self.liveStreamsAfterFailure(
      of: { _ = try await ToolCatalog.sessionSurface(context: context, skills: skills) },
      expecting: ToolModeError.openModeInSandbox, source: source, hold: hold)

    #expect(live == 0)
  }
}
