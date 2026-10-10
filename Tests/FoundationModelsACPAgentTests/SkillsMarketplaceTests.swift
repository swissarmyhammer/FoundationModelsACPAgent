import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The tool catalog of this package. FoundationModelsAgents also has a type
/// named `ToolCatalog`, thus this suite names the type of this package
/// through this alias.
private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The skills marketplaces of a session (task ^t87yzmg).
///
/// The default configuration reads the `main` branch of
/// `swissarmyhammer/skills` over HTTPS. A unit test must not use the
/// network, thus:
///
/// - the stub agent of each suite gets `marketplaces: []` from its defaults
///   layer, and a session of it makes no marketplace store;
/// - the marketplace proof uses a local git repository on its `main` branch,
///   through a `file://` URL, and a cache folder of the test.
@Suite struct SkillsMarketplaceTests {
    // MARK: - Constants

    /// The branch of the local marketplace repository: the branch of the
    /// default marketplace.
    static let marketplaceBranch = SkillsToolOptions.defaultMarketplaceRef

    /// The folder name of the local marketplace repository. A `file://` URL
    /// that ends in `.git` names a git repository, which the store fetches
    /// as it fetches a remote one.
    static let repositoryFolderName = "skills.git"

    /// The name of the skill of the local marketplace.
    static let skillName = "marketplace-skill"

    /// The name of the agent of the local marketplace.
    static let agentName = "marketplace-agent"

    /// The path of the skill document in the local marketplace.
    static let skillDocumentPath = "skills/\(skillName)/SKILL.md"

    /// The path of the agent document in the local marketplace: the layout
    /// `agents/<name>/AGENT.md`.
    static let agentDocumentPath = "agents/\(agentName)/AGENT.md"

    /// The name of the `agents` tool.
    static let agentsToolName = "agents"

    /// The scheme prefix of a marketplace URL that names a folder of this
    /// computer.
    static let fileURLPrefix = "file://"

    // MARK: - Fixtures

    /// The document of one skill or one agent: a frontmatter with a name and
    /// a description, and a body.
    ///
    /// - Parameter name: The name of the skill or of the agent.
    /// - Returns: The document text.
    static func document(named name: String) -> String {
        "---\nname: \(name)\ndescription: The \(name) of the test marketplace.\n---\n\nDo the task.\n"
    }

    /// Makes a local git repository on ``marketplaceBranch`` that holds one
    /// skill and one agent.
    ///
    /// - Returns: The work tree of the repository.
    /// - Throws: Whatever the folder creation, the file write or a git
    ///   command throws.
    static func makeMarketplaceRepository() throws -> URL {
        let repository = makeResolvedDirectory(label: "SkillsMarketplaceTests-repo")
            .appendingPathComponent(repositoryFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try GitVerbSupport.makeRepository(in: repository, branch: marketplaceBranch)
        try GitVerbSupport.commitFile(
            named: skillDocumentPath, text: document(named: skillName), message: "add the skill",
            in: repository)
        try GitVerbSupport.commitFile(
            named: agentDocumentPath, text: document(named: agentName), message: "add the agent",
            in: repository)
        return repository
    }

    /// Makes a catalog context whose one marketplace is `repository` on
    /// ``marketplaceBranch``, and whose environment names `cache` as the
    /// marketplace cache.
    ///
    /// - Parameters:
    ///   - repository: The work tree of the local marketplace repository.
    ///   - cache: The marketplace cache folder of the test.
    /// - Returns: The context.
    /// - Throws: Whatever the profile resolve throws.
    static func makeContext(repository: URL, cache: URL) async throws -> CatalogContext {
        var configuration = AgentConfiguration()
        configuration.tools.codeContext = .disabled
        configuration.tools.skills = .enabled(
            SkillsToolOptions(marketplaces: [
                MarketplaceSource(fileURLPrefix + repository.path, ref: marketplaceBranch)
            ]))
        return CatalogContext(
            workingDirectory: makeResolvedDirectory(label: "SkillsMarketplaceTests-work"),
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "SkillsMarketplaceTests-models")),
            environment: [MarketplaceStore.cacheDirectoryVariable: cache.path])
    }

    // MARK: - No network in the unit tests

    /// A session of the stub agent reads no marketplace: the defaults layer
    /// of the stub agent sets `marketplaces: []` over the default list, thus
    /// the session start makes no marketplace store and needs no network.
    @Test(.timeLimit(.minutes(1)))
    func aSessionOfTheStubAgentReadsNoMarketplace() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "SkillsMarketplaceTests-stub")
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])

        #expect(entry.configuration.tools.skills == .enabled(SkillsToolOptions(marketplaces: [])))
        await fixture.close()
    }

    // MARK: - The marketplace on main

    /// A marketplace on the `main` branch of a local git repository gives
    /// its skill to the skills registry and its agent to the `agents` tool,
    /// through the one store of the session. The store writes its cache into
    /// the folder that the environment of the context names.
    @Test(.timeLimit(.minutes(1)))
    func aMarketplaceOnMainGivesItsSkillAndItsAgentToTheSession() async throws {
        let repository = try Self.makeMarketplaceRepository()
        let cache = makeResolvedDirectory(label: "SkillsMarketplaceTests-cache")
        let context = try await Self.makeContext(repository: repository, cache: cache)

        let skills = try #require(await SurfaceCatalog.makeSkillsSource(context: context))
        let surface = try await SurfaceCatalog.sessionSurface(context: context, skills: skills)

        let agents = try #require(surface.tools.first { $0.name == Self.agentsToolName } as? AgentsTool)
        #expect(skills.marketplaces != nil)
        #expect(skills.registry.metadata().map(\.id).contains(Self.skillName))
        #expect(agents.agentNames.contains(Self.agentName))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: cache.path)).isEmpty)
        await surface.shutdown()
    }
}
