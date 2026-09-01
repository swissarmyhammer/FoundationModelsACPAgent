import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

/// Layered `config.yaml` loading through `ConfigurationLoader` (plan.md
/// §2.2 and §2.4). Every test builds its own throwaway `user/` and
/// `workspace/.<name>/` tree under a temp directory and injects the user
/// directory and the environment, so no test touches the real home
/// directory.
@Suite struct ConfigurationLoaderTests {
    /// The dotfolder name every fixture stack is built for.
    static let agentName = "testagent"

    /// A throwaway two-layer directory tree. The OS reclaims the temp
    /// directory.
    struct Fixture {
        /// The temp root that holds every other directory.
        let root: URL
        /// The session working directory; the project layer roots under it.
        let workingDirectory: URL
        /// The injected user layer root.
        let userDirectory: URL
        /// The project layer root, `<workingDirectory>/.<name>/`.
        let projectDirectory: URL

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ConfigurationLoaderTests-\(UUID().uuidString)", isDirectory: true)
            workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            projectDirectory = workingDirectory.appendingPathComponent(
                ".\(ConfigurationLoaderTests.agentName)", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: userDirectory, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(
                at: projectDirectory, withIntermediateDirectories: true)
        }

        /// Writes `contents` as `config.yaml` inside `directory`.
        func writeConfig(_ contents: String, in directory: URL) {
            try! FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(ConfigurationLoader.configFileName)
            try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        /// A loader over this fixture with the user directory injected.
        func makeLoader() throws -> ConfigurationLoader {
            try ConfigurationLoader(
                name: DotfolderName(ConfigurationLoaderTests.agentName),
                workingDirectory: workingDirectory,
                userDirectory: userDirectory,
                environment: [:])
        }

        /// Writes `contents` as the project-layer `config.yaml` and loads
        /// the stack — the one-call path the codec suites decode through.
        func loadProjectConfig(_ contents: String) throws -> LoadedConfiguration {
            writeConfig(contents, in: projectDirectory)
            return try makeLoader().load()
        }
    }

    // MARK: - Defaults and layering

    /// With no config files, the loaded configuration is the in-code default
    /// and there is no warning.
    @Test func noFilesGiveTheInCodeDefaults() throws {
        let fixture = Fixture()

        let loaded = try fixture.makeLoader().load()

        #expect(loaded.configuration == AgentConfiguration())
        #expect(loaded.warnings.isEmpty)
    }

    /// The default values the plan names (§2.2): recording is `full` and
    /// transcripts are project-local.
    @Test func inCodeDefaultsMatchThePlan() {
        let configuration = AgentConfiguration()

        #expect(configuration.recording.level == .full)
        #expect(configuration.transcripts.location == .project)
        #expect(configuration.profile.name == nil)
        #expect(!configuration.profile.standard.isEmpty)
        #expect(!configuration.profile.flash.isEmpty)
        #expect(!configuration.profile.embedding.isEmpty)
    }

    /// A project-layer key overrides the same user-layer key. A user-layer
    /// key the project does not name survives: the merge is at key level.
    @Test func projectKeyOverridesUserKeyAtKeyLevel() throws {
        let fixture = Fixture()
        fixture.writeConfig(
            """
            recording:
              level: off
            transcripts:
              location: home
            """, in: fixture.userDirectory)
        fixture.writeConfig(
            """
            recording:
              level: full
            """, in: fixture.projectDirectory)

        let loaded = try fixture.makeLoader().load()

        #expect(loaded.configuration.recording.level == .full)
        #expect(loaded.configuration.transcripts.location == .home)
        #expect(loaded.warnings.isEmpty)
    }

