import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// `SettingsStore` (ACPA-17, D100(f)): one settings object in memory for
/// each level, a flush of the level to its `config.yaml` after each `set` and
/// `clear`, and a reload when a `config.yaml` changes from outside.
///
/// Each test uses temporary folders from ``SettingsFoldersFixture`` and
/// ``makeResolvedDirectory(label:)``, and an ``InMemorySecretStore``. Thus no
/// test reads the real home directory or the real Keychain.
@Suite struct SettingsStoreTests {
    // MARK: - Constants

    /// The key path of `compaction.trigger`.
    private static let triggerKeyPath = ["compaction", "trigger"]

    /// The key path of `tools.mcp`, which only the builtin file sets in these
    /// tests.
    private static let builtinKeyPath = ["tools", "mcp"]

    /// The key path of `recording.level`.
    private static let recordingLevelKeyPath = ["recording", "level"]

    /// The dotted form of ``triggerKeyPath``, as the sources give it.
    private static let triggerSourceKey = "compaction.trigger"

    /// The value of `compaction.trigger` that the user level sets.
    private static let userTrigger = 0.7

    /// The value of `compaction.trigger` that a session level sets.
    private static let sessionTrigger = 0.9

    /// The value of `compaction.trigger` that an outside write sets.
    private static let outsideTrigger = 0.8

    /// A value of `recording.level` that does not decode.
    private static let badRecordingLevel = "loud"

    /// A key that the `compaction` section does not decode.
    private static let unknownCompactionKey = "bogus"

    /// The reference name of the Tavily key.
    private static let referenceName = "tavily-api-key"

    /// The value that the secret store holds for ``referenceName``.
    private static let secretValue = "settings-store-secret-5e19c3"

    /// A user `config.yaml` with the Tavily key as a `keychain:` reference.
    private static let referenceYAML =
        "tools:\n  web:\n    apiKeys:\n      tavily: keychain:\(referenceName)\n"

    /// A user `config.yaml` that sets `compaction.trigger` to ``userTrigger``.
    private static let userTriggerYAML = "compaction:\n  trigger: \(userTrigger)\n"

    /// A session `config.yaml` that sets `compaction.trigger` to
    /// ``sessionTrigger``.
    private static let sessionTriggerYAML = "compaction:\n  trigger: \(sessionTrigger)\n"

    /// A session `config.yaml` that sets `compaction.trigger` to
    /// ``outsideTrigger``.
    private static let outsideTriggerYAML = "compaction:\n  trigger: \(outsideTrigger)\n"

    /// The environment variable that the template tests render. Each
    /// process environment has it.
    private static let templateVariable = "HOME"

    /// A template expression of ``templateVariable``.
    private static let templateExpression = "{{ \(templateVariable) }}"

    /// A user `config.yaml` whose Tavily key is a template expression.
    private static let expressionYAML =
        "tools:\n  web:\n    apiKeys:\n      tavily: \"\(templateExpression)\"\n"

    /// A user `config.yaml` that sets `compaction.trigger` inside a block tag.
    private static let blockYAML =
        "{% if \(templateVariable) %}\ncompaction:\n  trigger: \(userTrigger)\n{% endif %}\n"

    // MARK: - Fixture

    /// A store over a temporary root settings folder, and two temporary
    /// working directories.
    private struct Fixture {
        /// The settings folders of the store.
        let settingsFolders: SettingsFolders

        /// The store.
        let store: SettingsStore

        /// The working directory of the first session.
        let firstDirectory: URL

        /// The working directory of the second session.
        let secondDirectory: URL

        /// Makes the folders and the store.
        ///
        /// - Parameters:
        ///   - label: The prefix that names the test.
        ///   - secretStore: The secret store of the store.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        init(label: String, secretStore: InMemorySecretStore = InMemorySecretStore()) throws {
            settingsFolders = try SettingsFoldersFixture.make(label: "SettingsStoreTests-\(label)")
            store = SettingsStore(settingsFolders: settingsFolders, secretStore: secretStore)
            firstDirectory = makeResolvedDirectory(label: "SettingsStoreTests-\(label)-first")
            secondDirectory = makeResolvedDirectory(label: "SettingsStoreTests-\(label)-second")
        }

