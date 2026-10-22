import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `SettingsFolders` (ACPA-16, D98): one list of folders for each kind of
/// settings. With a custom home from the host, the user layer of each kind
/// is in the synced root of the home (the root of these tests), and the
/// project layer is the project dotfolder of the working directory. With
/// the XDG home (no root, the CLI), the layers are the layers of
/// `DotfolderStack(name:workingDirectory:environment:)`.
///
/// Each test uses temporary folders only. A test gives an `XDG_CONFIG_HOME`
/// in a temporary folder, so no test reads the real home directory.
struct SettingsFoldersTests {
    /// The tool catalog of this package. FoundationModelsAgents also has a
    /// type named `ToolCatalog`, thus this alias names the type of this
    /// package in the suite.
    private typealias ToolCatalog = FoundationModelsACPAgent.ToolCatalog

    // MARK: - Constants

    /// The dotfolder name of the configuration in these tests.
    private static let dotfolderName = "settings-test"

    /// The environment variable that roots the XDG user layer.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The suffix of the environment variable that names the defaults layer
    /// of a dotfolder name.
    private static let defaultsVariableSuffix = StubAgentDefaultsLayer.environmentKeySuffix

    /// The value of `compaction.trigger` in the XDG user layer.
    private static let configHomeTrigger = 0.6

    /// The value of `compaction.trigger` in the synced root.
    private static let rootTrigger = 0.7

    /// The value of `compaction.trigger` in the project layer.
    private static let projectTrigger = 0.9

    /// The value of `compaction.target` that only the XDG user layer sets.
    private static let configHomeOnlyTarget = 0.3

    /// The id of the skill that the root and the project both hold.
    private static let sharedSkillID = "review"

    /// The description of the root copy of the shared skill.
    private static let rootSkillDescription = "The root copy."

    /// The description of the project copy of the shared skill.
    private static let projectSkillDescription = "The project copy."

    /// The text of the root `Instructions.md`.
    private static let rootInstructions = "The instructions of the root."

    /// The text of the project `Instructions.md`.
    private static let projectInstructions = "The instructions of the project."

    /// The document of an agent folder.
    private static let agentDocumentName = "AGENT.md"

    /// The id of the agent that only the synced root holds.
    private static let rootAgentID = "planner"

    /// The id of the agent that two layers hold.
    private static let sharedAgentID = "reviewer"

    /// The id of the agent that only the XDG config home holds.
    private static let configHomeAgentID = "helper"

    // MARK: - Fixture

    /// A temporary synced root, a temporary working directory, and a
    /// temporary XDG config home.
    private struct Fixture {
        /// The synced root of the custom home of the host.
        let root: URL

        /// The working directory of the session.
        let workingDirectory: URL

        /// The `XDG_CONFIG_HOME` of the environment.
        let configHome: URL

        /// Makes the three folders.
        ///
        /// - Parameter label: The prefix that names the test.
        init(label: String) {
            root = makeResolvedDirectory(label: "SettingsFoldersTests-\(label)-root")
            workingDirectory = makeResolvedDirectory(label: "SettingsFoldersTests-\(label)-repo")
            configHome = makeResolvedDirectory(label: "SettingsFoldersTests-\(label)-config")
        }

        /// The environment with ``configHome`` as `XDG_CONFIG_HOME`.
        var environment: [String: String] {
            [SettingsFoldersTests.configHomeVariable: configHome.path]
        }

        /// The XDG user layer of `dotfolder`, `<configHome>/<dotfolder>/`.
        ///
        /// - Parameter dotfolder: The dotfolder name of a kind.
        /// - Returns: The folder.
        func configHomeLayer(of dotfolder: String) -> URL {
            configHome.appendingPathComponent(dotfolder, isDirectory: true)
        }

        /// The project layer of `dotfolder`, `<workingDirectory>/.<dotfolder>/`.
        ///
        /// - Parameter dotfolder: The dotfolder name of a kind.
        /// - Returns: The folder.
        func projectLayer(of dotfolder: String) -> URL {
            workingDirectory.appendingPathComponent(".\(dotfolder)", isDirectory: true)
        }

        /// The custom home whose synced root is ``root``, with a throwaway
        /// local root.
        var customHome: AgentHome {
            AgentHomeFixture.make(label: "SettingsFoldersTests", synced: root)
        }

