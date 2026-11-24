import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Testing

@testable import FoundationModelsACPAgent

/// The source of the conflict versions of the agent registry of a session
/// comes from the agent, and not from a default in FoundationModelsAgents
/// (task ^j5dys15).
///
/// The default source, `FileVersionConflictSource`, adds one
/// `NSFileCoordinator` file presenter for each watched root. Each
/// coordinated read of the process then takes more time for each presenter.
/// A test agent gives a source that adds no presenter, so that the
/// coordinated reads of the full test run stay fast.
///
/// Each test gives a source that records each `changes(under:)` call, and
/// waits for the first call. The wait uses no clock.
@Suite(.closesHarnesses) struct AgentConflictVersionSourceTests {
  /// The agent registry of a catalog context follows the changes of the
  /// conflict source of that context.
  @Test
  func theAgentRegistryOfAContextFollowsTheSourceOfTheContext() async throws {
    let source = RecordingConflictVersionSource()
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeResolvedDirectory(label: "AgentConflictVersionSourceTests-context"),
      configuration: AgentConfiguration(), agentConflictVersions: source)
    let registry = AgentsComposition.makeAgentRegistry(context: context, marketplaces: nil)
    try await registry.load()

    let calls = try await source.followCalls.wait(for: "the follow of the roots") { $0 > 0 }
    await registry.stopWatching()

    #expect(calls > 0)
  }

  /// The agent registry of a session follows the changes of the conflict
  /// source that the agent got.
  @Test
  func theAgentRegistryOfASessionFollowsTheSourceOfTheAgent() async throws {
    let source = RecordingConflictVersionSource()
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "AgentConflictVersionSourceTests-cache"),
      agentConflictVersions: source)
    let harness = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
    _ = try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(
        cwd: makeResolvedDirectory(label: "AgentConflictVersionSourceTests-repo")))

    let calls = try await source.followCalls.wait(for: "the follow of the roots") { $0 > 0 }

    #expect(calls > 0)
  }
}

/// A conflict source that gives no conflict version, adds no file presenter,
/// and counts each `changes(under:)` call.
private struct RecordingConflictVersionSource: AgentConflictVersionSource {
  /// The number of `changes(under:)` calls, with its waits.
  let followCalls = WatchedValue(0)

  /// Gives no conflict version.
  ///
  /// - Parameter url: The URL of the agent file.
  /// - Returns: An empty list.
  func conflictVersions(of url: URL) -> [AgentConflictVersion] {
    []
  }

  /// Counts the call, and gives a stream that gives no value.
  ///
  /// - Parameter roots: The roots to follow.
  /// - Returns: A stream that ends only when the registry stops to iterate it.
  func changes(under roots: [URL]) -> AsyncStream<Void> {
    followCalls.update { $0 += 1 }
    return AsyncStream { _ in }
  }
}