        /// The folder of the user level, from the settings folders.
        var userRoot: URL {
            get throws {
                try Self.root(of: .user, in: stack(for: firstDirectory))
            }
        }

        /// The folder of the session level of `workingDirectory`, from the
        /// settings folders.
        ///
        /// - Parameter workingDirectory: The working directory of the session.
        /// - Returns: The folder.
        /// - Throws: A failed requirement when the stack has no project layer.
        func sessionRoot(of workingDirectory: URL) throws -> URL {
            try Self.root(of: .project, in: stack(for: workingDirectory))
        }

        /// The configuration stack of `workingDirectory`.
        ///
        /// - Parameter workingDirectory: The working directory of the session.
        /// - Returns: The stack.
        private func stack(for workingDirectory: URL) -> DotfolderStack {
            settingsFolders.stack(for: .configuration, workingDirectory: workingDirectory)
        }

        /// The root of the layer of `source` in `stack`.
        ///
        /// - Parameters:
        ///   - source: The source of the layer.
        ///   - stack: The stack.
        /// - Returns: The root of the layer.
        /// - Throws: A failed requirement when the stack has no such layer.
        private static func root(of source: DotfolderStack.Source, in stack: DotfolderStack) throws -> URL {
            try #require(stack.layers.first { $0.source == source }).root
        }

        /// The `config.yaml` of the layer root `root`.
        ///
        /// - Parameter root: The layer root.
        /// - Returns: The file URL.
        static func configFile(in root: URL) -> URL {
            root.appendingPathComponent(ConfigurationLoader.configFileName)
        }

        /// The `compaction.trigger` of the merged settings of `workingDirectory`.
        ///
        /// - Parameter workingDirectory: The working directory of the session.
        /// - Returns: The value.
        /// - Throws: What the merge throws.
        func mergedTrigger(for workingDirectory: URL) async throws -> Double {
            try await store.merged(for: workingDirectory).configuration.compaction.trigger
        }

