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

    /// The started marketplace store of the `tools.skills.marketplaces`
    /// list, or `nil` when the list is empty.
    public let marketplaces: MarketplaceStore?

    /// Makes a skills source.
    ///
    /// - Parameters:
    ///   - registry: The watched skills registry of the session.
    ///   - marketplaces: The started marketplace store, or `nil` when the
    ///     session has no marketplace.
    public init(registry: SkillsRegistry, marketplaces: MarketplaceStore?) {
        self.registry = registry
        self.marketplaces = marketplaces
    }
}
