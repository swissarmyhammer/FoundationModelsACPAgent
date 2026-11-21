import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsMultitool
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsSkills

/// ``StartedSessionParts/stop()`` stops each part that a session composition
/// started (task ^2zm9hbk). A composition that fails before its surface owns
/// the parts calls it, and so does ``SessionSurface/shutdown()``.
///
/// Each test keeps its part until the end, so only the stop ends the work of
/// the part, not a release.
@Suite struct StartedSessionPartsTests {
  /// The prefix of the directory labels of this suite.
  private static let label = "StartedSessionPartsTests"

  /// The id of the project agent of the agent tests.
  private static let projectAgentID = "reader"

  /// The marketplace source of the marketplace test. The recording store
  /// reads nothing from it.
  private static let marketplaceSource = MarketplaceSource("file:///nonexistent/marketplace")

  /// The stop ends the change stream of the agent registry.
  @Test(.timeLimit(.minutes(1)))
  func theStopStopsTheAgentRegistry() async throws {
    let source = ProbingConflictVersionSource()
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeResolvedDirectory(label: "\(Self.label)-agents"),
      configuration: AgentConfiguration(), agentConflictVersions: source)
    let registry = try await AgentsComposition.loadedAgentRegistry(
      context: context, marketplaces: nil)

    await StartedSessionParts(agentRegistry: registry).stop()
    let live = try await source.liveChangeStreams.wait(for: "the end of each stream") { $0 == 0 }
    withExtendedLifetime(registry) {}

    #expect(live == 0)
  }

  /// The stop stops the watch of the skills registry.
  @Test func theStopStopsTheSkillsRegistry() async throws {
    let registry = SkillsRegistry(
      roots: [makeResolvedDirectory(label: "\(Self.label)-skills")], mode: .sandboxed,
      watch: true)
    try #require(registry.isFollowingChanges)

    await StartedSessionParts(skillsRegistry: registry).stop()

    #expect(!registry.isFollowingChanges)
  }

  /// The stop stops the marketplace layers, and with them their store.
  @Test func theStopStopsTheMarketplaces() async {
    let store = MarketplaceRegistryMountTests.RecordingStore(sources: [Self.marketplaceSource])
    let marketplaces = SessionMarketplaces { _ in store }
    await marketplaces.replace(with: [Self.marketplaceSource])

    await StartedSessionParts(marketplaces: marketplaces).stop()

    #expect(store.events.withLock { $0 } == ["start", "stop"])
  }

  /// The stop releases the shell store lease.
  @Test func theStopReleasesTheShellStoreLease() async throws {
    let released = Mutex(false)
    let lease = ShellStoreLease(
      store: try ShellStore(storeDirectory: makeResolvedDirectory(label: "\(Self.label)-shell"))
    ) { released.withLock { $0 = true } }

    await StartedSessionParts(shellStoreLease: lease).stop()

    #expect(released.withLock { $0 })
  }

  /// The stop shuts down the MCP server pool.
  @Test func theStopShutsDownTheServerPool() async {
    let pool = MCPServerPool()
    let attachment = RecordingStoppable()
    await pool.attach(attachment: attachment)

    await StartedSessionParts(serverPool: pool).stop()

    #expect(attachment.isStopped)
  }

  /// The stop stops the agent runs of the mount: the runner starts no run.
  @Test func theStopStopsTheAgentRuns() async throws {
    let workingDirectory = makeResolvedDirectory(label: "\(Self.label)-runs")
    try AgentFolderFixture.writeProjectAgent(id: Self.projectAgentID, in: workingDirectory)
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.shell = .disabled
    configuration.tools.codeContext = .disabled
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: workingDirectory, configuration: configuration, mode: .sandboxed)
    let surface = try await ToolCatalog.sessionSurface(context: context)
    let mount = try #require(surface.agents)

    await StartedSessionParts(agentRuns: mount).stop()
    var refusal: AgentRunnerError?
    do {
      _ = try await mount.runner.start(Self.projectAgentID, prompt: "Read.")
    } catch {
      refusal = error
    }
    await surface.shutdown()

    #expect(refusal == .stopped)
  }
}

/// An attachment of an MCP server pool that records its stop.
private final class RecordingStoppable: Stoppable {
  /// Whether the pool stopped the attachment.
  private let stopped = Mutex(false)

  /// Makes an attachment that did not stop.
  init() {}

  /// Whether the pool stopped the attachment.
  var isStopped: Bool {
    stopped.withLock { $0 }
  }

  /// Records the stop.
  func stop() async {
    stopped.withLock { $0 = true }
  }
}
