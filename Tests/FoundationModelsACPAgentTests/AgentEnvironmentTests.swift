import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The tool catalog of this package. FoundationModelsAgents also has a type
/// named `ToolCatalog`, thus this suite names the type of this package
/// through this alias.
private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The host environment of the agent reaches the session tools (task
/// ^b2kb6j1).
///
/// A host gives the agent an environment (`RoutedACPAgent.init(environment:)`,
/// `ComposedAgent.compose(environment:)`). Each session composition gives
/// that environment to its `CatalogContext`, and each session tool that
/// reads an environment value reads it from there, not from the process.
///
/// Each test gives the agent one value that the process does not have, and
/// reads the tool that reads that value: in the first session, and in the
/// session after a model-slot switch. The slot switch composes no new
/// surface: the replacement session gets the tools of the first composition.
/// No test uses a clock or the network. The marketplace is a local git
/// repository, as in `SkillsMarketplaceTests`.
///
/// The web capability reads its API keys from the same
/// `CatalogContext.environment`. Multitool keeps the configuration of a
/// mounted web capability private, thus no test reads the providers of a
/// mounted web tool without a request. `WebToolTests` proves the providers
/// that an environment gives.
@Suite struct AgentEnvironmentTests {
    // MARK: - Constants

    /// The environment key of the defaults layer of the `skills` dotfolder
    /// stack: `<NAME>_DEFAULTS_DIR` of `DotfolderStack`.
    static let skillsDefaultsKey =
        SurfaceCatalog.skillsDotfolderName.uppercased() + StubAgentDefaultsLayer.environmentKeySuffix

    /// The environment key of the defaults layer of the `agents` dotfolder
    /// stack: `<NAME>_DEFAULTS_DIR` of `DotfolderStack`.
    static let agentsDefaultsKey =
        SurfaceCatalog.agentsDotfolderName.uppercased() + StubAgentDefaultsLayer.environmentKeySuffix

    /// The name of the skill in the defaults layer that the host environment
    /// names.
    static let hostSkillName = "host-environment-skill"

    /// The name of the agent in the defaults layer that the host environment
    /// names.
    static let hostAgentName = "host-environment-agent"

    /// The folder of a layer root of the `agents` stack that holds the agent
    /// folders.
    static let agentsFolderName = "agents"

    /// The document of an agent folder.
    static let agentDocumentName = "AGENT.md"

    /// The document of a skill folder.
    static let skillDocumentName = "SKILL.md"

    // MARK: - Fixtures

    /// One session of an agent, as the session table holds it before and
    /// after a model-slot switch to `flash`.
    struct SwitchedSession {
        /// The table entry after `session/new`.
        let first: ActiveSession

        /// The table entry after `session/set_config_option` selected the
        /// `flash` slot.
        let switched: ActiveSession
    }

    /// Makes a stub agent over `environment`, opens one session in a new
    /// working directory, and switches the session to the `flash` slot.
    ///
    /// The test requires that the process environment does not hold the
    /// value of each key of `environment`, so a pass proves that the value
    /// came from the host environment.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - environment: The host environment of the agent.
    ///   - prepare: Writes the project files of the working directory
    ///     before `session/new`.
    /// - Returns: The table entry before and after the switch.
    /// - Throws: Whatever the construction, the session requests or
    ///   `prepare` throws.
    static func openAndSwitchSession(
        label: String,
        environment: [String: String],
        prepare: (URL) throws -> Void = { _ in }
    ) async throws -> SwitchedSession {
        for (key, value) in environment {
            try #require(ProcessInfo.processInfo.environment[key] != value)
        }
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "AgentEnvironmentTests-\(label)-models"),
            recordingsDirectory: makeResolvedDirectory(label: "AgentEnvironmentTests-\(label)-recordings"),
            userDirectory: makeResolvedDirectory(label: "AgentEnvironmentTests-\(label)-user"),
            environment: environment)
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        let cwd = makeResolvedDirectory(label: "AgentEnvironmentTests-\(label)-repo")
        try prepare(cwd)
        let response = try await agent.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))
        let first = try #require(await agent.sessions[response.sessionId])
        _ = try await agent.setSessionConfigOption(
            SetSessionConfigOptionRequest(
                configId: ConfigOptions.modelOptionId, sessionId: response.sessionId,
                value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))
        let switched = try #require(await agent.sessions[response.sessionId])
        try #require(switched.selectedSlot == .flash)
        return SwitchedSession(first: first, switched: switched)
    }

    /// The ids of the skills that the skills registry of a session surface
    /// holds: the registry of the `skills` tool and of the agent runs.
    ///
    /// - Parameter entry: The table entry of the session.
    /// - Returns: The skill ids, or an empty list when the surface mounts no
    ///   `agents` tool.
    static func skillIDs(of entry: ActiveSession) -> [String] {
        entry.surface.agents?.environment.skills.metadata().map(\.id) ?? []
    }

    /// Whether the `agents` tool of a session surface can start the agent
    /// `name`: the agent list of the tool description names each startable
    /// agent as `- name` or `- name: description`.
    ///
    /// - Parameters:
    ///   - entry: The table entry of the session.
    ///   - name: The name of the agent.
    /// - Returns: `true` when the description lists the agent, `false` when
    ///   it does not or the surface mounts no `agents` tool.
    static func lists(_ entry: ActiveSession, agent name: String) -> Bool {
        entry.surface.agents?.tool.description.contains("- \(name)") ?? false
    }

    /// Writes `yaml` as the project layer configuration of the session
    /// working directory: `<cwd>/.<dotfolder>/config.yaml`.
    ///
    /// - Parameters:
    ///   - yaml: The configuration text.
    ///   - cwd: The session working directory.
    /// - Throws: The directory-creation or write error.
    static func writeProjectConfiguration(_ yaml: String, in cwd: URL) throws {
        try ConfigFileFixture.write(
            yaml,
            in: cwd.appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true))
    }

    // MARK: - The marketplace cache

    /// The skills marketplace store of each session writes its cache into
    /// the folder that `SKILLS_MARKETPLACE_CACHE` of the host environment
    /// names, and the marketplace skill reaches the skills registry. The
    /// session after the slot switch keeps that registry.
    @Test
    func theMarketplaceStoreOfEachSessionUsesTheCacheFolderOfTheHostEnvironment() async throws {
        let repository = try SkillsMarketplaceTests.makeMarketplaceRepository()
        let cache = makeResolvedDirectory(label: "AgentEnvironmentTests-marketplace-cache")

        let session = try await Self.openAndSwitchSession(
            label: "marketplace",
            environment: [MarketplaceStore.cacheDirectoryVariable: cache.path]
        ) { cwd in
            try Self.writeProjectConfiguration(
                """
                tools:
                  skills:
                    marketplaces:
                      - url: \(SkillsMarketplaceTests.fileURLPrefix + repository.path)
                        ref: \(SkillsMarketplaceTests.marketplaceBranch)
                """,
                in: cwd)
        }

        #expect(!(try FileManager.default.contentsOfDirectory(atPath: cache.path)).isEmpty)
        #expect(Self.skillIDs(of: session.first).contains(SkillsMarketplaceTests.skillName))
        #expect(Self.skillIDs(of: session.switched).contains(SkillsMarketplaceTests.skillName))
    }

    // MARK: - The dotfolder stacks of the session tools

    /// The `skills` dotfolder stack of each session reads its defaults layer
    /// from the folder that `SKILLS_DEFAULTS_DIR` of the host environment
    /// names. The session after the slot switch keeps that registry.
    @Test
    func theSkillsStackOfEachSessionReadsTheDefaultsLayerOfTheHostEnvironment() async throws {
        let defaults = makeResolvedDirectory(label: "AgentEnvironmentTests-skills-defaults")
        let skillFolder = defaults.appendingPathComponent(Self.hostSkillName, isDirectory: true)
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        try SkillsMarketplaceTests.document(named: Self.hostSkillName).write(
            to: skillFolder.appendingPathComponent(Self.skillDocumentName, isDirectory: false),
            atomically: true, encoding: .utf8)

        let session = try await Self.openAndSwitchSession(
            label: "skills", environment: [Self.skillsDefaultsKey: defaults.path])

        #expect(Self.skillIDs(of: session.first).contains(Self.hostSkillName))
        #expect(Self.skillIDs(of: session.switched).contains(Self.hostSkillName))
    }

    /// The `agents` dotfolder stack of each session reads its defaults layer
    /// from the folder that `AGENTS_DEFAULTS_DIR` of the host environment
    /// names. The session after the slot switch keeps that `agents` tool.
    @Test
    func theAgentsStackOfEachSessionReadsTheDefaultsLayerOfTheHostEnvironment() async throws {
        let defaults = makeResolvedDirectory(label: "AgentEnvironmentTests-agents-defaults")
        let agentFolder = defaults
            .appendingPathComponent(Self.agentsFolderName, isDirectory: true)
            .appendingPathComponent(Self.hostAgentName, isDirectory: true)
        try FileManager.default.createDirectory(at: agentFolder, withIntermediateDirectories: true)
        try SkillsMarketplaceTests.document(named: Self.hostAgentName).write(
            to: agentFolder.appendingPathComponent(Self.agentDocumentName, isDirectory: false),
            atomically: true, encoding: .utf8)

        let session = try await Self.openAndSwitchSession(
            label: "agents", environment: [Self.agentsDefaultsKey: defaults.path])

        #expect(Self.lists(session.first, agent: Self.hostAgentName))
        #expect(Self.lists(session.switched, agent: Self.hostAgentName))
    }
}
