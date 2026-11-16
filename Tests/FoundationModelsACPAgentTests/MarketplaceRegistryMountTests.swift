import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsSkills
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The mount of the marketplace registry of Extras (D190): the storage port
/// over `tools.skills.marketplaces` at the USER level, the one registry of
/// the agent, and the marketplace layers of a session, which follow each
/// change of the registry.
@Suite(.closesHarnesses) struct MarketplaceRegistryMountTests {
  /// A source with each optional field.
  static let full = MarketplaceSource(
    "https://example.com/a.git", ref: "dev", path: "sub", alias: "a",
    select: .skills(["one", "two"]), autoUpdate: false)

  /// A source with no optional field.
  static let plain = MarketplaceSource("https://example.com/b.git")

  // MARK: - The storage port

  /// A save writes `tools.skills.marketplaces` at the USER level, and a load
  /// gives the same sources back, in order.
  @Test func aSaveAndALoadGiveTheSameSources() async throws {
    let fixture = try SettingsGraphFixture(label: "marketplace-storage")
    let storage = SettingsMarketplaceSourceStorage(store: fixture.store)

    try await storage.saveSources([Self.full, Self.plain])
    let loaded = try await storage.loadSources()

    #expect(loaded == [Self.full, Self.plain])
    let text = try String(
      contentsOf: ConfigCommandFixture.configURL(in: try fixture.userRoot), encoding: .utf8)
    #expect(text.contains("https://example.com/a.git"))
    #expect(text.contains("autoUpdate: false"))
  }

  /// With no list in the settings, the storage gives the default list: the
  /// list that a session reads.
  @Test func noListGivesTheDefaultList() async throws {
    let fixture = try SettingsGraphFixture(label: "marketplace-storage-default")
    let storage = SettingsMarketplaceSourceStorage(store: fixture.store)

    #expect(try await storage.loadSources() == SkillsToolOptions.defaultMarketplaces)
  }

  // MARK: - The agent

  /// The registry of the agent writes the user settings, and the merged
  /// configuration has the new list.
  @Test func theRegistryOfTheAgentWritesTheSettings() async throws {
    let composed = try await composeStubAgent(
      name: "MarketplaceRegistryMountTests", label: "MarketplaceRegistryMountTests-agent")

    try await composed.agent.marketplaceRegistry.add(Self.plain)
    let cwd = makeResolvedDirectory(label: "MarketplaceRegistryMountTests-agent-cwd")
    let merged = try await composed.agent.settingsStore.merged(for: cwd).configuration
    await composed.closeOpenSessions()

    #expect(merged.tools.skills.marketplaces.contains(Self.plain))
  }

  /// The `skills` tool of a session has the marketplace operations of the
  /// registry of the agent (D190), thus the model and the `skills`
  /// endpoint change the list of the agent.
  @Test func theSkillsToolOfASessionHasTheMarketplaceOperations() async throws {
    let composed = try await composeStubAgent(
      name: "MarketplaceRegistryMountTests", label: "MarketplaceRegistryMountTests-tool")
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let folder = makeResolvedDirectory(label: "MarketplaceRegistryMountTests-tool-cwd")
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId

    let surface = await composed.agent.sessions[id]?.surface
    let skills = surface?.tools.first { $0.name == SkillOutputProtection.skillsToolName } as? SkillsCatalogTool
    await composed.closeOpenSessions()

    let nouns = Set((skills?.operations ?? []).map { $0.noun })
    #expect(nouns.contains("marketplace"))
  }

  // MARK: - The layers of a session

  /// A store of a test: it records its sources, its start and its stop,
  /// and it gives no layer.
  final class RecordingStore: SessionMarketplaceStore, Sendable {
    /// The sources of the store.
    let sources: [MarketplaceSource]

    /// The events of the store, in order: `start` and `stop`.
    let events = Mutex<[String]>([])

    init(sources: [MarketplaceSource]) {
      self.sources = sources
    }

    func marketplaceLayers() -> [MarketplaceLayer] { [] }

    var layerUpdates: AsyncStream<Void> { AsyncStream { _ in } }

    func start() async { events.withLock { $0.append("start") } }

    func stop() async { events.withLock { $0.append("stop") } }
  }

  /// The stores that a provider made, in order.
  final class MadeStores: Sendable {
    /// The stores.
    let stores = Mutex<[RecordingStore]>([])

