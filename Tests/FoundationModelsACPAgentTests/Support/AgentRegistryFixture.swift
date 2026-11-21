import FoundationModelsAgents

/// The load of an agent registry that a test makes (task ^6yt2dpb).
///
/// A registry with `watch: true` keeps a `DotfolderWatcher` and its file
/// descriptors, and follows the changes of its conflict source, until it
/// stops to watch. A test that only reads the catalog thus stops the
/// registry before it reads on.
enum AgentRegistryFixture {
  /// Loads `registry`, takes its catalog, and stops the watch of the
  /// registry, also when the load throws.
  ///
  /// - Parameter registry: The registry, which did not load yet.
  /// - Returns: The catalog of the load.
  /// - Throws: What the load throws.
  static func loadedCatalog(of registry: AgentRegistry) async throws -> AgentCatalog {
    do {
      try await registry.load()
    } catch {
      await registry.stopWatching()
      throw error
    }
    await registry.stopWatching()
    return registry.catalog()
  }
}