        /// The `compaction.trigger` that a fresh `ConfigurationLoader` reads
        /// from the files of `workingDirectory`.
        ///
        /// - Parameter workingDirectory: The working directory of the session.
        /// - Returns: The value.
        /// - Throws: What the load throws.
        func loadedTrigger(for workingDirectory: URL) throws -> Double {
            try ConfigurationLoader(
                settingsFolders: settingsFolders, workingDirectory: workingDirectory,
                secretStore: InMemorySecretStore()
            ).load().configuration.compaction.trigger
        }
    }

    // MARK: - set and clear

    /// A `set` on the user level changes the merged value for each working
    /// directory that does not set the key, and writes `<user>/config.yaml`.
    @Test func aUserSetChangesEachSessionAndWritesTheUserFile() async throws {
        let fixture = try Fixture(label: "user-set")

        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)

        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
        #expect(try await fixture.mergedTrigger(for: fixture.secondDirectory) == Self.userTrigger)
        let userFile = Fixture.configFile(in: try fixture.userRoot)
        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(try fixture.loadedTrigger(for: fixture.secondDirectory) == Self.userTrigger)
    }

    /// A `set` on a session level wins over the user level for that working
    /// directory only, and writes the `config.yaml` of that session folder.
    @Test func aSessionSetWinsForItsDirectoryOnly() async throws {
        let fixture = try Fixture(label: "session-set")
        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)

        try await fixture.store.set(
            .double(Self.sessionTrigger), at: Self.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.sessionTrigger)
        #expect(try await fixture.mergedTrigger(for: fixture.secondDirectory) == Self.userTrigger)
        let merged = try await fixture.store.merged(for: fixture.firstDirectory)
        #expect(merged.sources[Self.triggerSourceKey] == .project)
        let sessionFile = Fixture.configFile(in: try fixture.sessionRoot(of: fixture.firstDirectory))
        #expect(FileManager.default.fileExists(atPath: sessionFile.path))
        let otherFile = Fixture.configFile(in: try fixture.sessionRoot(of: fixture.secondDirectory))
        #expect(!FileManager.default.fileExists(atPath: otherFile.path))
        #expect(try fixture.loadedTrigger(for: fixture.firstDirectory) == Self.sessionTrigger)
    }

    /// A `clear` on the session level makes the user value apply again, in
    /// memory and in the files.
    @Test func aSessionClearRestoresTheUserValue() async throws {
        let fixture = try Fixture(label: "session-clear")
        let session = SettingsLevel.session(fixture.firstDirectory)
        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)
        try await fixture.store.set(.double(Self.sessionTrigger), at: Self.triggerKeyPath, level: session)

        try await fixture.store.clear(at: Self.triggerKeyPath, level: session)

        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
        let merged = try await fixture.store.merged(for: fixture.firstDirectory)
        #expect(merged.sources[Self.triggerSourceKey] == .user)
        #expect(try fixture.loadedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
    }

    /// A value that does not decode is refused, and the file and the merged
    /// value do not change.
    @Test func aChangeThatDoesNotDecodeIsRefused() async throws {
        let fixture = try Fixture(label: "refused")
        let userRoot = try fixture.userRoot
        try ConfigFileFixture.write(Self.userTriggerYAML, in: userRoot)

        await #expect(throws: YAMLValueDecodingError.self) {
            try await fixture.store.set(
                .string(Self.badRecordingLevel), at: Self.recordingLevelKeyPath, level: .user)
        }

        #expect(try textOnDisk(at: Fixture.configFile(in: userRoot)) == Self.userTriggerYAML)
        let merged = try await fixture.store.merged(for: fixture.firstDirectory)
        #expect(merged.configuration.recording.level == RecordingLevel.full)
    }

    /// A key that its section does not decode is refused with the schema
    /// error, and the file does not change.
    @Test func anUnknownKeyIsRefused() async throws {
        let fixture = try Fixture(label: "unknown-key")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)

        await #expect(throws: ConfigurationError.unknownKey(section: "compaction", key: Self.unknownCompactionKey)) {
            try await fixture.store.set(
                .bool(true), at: ["compaction", Self.unknownCompactionKey],
                level: .session(fixture.firstDirectory))
        }

        #expect(try textOnDisk(at: Fixture.configFile(in: sessionRoot)) == Self.sessionTriggerYAML)
    }

    /// A `keychain:` reference in a level file stays a reference after a
    /// flush, and the flush writes no value from the secret store.
    @Test func aFlushKeepsEachSecretReference() async throws {
        let fixture = try Fixture(
            label: "secret", secretStore: InMemorySecretStore([Self.referenceName: Self.secretValue]))
        let userRoot = try fixture.userRoot
        try ConfigFileFixture.write(Self.referenceYAML, in: userRoot)

        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)

        let text = try textOnDisk(at: Fixture.configFile(in: userRoot))
        #expect(text.contains("keychain:\(Self.referenceName)"))
        #expect(!text.contains(Self.secretValue))
        let merged = try await fixture.store.merged(for: fixture.firstDirectory)
        let options = try #require(merged.configuration.tools.web.mountedOptions)
        #expect(options.apiKeys[.tavily]?.reference == Self.referenceName)
    }

    /// A template expression on another key stays an expression after a
    /// flush, and the flush writes no rendered value of it.
    @Test func aFlushKeepsEachTemplateExpression() async throws {
        let renderedValue = try #require(ProcessInfo.processInfo.environment[Self.templateVariable])
        let fixture = try Fixture(label: "template")
        let userRoot = try fixture.userRoot
        try ConfigFileFixture.write(Self.expressionYAML, in: userRoot)

        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)

        let text = try textOnDisk(at: Fixture.configFile(in: userRoot))
        #expect(text.contains(Self.templateExpression))
        #expect(!text.contains(renderedValue))
        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
        #expect(try fixture.loadedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
    }

    /// A change of a level whose file holds a block tag is refused with an
    /// error that names the key path, because a write cannot keep the
    /// block, and the file does not change.
    @Test func aChangeUnderABlockTagIsRefused() async throws {
        let fixture = try Fixture(label: "block")
        let userRoot = try fixture.userRoot
        try ConfigFileFixture.write(Self.blockYAML, in: userRoot)

        await #expect(throws: SettingsTemplateError.unkeptTemplate(keyPath: Self.triggerSourceKey)) {
            try await fixture.store.set(.double(Self.sessionTrigger), at: Self.triggerKeyPath, level: .user)
        }

        #expect(try textOnDisk(at: Fixture.configFile(in: userRoot)) == Self.blockYAML)
        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.userTrigger)
    }

    // MARK: - value

    /// `value(at:cwd:)` gives the merged value of a key and the level that
    /// set it: the session level, the user level, or the builtin layer.
    @Test func aValueNamesTheLevelThatSetIt() async throws {
        let fixture = try Fixture(label: "value")
        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)
        try await fixture.store.set(
            .double(Self.sessionTrigger), at: Self.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        let sessionValue = try await fixture.store.value(at: Self.triggerKeyPath, cwd: fixture.firstDirectory)
        let userValue = try await fixture.store.value(at: Self.triggerKeyPath, cwd: fixture.secondDirectory)
        let builtinValue = try await fixture.store.value(at: Self.builtinKeyPath, cwd: fixture.firstDirectory)

        #expect(sessionValue == SettingsValue(value: .double(Self.sessionTrigger), level: .project))
        #expect(userValue == SettingsValue(value: .double(Self.userTrigger), level: .user))
        #expect(builtinValue == SettingsValue(value: .array([]), level: .builtin))
    }

    // MARK: - Changes

    /// A `set` sends one change that names its level and its key path.
    @Test(.timeLimit(.minutes(1))) func aSetSendsOneChange() async throws {
        let fixture = try Fixture(label: "set-change")
        var changes = await fixture.store.changes().makeAsyncIterator()

        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)

        #expect(await changes.next() == SettingsChange(level: .user, keyPath: Self.triggerKeyPath))
    }

    /// An outside write to a `config.yaml` that the store read updates the
    /// merged value and sends one change. The next change is the change of
    /// a later `set`, thus the outside write sent no second change.
    @Test(.timeLimit(.minutes(1))) func anOutsideWriteReloadsTheLevel() async throws {
        let fixture = try Fixture(label: "outside")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.sessionTrigger)
        var changes = await fixture.store.changes().makeAsyncIterator()

        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)

        let session = SettingsLevel.session(fixture.firstDirectory)
        #expect(await changes.next() == SettingsChange(level: session, keyPath: nil))
        #expect(try await fixture.mergedTrigger(for: fixture.firstDirectory) == Self.outsideTrigger)
        try await fixture.store.set(.double(Self.userTrigger), at: Self.triggerKeyPath, level: .user)
        #expect(await changes.next() == SettingsChange(level: .user, keyPath: Self.triggerKeyPath))
    }

    // MARK: - The level text

    /// The text of a level tree parses back to the same tree, for each kind
    /// of scalar, a list, a nested mapping, and a string with a line break.
    @Test func aLevelTextRoundTrips() throws {
        let tree = YAMLValue.dictionary([
            "section": .dictionary([
                "text": .string("first line\nsecond line\t\"quoted\" \\ end"),
                "reference": .string("keychain:\(Self.referenceName)"),
                "count": .int(3),
                "ratio": .double(Self.userTrigger),
                "enabled": .bool(true),
                "nothing": .null,
                "list": .array([.string("a"), .dictionary(["url": .string("https://example.com")])]),
                "empty": .dictionary([:]),
            ])
        ])

        let text = try ConfigurationYAML.levelText(of: tree)

        #expect(try YAMLValue.parse(text) == tree)
    }
}