    /// Records a new store of `sources`, and gives it.
    func make(_ sources: [MarketplaceSource]) -> RecordingStore {
      let store = RecordingStore(sources: sources)
      stores.withLock { $0.append(store) }
      return store
    }

    /// The stores made, in order.
    var all: [RecordingStore] { stores.withLock { $0 } }
  }

  /// The layers of a session over recording stores, and each store made.
  private static func recordingLayers() -> (SessionMarketplaces, MadeStores) {
    let made = MadeStores()
    return (SessionMarketplaces { made.make($0) }, made)
  }

  /// A replace starts a new store and stops the old one, and the layers
  /// tell their consumer to read again.
  @Test func aReplaceSwapsTheStoreAndTellsTheConsumer() async throws {
    let (layers, made) = Self.recordingLayers()
    var updates = layers.layerUpdates.makeAsyncIterator()

    await layers.replace(with: [Self.plain])
    await layers.replace(with: [Self.full])
    _ = await updates.next()

    let stores = made.all
    #expect(stores.map(\.sources) == [[Self.plain], [Self.full]])
    #expect(stores[0].events.withLock { $0 } == ["start", "stop"])
    #expect(stores[1].events.withLock { $0 } == ["start"])
    await layers.stop()
    #expect(stores[1].events.withLock { $0 } == ["start", "stop"])
  }

  /// An empty list makes no store.
  @Test func anEmptyListMakesNoStore() async throws {
    let (layers, made) = Self.recordingLayers()

    await layers.replace(with: [])

    #expect(made.all.isEmpty)
    #expect(layers.marketplaceLayers().isEmpty)
    await layers.stop()
  }

  /// Each change of the registry makes a new store from the list that the
  /// source closure gives.
  @Test func aChangeOfTheRegistryMakesANewStore() async throws {
    let storage = InMemoryMarketplaceSourceStorage()
    let registry = MarketplaceRegistry(storage: storage)
    let (layers, made) = Self.recordingLayers()
    var updates = layers.layerUpdates.makeAsyncIterator()
    layers.follow(registry.changes()) { try await storage.loadSources() }

    try await registry.add(Self.plain)
    _ = await updates.next()

    #expect(made.all.map(\.sources) == [[Self.plain]])
    await layers.stop()
  }

  /// A session whose list is empty gets the skill of a marketplace that the
  /// registry adds after the session started.
  @Test func aMarketplaceThatTheRegistryAddsReachesARunningSession() async throws {
    let repository = try SkillsMarketplaceTests.makeMarketplaceRepository()
    let cache = makeResolvedDirectory(label: "MarketplaceRegistryMountTests-cache")
    let environment = SkillsMarketplaceTests.environment(cache: cache)
    let storage = InMemoryMarketplaceSourceStorage()
    let registry = MarketplaceRegistry(storage: storage)
    var configuration = AgentConfiguration()
    configuration.tools.codeContext = .disabled
    configuration.tools.skills = SkillsToolOptions(marketplaces: [])
    let context = CatalogContext(
      workingDirectory: makeResolvedDirectory(label: "MarketplaceRegistryMountTests-work"),
      configuration: configuration,
      profile: try await makeStubProfile(
        cacheDirectory: makeResolvedDirectory(label: "MarketplaceRegistryMountTests-models")),
      settingsFolders: SettingsFolders(
        name: try DotfolderName(SkillsMarketplaceTests.dotfolderName),
        home: .makeXDG(
          name: try DotfolderName(SkillsMarketplaceTests.dotfolderName), environment: environment),
        environment: [:]),
      mode: .open, environment: environment,
      marketplaceMount: MarketplaceMount(registry: registry) { try await storage.loadSources() })

    let skills = await ToolCatalog.makeSkillsSource(context: context)
    #expect(!skills.registry.metadata().map(\.id).contains(SkillsMarketplaceTests.skillName))
    try await registry.add(
      MarketplaceSource(
        SkillsMarketplaceTests.fileURLPrefix + repository.path,
        ref: SkillsMarketplaceTests.marketplaceBranch))

    var found = false
    for _ in 0..<200 where !found {
      found = skills.registry.metadata().map(\.id).contains(SkillsMarketplaceTests.skillName)
      if !found { try await Task.sleep(for: .milliseconds(50)) }
    }
    await skills.marketplaces?.stop()
    await skills.registry.stopWatching()
    #expect(found)
  }
}
