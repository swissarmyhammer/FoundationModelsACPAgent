import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Testing

@testable import FoundationModelsACPAgent

/// The load of an agent registry that a test makes leaves no watch behind
/// (task ^6yt2dpb).
@Suite struct AgentRegistryFixtureTests {
  /// ``AgentRegistryFixture/loadedCatalog(of:)`` stops the registry that it
  /// loads: the registry no longer follows the changes of its conflict
  /// source, also while the test keeps the registry.
  ///
  /// The wait uses no clock. A registry that still watches keeps its
  /// stream, and then the time limit ends the test.
  @Test(.timeLimit(.minutes(1)))
  func theLoadedCatalogOfARegistryStopsTheRegistry() async throws {
    let source = ProbingConflictVersionSource()
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeResolvedDirectory(label: "AgentRegistryFixtureTests-stop"),
      configuration: AgentConfiguration(), agentConflictVersions: source)
    let registry = AgentsComposition.makeAgentRegistry(context: context, marketplaces: nil)

    _ = try await AgentRegistryFixture.loadedCatalog(of: registry)
    let live = try await source.liveChangeStreams.wait(for: "the end of each stream") { $0 == 0 }
    // The registry lives until the wait ends, thus only a stop ends its stream.
    withExtendedLifetime(registry) {}

    #expect(live == 0)
  }
}
