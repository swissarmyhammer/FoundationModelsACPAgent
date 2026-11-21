import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The synchronous file reads of the session open path do not hold a thread
/// of the cooperative pool (task ^6yt2dpb).
///
/// A coordinated read (`NSFileCoordinator`) waits for each file presenter of
/// the item and for each sync engine that holds a claim. A wait of that kind
/// on a thread of the cooperative pool holds the thread, and with enough
/// open sessions the pool has no thread for the other tasks. Thus the read of
/// the `AGENT.md` of the working directory and the load of the agent
/// registry of a session run on the queue of ``BlockingFileReads``.
@Suite struct BlockingFileReadsTests {
  /// The prefix of the directory labels of this suite.
  private static let label = "BlockingFileReadsTests"

  /// The id of the agent that the registry load reads.
  private static let projectAgentID = "reader"

  /// The probe of the cooperative pool sees a thread of the pool. Without
  /// this proof, a probe that always says "no" would make each other test of
  /// the suite pass.
  @Test func theProbeSeesAThreadOfTheCooperativePool() async {
    let onPool = await Task.detached { CooperativePool.isCurrentThreadInPool }.value

    #expect(onPool)
  }

  /// The read of the `AGENT.md` of the working directory of a new session
  /// runs off the cooperative pool.
  @Test func theReadOfTheWorkingDirectoryAgentOfANewSessionRunsOffThePool() async throws {
    let probe = RootAgentReadProbe()

    _ = try await SessionAgentResolution.resolve(
      requested: nil, catalog: AgentRegistry(layers: []).catalog(),
      workingDirectory: makeResolvedDirectory(label: "\(Self.label)-new"), layerRoots: [],
      readRootAgent: { probe.read(in: $0, id: $1) })

    #expect(probe.readsOnCooperativePool == [false])
  }

  /// The read of the `AGENT.md` of the working directory of a resumed
  /// session runs off the cooperative pool. The folder has no `AGENT.md`,
  /// thus the restore reads it two times: one time for the recorded agent,
  /// and one time for the agent of a new session.
  @Test func theReadOfTheWorkingDirectoryAgentOfAResumedSessionRunsOffThePool() async {
    let probe = RootAgentReadProbe()
    let choice = SessionAgentChoice(id: Self.projectAgentID, source: .workingDirectory)

    _ = await SessionAgentResolution.restore(
      choice, catalog: AgentRegistry(layers: []).catalog(),
      workingDirectory: makeResolvedDirectory(label: "\(Self.label)-resume"), layerRoots: [],
      readRootAgent: { probe.read(in: $0, id: $1) })

    #expect(probe.readsOnCooperativePool == [false, false])
  }

  /// The load of the agent registry of a session reads the agent files off
  /// the cooperative pool.
  @Test func theLoadOfTheAgentRegistryOfASessionReadsOffThePool() async throws {
    let source = ProbingConflictVersionSource()
    let cwd = makeResolvedDirectory(label: "\(Self.label)-load")
    try AgentFolderFixture.writeProjectAgent(id: Self.projectAgentID, in: cwd)
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: cwd, configuration: AgentConfiguration(), agentConflictVersions: source)

    let registry = try await AgentsComposition.loadedAgentRegistry(
      context: context, marketplaces: nil)
    await registry.stopWatching()

    #expect(source.readsOnCooperativePool == [false])
  }
}

/// A reader of the root `AGENT.md` of a folder that records, for each read,
/// whether it ran on a thread of the cooperative pool, and then reads as the
/// session does.
private final class RootAgentReadProbe: Sendable {
  /// For each read, in order, whether it ran on a thread of the pool.
  private let reads = Mutex<[Bool]>([])

  /// For each read so far, in order, whether it ran on a thread of the pool.
  var readsOnCooperativePool: [Bool] {
    reads.withLock { $0 }
  }

  /// Records the thread of the read, and reads the root `AGENT.md` of
  /// `folder`.
  ///
  /// - Parameters:
  ///   - folder: The folder of the read.
  ///   - id: The id of the agent.
  /// - Returns: The load of the read.
  func read(in folder: URL, id: String) -> RootAgentLoad {
    let onPool = CooperativePool.isCurrentThreadInPool
    reads.withLock { $0.append(onPool) }
    return AgentRegistry.rootAgent(in: folder, id: id)
  }
}
