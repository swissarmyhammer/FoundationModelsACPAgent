import FoundationModelsACPAgent

extension AgentConfiguration {
    /// The in-code defaults with an empty `tools.skills.marketplaces` list.
    ///
    /// The default list names the `swissarmyhammer/skills` repository on
    /// GitHub, and the tool catalog fetches each marketplace when it makes
    /// the skills source of a session. A unit test must not use the network,
    /// thus a suite that makes a `CatalogContext` itself starts from this
    /// value. ``StubAgentDefaultsLayer`` gives the same empty list to each
    /// stub agent.
    public static var withoutMarketplaces: AgentConfiguration {
        var configuration = AgentConfiguration()
        configuration.tools.skills = SkillsToolOptions(marketplaces: [])
        return configuration
    }
}