    /// Two loaders with different working directories resolve different
    /// project layers, so two sessions in two repos see their own config.
    @Test func differentWorkingDirectoriesSeeDifferentProjectLayers() throws {
        let first = Fixture()
        let second = Fixture()
        first.writeConfig("recording:\n  level: off\n", in: first.projectDirectory)
        second.writeConfig("transcripts:\n  location: home\n", in: second.projectDirectory)

        let firstLoaded = try first.makeLoader().load()
        let secondLoaded = try second.makeLoader().load()

        #expect(firstLoaded.configuration.recording.level == .off)
        #expect(firstLoaded.configuration.transcripts.location == .project)
        #expect(secondLoaded.configuration.recording.level == .full)
        #expect(secondLoaded.configuration.transcripts.location == .home)
    }

    // MARK: - The user layer location

    /// An absolute `$XDG_CONFIG_HOME` moves the user layer to
    /// `$XDG_CONFIG_HOME/<name>/`, and a file there loads.
    @Test func absoluteXDGConfigHomeIsHonored() throws {
        let fixture = Fixture()
        let xdgHome = fixture.root.appendingPathComponent("xdg", isDirectory: true)
        let xdgUserDirectory = xdgHome.appendingPathComponent(Self.agentName, isDirectory: true)
        fixture.writeConfig("recording:\n  level: off\n", in: xdgUserDirectory)
        let loader = try ConfigurationLoader(
            name: DotfolderName(Self.agentName),
            workingDirectory: fixture.workingDirectory,
            environment: ["XDG_CONFIG_HOME": xdgHome.path])

        let loaded = try loader.load()

        #expect(Self.userLayerPath(of: loader) == xdgUserDirectory.path)
        #expect(loaded.configuration.recording.level == .off)
    }

    /// A relative `$XDG_CONFIG_HOME` is invalid and ignored, and an unset
    /// one is absent: both give `~/.config/<name>/`.
    @Test(arguments: [["XDG_CONFIG_HOME": "relative/config"], [:]])
    func relativeOrUnsetXDGConfigHomeFallsBackToHomeConfig(environment: [String: String])
        throws
    {
        let fixture = Fixture()
        let loader = try ConfigurationLoader(
            name: DotfolderName(Self.agentName),
            workingDirectory: fixture.workingDirectory,
            environment: environment)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(Self.agentName, isDirectory: true)

        #expect(Self.userLayerPath(of: loader) == expected.path)
    }

    /// The project layer is `<workingDirectory>/.<name>/`, with the dot.
    @Test func projectLayerIsTheDottedNameUnderTheWorkingDirectory() throws {
        let fixture = Fixture()

        let loader = try fixture.makeLoader()

        let projectLayer = loader.stack.layers.first { $0.source == .project }
        #expect(projectLayer?.root.path == fixture.projectDirectory.path)
        #expect(loader.stack.layers.map(\.source) == [.user, .project])
    }

    // MARK: - Schema errors and warnings

    /// `recording.level` accepts only `off` and `full`. Any other value is an
    /// error whose message names the two valid ones.
    @Test func metadataRecordingLevelIsRejectedNamingTheValidLevels() throws {
        let fixture = Fixture()
        fixture.writeConfig("recording:\n  level: metadata\n", in: fixture.projectDirectory)

        let error = #expect(throws: (any Error).self) {
            try fixture.makeLoader().load()
        }

        let message = String(describing: error)
        #expect(message.contains("metadata"))
        #expect(message.contains("off"))
        #expect(message.contains("full"))
    }

    /// A `permissions:` section is unknown at the top level: it gives a
    /// warning, not an error, and the rest still decodes to the defaults.
    @Test func permissionsSectionGivesTheUnknownSectionWarning() throws {
        let fixture = Fixture()
        fixture.writeConfig(
            """
            permissions:
              allow:
                - "git status"
            """, in: fixture.projectDirectory)

        let loaded = try fixture.makeLoader().load()

        #expect(loaded.configuration == AgentConfiguration())
        #expect(loaded.warnings == [.unknownSection(name: "permissions")])
        #expect(loaded.warnings[0].description.contains("permissions"))
    }

