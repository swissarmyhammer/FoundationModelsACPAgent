import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The builtin configuration file `builtin.config.yaml`: layer 1 of the
/// configuration stack, a resource of the library target.
///
/// The Swift defaults of ``AgentConfiguration`` stay as the decode fallback.
/// These tests make sure that the file and the code cannot be different: the
/// file decodes to exactly `AgentConfiguration()`, and it names each tool and
/// each option key of each tool. Thus a new tool or a new option fails a test
/// until the file names it.
@Suite struct BuiltinConfigurationFileTests {
    // MARK: - Helpers

    /// The body of each tool under `tools:` in the builtin file, by the YAML
    /// spelling of the tool.
    ///
    /// - Returns: The bodies.
    /// - Throws: When the file does not load. When the file or its `tools:`
    ///   value is not a mapping, `#require` records an issue and throws.
    private static func toolBodies() throws -> [String: YAMLValue] {
        let root = try BuiltinConfigurationFile.root()
        let sections = try #require(root.mapping, "the builtin file is not a mapping: \(root)")
        return try #require(
            sections[AgentConfiguration.CodingKeys.tools.stringValue]?.mapping,
            "the builtin file has no tools mapping: \(root)")
    }

    /// The mapping body of one tool in the builtin file.
    ///
    /// - Parameter tool: The YAML spelling of the tool.
    /// - Returns: The keys and values of the body.
    /// - Throws: What ``toolBodies()`` throws. When the file has no mapping
    ///   body for `tool`, `#require` records an issue and throws.
    private static func body(of tool: String) throws -> [String: YAMLValue] {
        try #require(toolBodies()[tool]?.mapping, "the builtin file has no mapping body for tools.\(tool)")
    }

    /// A loader over `fixture` that reads `builtinLayer` as layer 1 in place
    /// of the builtin file.
    ///
    /// - Parameters:
    ///   - fixture: The two-layer tree the loader reads.
    ///   - builtinLayer: The tree of layer 1.
    /// - Returns: The loader.
    /// - Throws: `DotfolderNameError`.
    private static func makeLoader(
        over fixture: ConfigurationLoaderTests.Fixture, builtinLayer: YAMLValue
    ) throws -> ConfigurationLoader {
        try ConfigurationLoader(
            name: DotfolderName(ConfigurationLoaderTests.agentName),
            workingDirectory: fixture.workingDirectory,
            userDirectory: fixture.userDirectory,
            environment: [:],
            builtinLayer: { builtinLayer })
    }

    /// The URL of a file that is not on disk, in a directory that is not on
    /// disk.
    ///
    /// - Returns: The URL.
    private static func absentFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltinConfigurationFileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(BuiltinConfigurationFile.fileName)
    }

    /// The reason the file system gives when it cannot read `url` as UTF-8
    /// text.
    ///
    /// - Parameter url: A file that cannot be read.
    /// - Returns: The localized description of the read error.
    /// - Throws: An issue and an error when the read does not fail.
    private static func fileSystemReason(forReading url: URL) throws -> String {
        try #require(throws: (any Error).self) {
            try String(contentsOf: url, encoding: .utf8)
        }.localizedDescription
    }

    /// A layer 1 tree that turns the web tool off.
    private static let webOffBuiltinLayer = YAMLValue.dictionary([
        AgentConfiguration.CodingKeys.tools.stringValue: .dictionary([
            ToolsConfiguration.CodingKeys.web.stringValue: .bool(false)
        ])
    ])

    // MARK: - The resource

    /// The file loads from the resource bundle of the library target.
    @Test func theFileLoadsFromTheResourceBundle() throws {
        let url = try BuiltinConfigurationFile.url()

        #expect(url.lastPathComponent == BuiltinConfigurationFile.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The public accessor of the loader gives the same file that layer 1
    /// reads, thus a report of the location names the file that loads.
    @Test func theLoaderGivesTheLocationOfTheFileThatLoads() throws {
        let url = try ConfigurationLoader.builtinConfigurationFileURL()

        #expect(url == (try BuiltinConfigurationFile.url()))
    }

    /// A file that cannot be read gives `unreadable` with the reason of the
    /// file system, not only the path.
    @Test func aFileThatCannotBeReadKeepsTheFileSystemReason() throws {
        let url = Self.absentFileURL()
        let reason = try Self.fileSystemReason(forReading: url)

        let error = try #require(throws: BuiltinConfigurationFileError.self) {
            try BuiltinConfigurationFile.root(at: url)
        }

        #expect(error == .unreadable(path: url.path, reason: reason))
    }

    /// The description of `unreadable` names the reason of the file system.
    @Test func theUnreadableDescriptionNamesTheReason() {
        let reason = "the disk is not available"

        let description = BuiltinConfigurationFileError.unreadable(path: "/builtin.config.yaml", reason: reason)
            .description

        #expect(description.contains(reason))
    }

    // MARK: - The file and the code are the same

    /// The file decodes to exactly the in-code defaults.
    @Test func theFileDecodesToTheInCodeDefaults() throws {
        let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

        #expect(decoded == AgentConfiguration())
    }

    /// The file names each tool of the roster under `tools:`.
    @Test func theFileNamesEachToolOfTheRoster() throws {
        let tools = try Self.toolBodies()

        for tool in ToolsConfiguration.CodingKeys.allCases {
            #expect(tools[tool.stringValue] != nil, "the file does not name tools.\(tool.stringValue)")
        }
    }

    /// The body of each mapping-bodied tool in the file names exactly the
    /// option keys of that tool.
    @Test func theFileNamesEachOptionKeyOfEachTool() throws {
        for (tool, optionKeys) in ToolsConfiguration.optionKeys {
            #expect(try Set(Self.body(of: tool).keys) == optionKeys, "the keys of tools.\(tool) differ")
        }
    }

    /// Each tool body that takes `enabled:` sets it to `true`.
    @Test(arguments: [ToolsConfiguration.CodingKeys.web, .git, .environment])
    func eachSwitchableToolIsOnInTheFile(tool: ToolsConfiguration.CodingKeys) throws {
        let enabled = try Self.body(of: tool.stringValue)[WebToolOptions.CodingKeys.enabled.stringValue]

        #expect(enabled == .bool(true))
    }

    /// The file holds no secret: the map of web API keys is empty.
    @Test func theFileHoldsNoSecret() throws {
        let apiKeys = try Self.body(of: ToolsConfiguration.CodingKeys.web.stringValue)[
            WebToolOptions.CodingKeys.apiKeys.stringValue]

        #expect(apiKeys == .dictionary([:]))
    }

    // MARK: - The file is layer 1

    /// A user layer that sets `web: false` over the builtin file turns web
    /// off, and each other tool stays on with its defaults.
    @Test func aUserWebFalseTurnsOnlyWebOff() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        fixture.writeConfig("tools:\n  web: false\n", in: fixture.userDirectory)
        let loader = try fixture.makeLoader()
        var expected = loader.builtinConfiguration.tools
        expected.web = .disabled

        let loaded = try loader.load()

        #expect(loaded.configuration.tools == expected)
    }

    /// The loader reads layer 1 when no layer holds a file. Layer 1 sets no
    /// source, thus each key reports the builtin layer.
    @Test func theLoaderReadsLayerOneWhenNoLayerHoldsAFile() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        let loader = try Self.makeLoader(over: fixture, builtinLayer: Self.webOffBuiltinLayer)

        let loaded = try loader.load()

        #expect(loaded.configuration.tools.web == .disabled)
        #expect(loaded.sources.isEmpty)
    }

    /// A dotfolder layer wins over layer 1, and the key reports that layer.
    @Test func aDotfolderLayerWinsOverLayerOne() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        fixture.writeConfig("tools:\n  web: true\n", in: fixture.userDirectory)
        let loader = try Self.makeLoader(over: fixture, builtinLayer: Self.webOffBuiltinLayer)

        let loaded = try loader.load()

        #expect(loaded.configuration.tools.web == .enabled(WebToolOptions()))
        #expect(loaded.sources["tools.web"] == .user)
    }
}

extension YAMLValue {
    /// The keys and values of this tree when it is a mapping, or `nil` when
    /// it is an other kind of value. A test unwraps it with `#require`.
    fileprivate var mapping: [String: YAMLValue]? {
        if case .dictionary(let mapping) = self {
            return mapping
        }
        return nil
    }
}
