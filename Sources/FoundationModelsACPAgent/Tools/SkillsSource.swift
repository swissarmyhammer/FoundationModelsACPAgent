import FoundationModelsSkills

/// The skills registry of one session, and the marketplace store under it.
///
/// One session has one skills registry and one marketplace store. The
/// `skills` tool, the slash-command source, the instructions preload, the
/// agent environment and the agent registry all read these same instances,
/// thus a skill or an agent of a marketplace comes from one fetch.
public struct SkillsSource: Sendable {
  /// The watched skills registry of the session.
  public let registry: SkillsRegistry

  /// The marketplace layers of the session
  /// (``ToolCatalog/startSkillsMarketplaces(context:)``), or `nil` when the
  /// list is empty and the session follows no marketplace registry.
  public let marketplaces: SessionMarketplaces?

  /// Makes a skills source.
  ///
  /// - Parameters:
  ///   - registry: The watched skills registry of the session.
  ///   - marketplaces: The marketplace layers of the session, or `nil`
  ///     when the session has no marketplace.
  public init(registry: SkillsRegistry, marketplaces: SessionMarketplaces?) {
    self.registry = registry
    self.marketplaces = marketplaces
  }
}