    /// An unknown key inside a known section is an error that names the
    /// section and the key.
    @Test func unknownKeyInsideKnownSectionIsAnError() throws {
        let fixture = Fixture()
        fixture.writeConfig("recording:\n  levle: full\n", in: fixture.userDirectory)

        #expect(throws: ConfigurationError.unknownKey(section: "recording", key: "levle")) {
            try fixture.makeLoader().load()
        }
    }

    /// A document whose root is not a mapping cannot hold sections.
    @Test func nonMappingDocumentIsAnError() throws {
        let fixture = Fixture()
        fixture.writeConfig("- just\n- a\n- list\n", in: fixture.projectDirectory)

        #expect(throws: ConfigurationError.documentNotAMapping) {
            try fixture.makeLoader().load()
        }
    }

    /// The `tools` and `sandbox` sections decode their bodies through the
    /// codec (plan.md §11.2, §11.7): a `shell: false` turns the tool off and
    /// an `extraWritePaths` entry lands in the sandbox section.
    @Test func toolsAndSandboxBodiesDecodeThroughTheCodec() throws {
        let fixture = Fixture()

        let loaded = try fixture.loadProjectConfig(
            """
            tools:
              shell: false
            sandbox:
              extraWritePaths:
                - /tmp/cache
            """)

        #expect(loaded.configuration.tools.shell == .disabled)
        #expect(loaded.configuration.sandbox.extraWritePaths == ["/tmp/cache"])
        #expect(loaded.warnings.isEmpty)
    }

    // MARK: - Section values

    /// `transcripts.location` reads `project`, `home`, or an absolute path.
    @Test func transcriptLocationReadsTheThreeForms() throws {
        let fixture = Fixture()
        fixture.writeConfig(
            "transcripts:\n  location: /var/transcripts\n", in: fixture.projectDirectory)

        let loaded = try fixture.makeLoader().load()

        #expect(
            loaded.configuration.transcripts.location
                == .path(URL(fileURLWithPath: "/var/transcripts", isDirectory: true)))
    }

    /// A relative `transcripts.location` is none of the three forms.
    @Test func relativeTranscriptLocationIsRejected() throws {
        let fixture = Fixture()
        fixture.writeConfig("transcripts:\n  location: nearby\n", in: fixture.projectDirectory)

        let error = #expect(throws: (any Error).self) {
            try fixture.makeLoader().load()
        }

        let message = String(describing: error)
        #expect(message.contains("nearby"))
        #expect(message.contains("project"))
        #expect(message.contains("home"))
    }

    /// The `profile` and `compaction` sections decode their keys, and a key
    /// that is not set keeps its default.
    @Test func profileAndCompactionSectionsDecode() throws {
        let fixture = Fixture()
        fixture.writeConfig(
            """
            profile:
              name: pair
              standard:
                - org/model-a
                - org/model-b
            compaction:
              trigger: \(Self.configuredTrigger)
              toolOutputLimit: \(Self.configuredToolOutputLimit)
            """, in: fixture.projectDirectory)

        let loaded = try fixture.makeLoader().load()
        let defaults = AgentConfiguration()

        #expect(loaded.configuration.profile.name == "pair")
        #expect(loaded.configuration.profile.standard == ["org/model-a", "org/model-b"])
        #expect(loaded.configuration.profile.flash == defaults.profile.flash)
        #expect(loaded.configuration.compaction.trigger == Self.configuredTrigger)
        #expect(loaded.configuration.compaction.target == defaults.compaction.target)
        #expect(loaded.configuration.compaction.toolOutputLimit == Self.configuredToolOutputLimit)
        #expect(loaded.configuration.compaction.hardCeiling == nil)
    }

    /// The `compaction.trigger` the section test writes; it differs from the
    /// default so the decode is observable.
    private static let configuredTrigger = 0.7

    /// The `compaction.toolOutputLimit` the section test writes.
    private static let configuredToolOutputLimit = 4000

    // MARK: - Helpers

    /// The path of `loader`'s user layer root.
    private static func userLayerPath(of loader: ConfigurationLoader) -> String? {
        loader.stack.layers.first { $0.source == .user }?.root.path
    }
}
