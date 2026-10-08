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
    /// - Throws: When the file does not load, or when its `tools:` value is
    ///   not a mapping.
    private static func toolBodies() throws -> [String: YAMLValue] {
        let root = try BuiltinConfigurationFile.root()
        guard case .dictionary(let sections) = root,
            case .dictionary(let tools)? = sections[AgentConfiguration.CodingKeys.tools.stringValue]
        else {
            Issue.record("the builtin file has no tools mapping: \(root)")
            return [:]
        }
        return tools
    }

    /// The keys of the body of one tool in the builtin file.
    ///
    /// - Parameter tool: The YAML spelling of the tool.
    /// - Returns: The keys, or an empty set when the body is not a mapping.
    /// - Throws: What ``toolBodies()`` throws.
    private static func bodyKeys(of tool: String) throws -> Set<String> {
        guard case .dictionary(let body)? = try toolBodies()[tool] else {
            return []
        }
        return Set(body.keys)
    }

    /// The value of one key of the body of one tool in the builtin file.
    ///
    /// - Parameters:
    ///   - key: The option key.
    ///   - tool: The YAML spelling of the tool.
    /// - Returns: The value, or `nil` when the file does not set it.
    /// - Throws: What ``toolBodies()`` throws.
    private static func value(of key: String, inTool tool: String) throws -> YAMLValue? {
        guard case .dictionary(let body)? = try toolBodies()[tool] else {
            return nil
        }
        return body[key]
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
            #expect(try Self.bodyKeys(of: tool) == optionKeys, "the keys of tools.\(tool) differ")
        }
    }

    /// Each tool body that takes `enabled:` sets it to `true`.
    @Test(arguments: [ToolsConfiguration.CodingKeys.web, .git])
    func eachSwitchableToolIsOnInTheFile(tool: ToolsConfiguration.CodingKeys) throws {
        let enabled = try Self.value(
            of: WebToolOptions.CodingKeys.enabled.stringValue, inTool: tool.stringValue)

        #expect(enabled == .bool(true))
    }

    /// The file holds no secret: the map of web API keys is empty.
    @Test func theFileHoldsNoSecret() throws {
        let apiKeys = try Self.value(
            of: WebToolOptions.CodingKeys.apiKeys.stringValue,
            inTool: ToolsConfiguration.CodingKeys.web.stringValue)

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