        /// The settings folders of the fixture.
        ///
        /// - Parameter hasRoot: `true` gives the custom home whose synced
        ///   root is ``root``; `false` gives the XDG home of ``environment``.
        /// - Returns: The settings folders.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        func settingsFolders(hasRoot: Bool) throws -> SettingsFolders {
            let name = try DotfolderName(SettingsFoldersTests.dotfolderName)
            return SettingsFolders(
                name: name,
                home: hasRoot ? customHome : .xdg(name: name, environment: environment),
                environment: environment)
        }
    }

    /// One kind, with the user layer root that a synced root gives
    /// it, relative to the root.
    struct KindCase: Sendable, CustomTestStringConvertible {
        /// The kind.
        let kind: SettingsFolders.Kind

        /// The path of the user layer in the root; empty for the root
        /// itself.
        let userPathInRoot: String

        /// The dotfolder name of the project layer, with no leading dot.
        let projectDotfolder: String

        /// The name of the case in the test report.
        var testDescription: String { "\(kind)" }
    }

    /// Each kind and the folders a synced root gives it.
    static let kindCases = [
        KindCase(kind: .configuration, userPathInRoot: "", projectDotfolder: dotfolderName),
        KindCase(
            kind: .skills, userPathInRoot: SettingsFolders.skillsFolderName,
            projectDotfolder: ToolCatalog.skillsDotfolderName),
        KindCase(kind: .agents, userPathInRoot: "", projectDotfolder: ToolCatalog.agentsDotfolderName),
        KindCase(
            kind: .rules, userPathInRoot: SettingsFolders.rulesFolderName,
            projectDotfolder: SettingsFolders.rulesDotfolderName),
    ]

    /// The user layer root that a case expects in `root`.
    ///
    /// - Parameters:
    ///   - kindCase: The case.
    ///   - root: The synced root.
    /// - Returns: The folder.
    private static func expectedUserLayer(of kindCase: KindCase, in root: URL) -> URL {
        kindCase.userPathInRoot.isEmpty
            ? root : root.appendingPathComponent(kindCase.userPathInRoot, isDirectory: true)
    }

    /// The root and the source of each layer of `stack`, lowest first.
    ///
    /// - Parameter stack: The stack.
    /// - Returns: One pair for each layer.
    private static func layerList(of stack: DotfolderStack) -> [String] {
        stack.layers.map { "\($0.source):\($0.root.standardizedFileURL.path)" }
    }

    // MARK: - The layers with a root

    /// With a root, the stack of each kind is the user layer in the root
    /// under the project dotfolder of the working directory.
    @Test(arguments: kindCases)
    func withARootTheLayersAreTheRootAndTheProjectDotfolder(kindCase: KindCase) throws {
        let fixture = Fixture(label: "root-\(kindCase.kind)")

        let stack = try fixture.settingsFolders(hasRoot: true)
            .stack(for: kindCase.kind, workingDirectory: fixture.workingDirectory)

        let expected = DotfolderStack(layers: [
            DotfolderStack.Layer(
                source: .user, root: Self.expectedUserLayer(of: kindCase, in: fixture.root)),
            DotfolderStack.Layer(
                source: .project, root: fixture.projectLayer(of: kindCase.projectDotfolder)),
        ])
        #expect(Self.layerList(of: stack) == Self.layerList(of: expected))
    }

    /// With a root, no layer of any kind is in the XDG config home or in the
    /// home directory, also when the environment names an XDG config home.
    @Test(arguments: kindCases)
    func withARootNoLayerIsInTheConfigHomeOrTheHomeDirectory(kindCase: KindCase) throws {
        let fixture = Fixture(label: "no-home-\(kindCase.kind)")
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        let stack = try fixture.settingsFolders(hasRoot: true)
            .stack(for: kindCase.kind, workingDirectory: fixture.workingDirectory)

        let roots = stack.layers.map(\.root.standardizedFileURL.path)
        #expect(!roots.contains { $0.hasPrefix(fixture.configHome.standardizedFileURL.path) })
        #expect(!roots.contains { $0.hasPrefix(home) })
    }

    /// With a root, the defaults layer that `<NAME>_DEFAULTS_DIR` names stays
    /// the lowest layer.
    @Test func withARootTheDefaultsLayerOfTheEnvironmentStaysTheLowestLayer() throws {
        let fixture = Fixture(label: "defaults")
        let defaults = makeResolvedDirectory(label: "SettingsFoldersTests-defaults")
        let settingsFolders = SettingsFolders(
            name: try DotfolderName(Self.dotfolderName),
            home: fixture.customHome,
            environment: [Self.dotfolderName.uppercased() + Self.defaultsVariableSuffix: defaults.path])

        let stack = settingsFolders.stack(for: .configuration, workingDirectory: fixture.workingDirectory)

        let lowest = try #require(stack.layers.first)
        #expect(lowest.source == .defaults)
        #expect(lowest.root.standardizedFileURL.path == defaults.standardizedFileURL.path)
    }

    // MARK: - The layers with no root

    /// With no root, the stack of each kind has the layers of
    /// `DotfolderStack(name:workingDirectory:environment:)`, as before.
    @Test(arguments: kindCases)
    func withNoRootEachKindKeepsTheOldLayerList(kindCase: KindCase) throws {
        let fixture = Fixture(label: "no-root-\(kindCase.kind)")

        let stack = try fixture.settingsFolders(hasRoot: false)
            .stack(for: kindCase.kind, workingDirectory: fixture.workingDirectory)

        let old = DotfolderStack(
            name: kindCase.projectDotfolder, workingDirectory: fixture.workingDirectory,
            environment: fixture.environment)
        #expect(Self.layerList(of: stack) == Self.layerList(of: old))
    }

    // MARK: - config.yaml

    /// The `config.yaml` text that sets `compaction.trigger`, and
    /// `compaction.target` when `target` is not `nil`.
    ///
    /// - Parameters:
    ///   - trigger: The value of `compaction.trigger`.
    ///   - target: The value of `compaction.target`, or `nil` for no key.
    /// - Returns: The text.
    private static func compactionYAML(trigger: Double, target: Double? = nil) -> String {
        "compaction:\n  trigger: \(trigger)\n" + (target.map { "  target: \($0)\n" } ?? "")
    }

    /// Writes the `compaction.trigger` value of each of the three layers,
    /// and a `compaction.target` in the XDG user layer only.
    ///
    /// - Parameter fixture: The folders to write into.
    /// - Throws: The directory-creation or write error.
    private static func writeThreeConfigurationLayers(in fixture: Fixture) throws {
        try ConfigFileFixture.write(
            compactionYAML(trigger: configHomeTrigger, target: configHomeOnlyTarget),
            in: fixture.configHomeLayer(of: dotfolderName))
        try ConfigFileFixture.write(compactionYAML(trigger: rootTrigger), in: fixture.root)
        try ConfigFileFixture.write(
            compactionYAML(trigger: projectTrigger), in: fixture.projectLayer(of: dotfolderName))
    }

    /// With a root, a key that the root, the project and the XDG config home
    /// all set has the project value, and a key that only the XDG config home
    /// sets is not set.
    @Test func withARootTheProjectWinsAndTheConfigHomeIsNotRead() throws {
        let fixture = Fixture(label: "config")
        try Self.writeThreeConfigurationLayers(in: fixture)

        let loaded = try ConfigurationLoader(
            settingsFolders: try fixture.settingsFolders(hasRoot: true),
            workingDirectory: fixture.workingDirectory,
            secretStore: InMemorySecretStore()
        ).load()

        #expect(loaded.configuration.compaction.trigger == Self.projectTrigger)
        #expect(loaded.configuration.compaction.target == CompactionConfiguration.defaultTarget)
    }

    /// With a root, the start-up load of `ComposedAgent.compose` and the load
    /// of each session read the root and the project, and the project wins.
    @Test func theComposedAgentReadsTheRootAndTheProject() async throws {
        let fixture = Fixture(label: "compose")
        try Self.writeThreeConfigurationLayers(in: fixture)

        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "SettingsFoldersTests-compose",
            workspace: fixture.workingDirectory, home: fixture.customHome,
            environment: fixture.environment)
        let session = try composed.agent.makeConfigurationLoader(
            workingDirectory: fixture.workingDirectory
        ).load().configuration

        #expect(composed.configuration.compaction.trigger == Self.projectTrigger)
        #expect(composed.configuration.compaction.target == CompactionConfiguration.defaultTarget)
        #expect(session.compaction.trigger == Self.projectTrigger)
        #expect(session.compaction.target == CompactionConfiguration.defaultTarget)
    }

    // MARK: - Instructions.md

    /// With a root, the `Instructions.md` of the project wins over the one
    /// of the root.
    @Test func withARootTheProjectInstructionsWin() async throws {
        let fixture = Fixture(label: "instructions")
        let projectLayer = fixture.projectLayer(of: Self.dotfolderName)
        try FileManager.default.createDirectory(at: projectLayer, withIntermediateDirectories: true)
        try Self.rootInstructions.write(
            to: fixture.root.appendingPathComponent(InstructionsAssembler.instructionsFileName),
            atomically: true, encoding: .utf8)
        try Self.projectInstructions.write(
            to: projectLayer.appendingPathComponent(InstructionsAssembler.instructionsFileName),
            atomically: true, encoding: .utf8)
        let stack = try fixture.settingsFolders(hasRoot: true)
            .stack(for: .configuration, workingDirectory: fixture.workingDirectory)

        let assembled = try await InstructionsAssembler(
            stack: stack, workingDirectory: fixture.workingDirectory
        ).assemble()

        #expect(assembled.text.contains(Self.projectInstructions))
        #expect(!assembled.text.contains(Self.rootInstructions))
    }

    // MARK: - Skills

    /// The `SKILL.md` text of the shared skill with `description`.
    ///
    /// - Parameter description: The description of the copy.
    /// - Returns: The text.
    private static func sharedSkillMarkdown(description: String) -> String {
        "---\nname: \(sharedSkillID)\ndescription: \(description)\n---\nReview the change.\n"
    }

    /// With a root, a skill in `<root>/_skills/` and a skill with the same id
    /// in the project give the project skill.
    @Test func withARootTheProjectSkillWinsOverTheRootSkill() async throws {
        let fixture = Fixture(label: "skills")
        try writeSkillFixture(
            id: Self.sharedSkillID,
            markdown: Self.sharedSkillMarkdown(description: Self.rootSkillDescription),
            under: fixture.root.appendingPathComponent(SettingsFolders.skillsFolderName, isDirectory: true))
        try writeSkillFixture(
            id: Self.sharedSkillID,
            markdown: Self.sharedSkillMarkdown(description: Self.projectSkillDescription),
            under: fixture.projectLayer(of: ToolCatalog.skillsDotfolderName))
        let context = try await Self.catalogContext(of: fixture, hasRoot: true)

        let skills = await ToolCatalog.makeSkillsSource(context: context).registry.metadata()

        let skill = try #require(skills.first { $0.id == Self.sharedSkillID })
        #expect(skill.description == Self.projectSkillDescription)
    }

    /// Makes a catalog context over the folders of `fixture`, with no
    /// marketplace, so that it needs no network.
    ///
    /// - Parameters:
    ///   - fixture: The folders of the test.
    ///   - hasRoot: `true` gives the custom home whose synced root is the
    ///     root of the fixture; `false` gives the XDG home.
    /// - Returns: The context.
    /// - Throws: Whatever the stub profile resolve throws, or
    ///   `DotfolderNameError` when the dotfolder name is refused.
    private static func catalogContext(of fixture: Fixture, hasRoot: Bool) async throws -> CatalogContext {
        CatalogContext(
            workingDirectory: fixture.workingDirectory,
            configuration: AgentConfiguration.withoutMarketplaces,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "SettingsFoldersTests-cache")),
            settingsFolders: try fixture.settingsFolders(hasRoot: hasRoot),
            environment: fixture.environment)
    }

    // MARK: - Agents

    /// Writes the agent folder `<layer>/<id>/AGENT.md`.
    ///
    /// - Parameters:
    ///   - id: The id of the agent, which is also the folder name.
    ///   - layer: The folder that holds the agent folder.
    /// - Throws: The directory-creation or write error.
    private static func writeAgent(id: String, under layer: URL) throws {
        let folder = layer.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SkillsMarketplaceTests.document(named: id).write(
            to: folder.appendingPathComponent(agentDocumentName, isDirectory: false),
            atomically: true, encoding: .utf8)
    }

    /// The agent catalog that the session composition loads over the folders
    /// of `fixture`.
    ///
    /// - Parameters:
    ///   - fixture: The folders of the test.
    ///   - hasRoot: `true` gives the custom home whose synced root is the
    ///     root of the fixture; `false` gives the XDG home.
    /// - Returns: The loaded catalog.
    /// - Throws: Whatever the context or the load of the registry throws.
    private static func composedAgentCatalog(of fixture: Fixture, hasRoot: Bool) async throws -> AgentCatalog {
        let context = try await catalogContext(of: fixture, hasRoot: hasRoot)
        let registry = AgentsComposition.makeAgentRegistry(context: context, marketplaces: nil)
        try await registry.load()
        return registry.catalog()
    }

    /// The id and the document path of each agent of `catalog`, in catalog
    /// order.
    ///
    /// - Parameter catalog: The catalog.
    /// - Returns: One `<id>:<path>` entry for each agent.
    private static func agentList(of catalog: AgentCatalog) -> [String] {
        catalog.definitions.map { "\($0.id):\($0.url.standardizedFileURL.path)" }
    }

    /// With a root, an agent in `<root>/<id>/AGENT.md` is in the catalog,
    /// and an agent with the same id in the project dotfolder of the working
    /// directory wins.
    @Test func withARootTheRootAgentIsInTheCatalogAndTheProjectAgentWins() async throws {
        let fixture = Fixture(label: "agents")
        let projectLayer = fixture.projectLayer(of: ToolCatalog.agentsDotfolderName)
        try Self.writeAgent(id: Self.rootAgentID, under: fixture.root)
        try Self.writeAgent(id: Self.sharedAgentID, under: fixture.root)
        try Self.writeAgent(id: Self.sharedAgentID, under: projectLayer)

        let catalog = try await Self.composedAgentCatalog(of: fixture, hasRoot: true)

        let rootAgent = try #require(catalog.definition(named: Self.rootAgentID))
        #expect(rootAgent.folderURL.standardizedFileURL.path.hasPrefix(fixture.root.standardizedFileURL.path))
        let sharedAgent = try #require(catalog.definition(named: Self.sharedAgentID))
        #expect(
            sharedAgent.folderURL.standardizedFileURL.path
                == projectLayer.appendingPathComponent(Self.sharedAgentID, isDirectory: true)
                .standardizedFileURL.path)
    }

    /// With a root, the settings folders `<root>/_skills/` and
    /// `<root>/_rules/` are not agents, also when each holds an `AGENT.md`,
    /// and they give no diagnostic.
    @Test func withARootTheSettingsFoldersOfTheRootAreNotAgents() async throws {
        let fixture = Fixture(label: "agents-settings")
        try Self.writeAgent(id: SettingsFolders.skillsFolderName, under: fixture.root)
        try Self.writeAgent(id: SettingsFolders.rulesFolderName, under: fixture.root)
        try writeSkillFixture(
            id: Self.sharedSkillID,
            markdown: Self.sharedSkillMarkdown(description: Self.rootSkillDescription),
            under: fixture.root.appendingPathComponent(SettingsFolders.skillsFolderName, isDirectory: true))

        let catalog = try await Self.composedAgentCatalog(of: fixture, hasRoot: true)

        #expect(catalog.definition(named: SettingsFolders.skillsFolderName) == nil)
        #expect(catalog.definition(named: SettingsFolders.rulesFolderName) == nil)
        #expect(catalog.definition(named: Self.sharedSkillID) == nil)
        #expect(catalog.diagnostics.isEmpty)
    }

    /// With a root, no agent comes from the XDG config home: neither the
    /// agent folder form nor the `agents/` form of `<XDG_CONFIG_HOME>/agents/`.
    @Test func withARootNoAgentComesFromTheConfigHome() async throws {
        let fixture = Fixture(label: "agents-config-home")
        let configHomeLayer = fixture.configHomeLayer(of: ToolCatalog.agentsDotfolderName)
        try Self.writeAgent(id: Self.configHomeAgentID, under: configHomeLayer)
        try Self.writeAgent(
            id: Self.configHomeAgentID,
            under: configHomeLayer.appendingPathComponent(ToolCatalog.agentsDotfolderName, isDirectory: true))

        let catalog = try await Self.composedAgentCatalog(of: fixture, hasRoot: true)

        #expect(catalog.definition(named: Self.configHomeAgentID) == nil)
    }

    /// With no root, the catalog is the catalog of the old stack
    /// `DotfolderStack(name: "agents", ...)`, and it holds the agents of the
    /// XDG config home.
    @Test func withNoRootTheCatalogIsTheCatalogOfTheOldStack() async throws {
        let fixture = Fixture(label: "agents-no-root")
        let configHomeLayer = fixture.configHomeLayer(of: ToolCatalog.agentsDotfolderName)
        try Self.writeAgent(id: Self.configHomeAgentID, under: configHomeLayer)
        try Self.writeAgent(id: Self.sharedAgentID, under: configHomeLayer)
        try Self.writeAgent(
            id: Self.sharedAgentID, under: fixture.projectLayer(of: ToolCatalog.agentsDotfolderName))
        let old = AgentRegistry(
            stack: DotfolderStack(
                name: ToolCatalog.agentsDotfolderName, workingDirectory: fixture.workingDirectory,
                environment: fixture.environment))
        try await old.load()

        let catalog = try await Self.composedAgentCatalog(of: fixture, hasRoot: false)

        #expect(catalog.definition(named: Self.configHomeAgentID) != nil)
        #expect(Self.agentList(of: catalog) == Self.agentList(of: old.catalog()))
    }
}
