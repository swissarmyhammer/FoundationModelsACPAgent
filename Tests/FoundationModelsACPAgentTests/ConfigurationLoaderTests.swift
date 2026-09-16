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

    // MARK: - The builtin default models

    /// The empty stack — no `config.yaml` in any layer — gives the three
    /// model references of cli-plan.md §7 exactly. This is what a person
    /// gets on a first run with no configuration, so a wrong id here stops
    /// that run.
    @Test func theEmptyStackGivesTheThreeDefaultModels() throws {
        let fixture = Fixture()

        let profile = try fixture.makeLoader().load().configuration.profile

        #expect(profile.standard.map(\.stringValue) == [Self.defaultStandardModel])
        #expect(profile.flash.map(\.stringValue) == [Self.defaultFlashModel])
        #expect(profile.embedding.map(\.stringValue) == [Self.defaultEmbeddingModel])
    }

    /// No default names an MTP (multi-token prediction) repository
    /// (cli-plan.md §7.1). Router calls the plain generate path and does not
    /// read an MTP draft head, so an MTP repository downloads bytes that do
    /// no work. This test keeps a later edit from making one a default by
    /// accident.
    ///
    /// A Hugging Face repository id keeps its case, and the marker is usually
    /// upper case. But the case is the publisher's choice, not a rule, so the
    /// match ignores case: a lower-case `mtp` names the same draft head.
    @Test(arguments: ConfigurationLoaderTests.defaultModelReferences)
    func noDefaultModelNamesAnMTPRepository(reference: ModelRef) {
        #expect(!Self.namesMultiTokenPredictionRepository(reference.stringValue))
    }

    /// The MTP check reads the marker as a word of the id, wherever the word
    /// stands, and it reads no bare `mtp` inside a word.
    ///
    /// The test above runs the check over the builtin defaults, and no default
    /// holds the marker. That test thus cannot show that the check finds a
    /// marker, or that the check accepts an id it must accept. This test shows
    /// both answers, over each position the marker word can take.
    @Test(arguments: ConfigurationLoaderTests.multiTokenPredictionExamples)
    func theMTPCheckReadsTheMarkerAsAWordOfTheId(
        identifier: String, namesADraftHead: Bool
    ) {
        #expect(Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead)
    }

    /// Tells if `identifier` names a multi-token-prediction repository.
    ///
    /// One rule reads the marker: `MTP` is a word of the id. A word opens at
    /// the start of the id, after a hyphen, or after the owner separator; it
    /// closes at the end of the id or before a hyphen. The rule holds wherever
    /// the word stands — at the start of the name, in the middle, at the end,
    /// as the whole name, and in an id that has no owner separator.
    ///
    /// The rule keeps the marker a word, thus a bare `mtp` inside a word, as in
    /// `Qwen3-mtprime-4bit`, does not match, and the check accepts an id it
    /// must accept. The owner separator opens a word but does not close one,
    /// thus an owner whose whole name is `mtp` names a publisher, not a draft
    /// head.
    ///
    /// The case is the publisher's choice, not a rule, thus the match ignores
    /// case.
    ///
    /// - Parameter identifier: The model id to read.
    /// - Returns: `true` when the id names a draft head.
    private static func namesMultiTokenPredictionRepository(_ identifier: String) -> Bool {
        var searchStart = identifier.startIndex

        while let marker = identifier.range(
            of: multiTokenPredictionMarker,
            options: .caseInsensitive,
            range: searchStart..<identifier.endIndex)
        {
            if isAWord(marker, ofIdentifier: identifier) { return true }
            searchStart = identifier.index(after: marker.lowerBound)
        }

        return false
    }

    /// Tells if `range` covers a whole word of the model id `identifier`.
    ///
    /// - Parameters:
    ///   - range: The part of the id to read.
    ///   - identifier: The model id that holds `range`.
    /// - Returns: `true` when a word opener or the start of the id stands
    ///   before `range`, and a word separator or the end of the id stands
    ///   after it.
    private static func isAWord(
        _ range: Range<String.Index>, ofIdentifier identifier: String
    ) -> Bool {
        let opensAWord =
            range.lowerBound == identifier.startIndex
            || modelIdentifierWordOpeners.contains(
                identifier[identifier.index(before: range.lowerBound)])
        let closesAWord =
            range.upperBound == identifier.endIndex
            || identifier[range.upperBound] == modelIdentifierWordSeparator

        return opensAWord && closesAWord
    }

    /// Each default id has the shape `owner/name`: two parts, each one not
    /// empty, and no space in the id. This is the cheap half of the doctor's
    /// model check, and it is available now.
    @Test(arguments: ConfigurationLoaderTests.defaultModelReferences)
    func everyDefaultModelIdHasTheOwnerNameShape(reference: ModelRef) {
        let identifier = reference.stringValue

        let parts = identifier.split(
            separator: Self.modelOwnerSeparator, omittingEmptySubsequences: false)
        let holdsWhitespace = identifier.contains(where: \.isWhitespace)

        #expect(parts.count == Self.modelIdentifierPartCount)
        #expect(parts.allSatisfy { !$0.isEmpty })
        #expect(!holdsWhitespace)
    }

    /// The `standard` slot default of the builtin configuration.
    private static let defaultStandardModel = "mlx-community/Qwen3.8-27B-mxfp4"

    /// The `flash` slot default of the builtin configuration.
    private static let defaultFlashModel = "mlx-community/Qwen3-4B-4bit"

    /// The `embedding` slot default of the builtin configuration.
    private static let defaultEmbeddingModel = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// Every model reference the builtin defaults name, over the three slots.
    private static var defaultModelReferences: [ModelRef] {
        let profile = AgentConfiguration().profile
        return profile.standard + profile.flash + profile.embedding
    }

    /// The word that marks a multi-token-prediction repository.
    private static let multiTokenPredictionMarker = "MTP"

    /// Model ids the MTP check reads, and the answer each one must get.
    ///
    /// The first ten hold the marker as a word, and they cover each position
    /// the word can take, in upper case and in lower case: in the middle of the
    /// name, at the end of the id, at the start of the name, as the whole name,
    /// and at the start of an id that has no owner separator. `mtprime/MTP-4bit`
    /// holds the letters twice, and only the second holding is a word, thus it
    /// shows that the check reads the id to its end.
    ///
    /// The last seven hold no marker word, and each half of the rule is
    /// necessary to keep them out. `Qwen3-mtprime-4bit` holds a bare `mtp`
    /// inside a word and `mtprime-4bit` starts with those letters, thus a rule
    /// that does not close the word admits them. `Qwen3-Xmtp-4bit` ends a word
    /// with those letters, thus a rule that does not open the word admits it.
    /// In `mtp/Qwen3-30B-4bit` and `MTP/Qwen3-30B-4bit` the whole owner is the
    /// marker. The owner separator opens a word, but it does not close one,
    /// thus these two ids name a publisher and not a draft head. A rule that
    /// closes a word at the owner separator too is symmetrical, and it admits
    /// them. That change is one character, and it makes the check reject a
    /// publisher it must accept. Both cases of the owner stand here, because
    /// the check ignores case, thus each case must get the same answer.
    /// The two builtin defaults beside them are ids the check reads every run.
    private static let multiTokenPredictionExamples: [(String, Bool)] = [
        ("mlx-community/Qwen3-30B-A3B-MTP-4bit", true),
        ("mlx-community/Qwen3-30B-A3B-mtp-4bit", true),
        ("mlx-community/Qwen3.5-9B-MTP", true),
        ("mlx-community/Qwen3.5-9B-mtp", true),
        ("mlx-community/MTP-Qwen3-30B-4bit", true),
        ("mlx-community/mtp-Qwen3-30B-4bit", true),
        ("mlx-community/MTP", true),
        ("mlx-community/mtp", true),
        ("MTP-Qwen3-4bit", true),
        ("mtprime/MTP-4bit", true),
        ("mlx-community/Qwen3-mtprime-4bit", false),
        ("mlx-community/mtprime-4bit", false),
        ("mlx-community/Qwen3-Xmtp-4bit", false),
        ("mtp/Qwen3-30B-4bit", false),
        ("MTP/Qwen3-30B-4bit", false),
        (defaultStandardModel, false),
        (defaultEmbeddingModel, false),
    ]

    /// The separator between the owner and the name of a model id.
    private static let modelOwnerSeparator: Character = "/"

    /// The separator between the words of a model name.
    private static let modelIdentifierWordSeparator: Character = "-"

    /// The characters that open a word of a model id. The owner separator opens
    /// the name, thus the first word of the name stands after it.
    private static let modelIdentifierWordOpeners: Set<Character> = [
        modelIdentifierWordSeparator, modelOwnerSeparator,
    ]

    /// The count of parts an `owner/name` model id has.
    private static let modelIdentifierPartCount = 2

    // MARK: - The per-key source map

    /// The source map names the layer that set each key, by dotted key
    /// path: the project layer wins the key both layers set, the user
    /// layer keeps the key only it set, and a key no layer set is absent,
    /// which is the builtin default (cli-plan.md §5.11).
    @Test func sourceMapNamesTheLayerThatSetEachKey() throws {
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

        #expect(loaded.sources["recording.level"] == .project)
        #expect(loaded.sources["transcripts.location"] == .user)
        #expect(loaded.sources["compaction.trigger"] == nil)
        #expect(loaded.sources["profile"] == nil)
    }

    /// Every `DotfolderStack.Source` has its own layer name, the
    /// marketplace layer included, so a report can name the layer a key
    /// came from without a fallback.
    @Test(arguments: [
        (DotfolderStack.Source.defaults, ConfigurationLayerName.defaults),
        (DotfolderStack.Source.user, ConfigurationLayerName.user),
        (DotfolderStack.Source.project, ConfigurationLayerName.project),
        (DotfolderStack.Source.marketplace, ConfigurationLayerName.marketplace),
    ])
    func eachSourceNamesItsOwnLayer(source: DotfolderStack.Source, name: ConfigurationLayerName) {
        #expect(ConfigurationLayerName(source) == name)
    }

    /// With no file in any layer the source map is empty: every key is
    /// builtin.
    @Test func noFilesGiveAnEmptySourceMap() throws {
        let fixture = Fixture()

        let loaded = try fixture.makeLoader().load()

        #expect(loaded.sources.isEmpty)
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

    /// A project `config.yaml` that names a model for each of the three slots
    /// wins over each builtin default (cli-plan.md §7).
    ///
    /// The section test above writes the `standard` slot alone, thus it shows
    /// the override for one slot of three. This test writes all three slots and
    /// reads all three values back, thus each default is shown to lose.
    @Test func eachProfileSlotInTheProjectConfigWinsOverItsDefault() throws {
        let fixture = Fixture()

        let loaded = try fixture.loadProjectConfig(
            """
            profile:
              standard:
                - \(Self.configuredStandardModel)
              flash:
                - \(Self.configuredFlashModel)
              embedding:
                - \(Self.configuredEmbeddingModel)
            """)

        let profile = loaded.configuration.profile
        let defaults = AgentConfiguration().profile
        #expect(profile.standard.map(\.stringValue) == [Self.configuredStandardModel])
        #expect(profile.flash.map(\.stringValue) == [Self.configuredFlashModel])
        #expect(profile.embedding.map(\.stringValue) == [Self.configuredEmbeddingModel])
        #expect(profile.standard != defaults.standard)
        #expect(profile.flash != defaults.flash)
        #expect(profile.embedding != defaults.embedding)
    }

    /// The `compaction.trigger` the section test writes; it differs from the
    /// default so the decode is observable.
    private static let configuredTrigger = 0.7

    /// The `compaction.toolOutputLimit` the section test writes.
    private static let configuredToolOutputLimit = 4000

    /// The `profile.standard` model the override test writes. It differs from
    /// the default, thus the override is observable.
    private static let configuredStandardModel = "org/standard-override"

    /// The `profile.flash` model the override test writes.
    private static let configuredFlashModel = "org/flash-override"

    /// The `profile.embedding` model the override test writes.
    private static let configuredEmbeddingModel = "org/embedding-override"

    // MARK: - Helpers

    /// The path of `loader`'s user layer root.
    private static func userLayerPath(of loader: ConfigurationLoader) -> String? {
        loader.stack.layers.first { $0.source == .user }?.root.path
    }
}
