import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The scheduled agents of a session are saved in its recording folder
/// (`<recording root>/<session>/schedules.json`), so a restart or a resume of
/// the session restores them. FoundationModelsAgents gives only the store
/// protocol (`AgentScheduleStore`); this host writes the file.
@Suite struct ScheduledAgentStoreTests {
  /// A request of a scheduled agent that fires every hour.
  private static func hourly(owner: ULID) -> AgentScheduleRequest {
    AgentScheduleRequest(prompt: "Report the state.", spec: .interval(seconds: 3600), owner: owner)
  }

  /// A context whose agent runs record under `root`, as a session of the agent has.
  private static func context(label: String, root: URL) async throws -> CatalogContext {
    let base = try await AgentsToolTests.makeContext(label: label)
    let host = AgentRunHost(
      recordingRoot: root,
      sessionEnding: { _, _ in },
      callerMail: { _, _, _ in nil },
      claimCompletion: { _, _, _, _ in false })
    return CatalogContext(
      workingDirectory: base.workingDirectory, configuration: base.configuration,
      profile: base.profile, settingsFolders: base.settingsFolders,
      environment: base.environment, agentRunHost: host)
  }

  /// The store saves the tasks of a session, loads them back, and removes
  /// the file when the list is empty.
  @Test func theStoreSavesLoadsAndRemovesTheTasksOfASession() async throws {
    let root = makeResolvedDirectory(label: "ScheduledAgentStoreTests-store")
    let surface = try await SurfaceCatalog.sessionSurface(
      context: try await AgentsToolTests.makeContext(label: "schedule-store"))
    let owner = ULID()
    let task = try await #require(surface.agents).runner.schedule(Self.hourly(owner: owner))
    let store = ScheduleFileStore(recordingRoot: root)

    try await store.save([task], of: owner)
    let loaded = try await store.load(of: owner)
    try await store.save([], of: owner)
    let afterRemove = try await store.load(of: owner)

    #expect(loaded == [task])
    #expect(afterRemove.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: ScheduleFileStore.file(of: owner, in: root).path))
    await surface.shutdown()
  }

  /// A session whose agent runs record under a root saves each scheduled
  /// agent there, and a later surface over the same root restores it.
  @Test func aSurfaceSavesItsScheduledAgentsAndALaterSurfaceRestoresThem() async throws {
    let root = makeResolvedDirectory(label: "ScheduledAgentStoreTests-wiring")
    let owner = ULID()
    let first = try await SurfaceCatalog.sessionSurface(
      context: try await Self.context(label: "schedule-first", root: root))
    let task = try await #require(first.agents).runner.schedule(Self.hourly(owner: owner))
    await first.stopAgentRuns()

    let second = try await SurfaceCatalog.sessionSurface(
      context: try await Self.context(label: "schedule-second", root: root))
    let restored = try await #require(second.agents).runner.restoreSchedules(of: owner)

    #expect(FileManager.default.fileExists(atPath: ScheduleFileStore.file(of: owner, in: root).path))
    #expect(restored.map(\.id) == [task.id])
    await first.shutdown()
    await second.shutdown()
  }
}
