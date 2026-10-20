import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `SettingsFolders` (ACPA-16, D98): one list of folders for each kind of
/// settings. With a root settings folder from the host, the user layer of
/// each kind is in the root, and the project layer is the project dotfolder
/// of the working directory. With no root (the CLI), the layers are the
/// layers of `DotfolderStack(name:workingDirectory:environment:)`.
///
/// Each test uses temporary folders only. A test gives an `XDG_CONFIG_HOME`
/// in a temporary folder, so no test reads the real home directory.
struct SettingsFoldersTests {
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

    /// The value of `compaction.trigger` in the root settings folder.
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

    // MARK: - Fixture

    /// A temporary root settings folder, a temporary working directory, and
    /// a temporary XDG config home.
    private struct Fixture {
        /// The root settings folder of the host.
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

        /// The settings folders of the fixture.
        ///
        /// - Parameter hasRoot: `true` gives ``root`` as the root settings
        ///   folder; `false` gives no root.
        /// - Returns: The settings folders.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        func settingsFolders(hasRoot: Bool) throws -> SettingsFolders {
            SettingsFolders(
                name: try DotfolderName(SettingsFoldersTests.dotfolderName),
                rootSettingsFolder: hasRoot ? root : nil,
                environment: environment)
        }
    }

    /// One kind, with the user layer root that a root settings folder gives
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

    /// Each kind and the folders a root settings folder gives it.
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
    ///   - root: The root settings folder.
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
            rootSettingsFolder: fixture.root,
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
            workspace: fixture.workingDirectory, rootSettingsFolder: fixture.root,
            configHome: fixture.configHome)
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
        let context = CatalogContext(
            workingDirectory: fixture.workingDirectory,
            configuration: AgentConfiguration.withoutMarketplaces,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "SettingsFoldersTests-skills-cache")),
            settingsFolders: try fixture.settingsFolders(hasRoot: true),
            environment: fixture.environment)

        let skills = await ToolCatalog.makeSkillsSource(context: context).registry.metadata()

        let skill = try #require(skills.first { $0.id == Self.sharedSkillID })
        #expect(skill.description == Self.projectSkillDescription)
    }
}
