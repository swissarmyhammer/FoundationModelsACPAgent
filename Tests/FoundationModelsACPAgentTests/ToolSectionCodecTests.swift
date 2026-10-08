import Foundation
import FoundationModelsACPAgent
import FoundationModelsSkills
import Testing

/// The `tools:` enable and disable codec (plan.md §11.2): the five-shape
/// matrix, the `mcp:` tri-state, and the key checks of each tool body.
/// Every test loads through a throwaway `ConfigurationLoaderTests.Fixture`,
/// so the codec is proved on the same path production uses.
@Suite struct ToolSectionCodecTests {
    /// The `tools.files.exclude` list a fixture loader gives when no layer
    /// sets the key: the dotfolder of the loader, `.<name>/`.
    private static let dotfolderExclude = [".\(ConfigurationLoaderTests.agentName)/"]

    /// The files options a fixture loader gives when no layer sets a files
    /// key: the flag defaults, and the dotfolder exclude list.
    private static let loadedFilesDefaults = FilesToolOptions(exclude: dotfolderExclude)

    // MARK: - The five shapes of §11.2

    /// Shape 1: with no `tools:` section, every built-in is on with its
    /// defaults, and MCP is on with no configured servers.
    @Test func noToolsSectionEnablesEveryToolWithDefaults() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "recording:\n  level: full\n")

        let tools = loaded.configuration.tools
        #expect(tools.files == .enabled(Self.loadedFilesDefaults))
        #expect(tools.shell == .enabled(ShellToolOptions()))
        #expect(tools.skills == .enabled(SkillsToolOptions()))
        #expect(tools.codeContext == .enabled(CodeContextToolOptions()))
        #expect(tools.mcp == .enabled(servers: []))
    }

    /// Shape 2: `tools:` present with a tool not mentioned keeps that tool
    /// on with its defaults.
    @Test func unmentionedToolStaysEnabledWithDefaults() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              files:
                readOnly: true
            """)

        #expect(loaded.configuration.tools.shell == .enabled(ShellToolOptions()))
        #expect(loaded.configuration.tools.skills == .enabled(SkillsToolOptions()))
    }

    /// Shape 3: `{}`, null and `true` each give on with defaults —
    /// explicit but redundant.
    @Test(arguments: ["shell: {}", "shell:", "shell: true"])
    func emptyNullAndTrueBodiesEnableWithDefaults(body: String) throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  \(body)\n")

        #expect(loaded.configuration.tools.shell == .enabled(ShellToolOptions()))
        #expect(loaded.warnings.isEmpty)
    }

    /// Shape 4: a mapping body decodes as the capability's own option type.
    @Test func mappingBodyDecodesAsTheOptionType() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              shell:
                storeDirectory: /var/shell
            """)

        let expected = ShellToolOptions(
            storeDirectory: URL(fileURLWithPath: "/var/shell", isDirectory: true))
        #expect(loaded.configuration.tools.shell == .enabled(expected))
    }

    /// Shape 5: a scalar `false` disables the tool, and the other tools
    /// stay on.
    @Test func scalarFalseDisablesOnlyThatTool() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  shell: false\n")

        #expect(loaded.configuration.tools.shell == .disabled)
        #expect(loaded.configuration.tools.files == .enabled(Self.loadedFilesDefaults))
        #expect(loaded.configuration.tools.skills == .enabled(SkillsToolOptions()))
        #expect(loaded.configuration.tools.mcp == .enabled(servers: []))
    }

    // MARK: - Option bodies

    /// The files body decodes each of the three flags the capability's
    /// builder call takes.
    @Test func filesBodyDecodesTheThreeFlags() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              files:
                readOnly: true
                allowSymlinks: true
                recordsChanges: true
            """)

        let expected = FilesToolOptions(
            readOnly: true, allowSymlinks: true, recordsChanges: true, exclude: Self.dotfolderExclude)
        #expect(loaded.configuration.tools.files == .enabled(expected))
    }

    // MARK: - The files exclude list

    /// With no `exclude:` key in the files body, the loaded options hold
    /// the default list: the dotfolder of the loader, so the search verbs
    /// skip the transcripts of the agent.
    @Test func anAbsentFilesExcludeGivesTheDotfolderDefault() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  files:\n    readOnly: true\n")

        let expected = FilesToolOptions(readOnly: true, exclude: Self.dotfolderExclude)
        #expect(loaded.configuration.tools.files == .enabled(expected))
    }

    /// An empty `exclude:` list turns the exclusion off: the loaded options
    /// hold no pattern, and the default does not come back.
    @Test func anEmptyFilesExcludeGivesNoExclude() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  files:\n    exclude: []\n")

        #expect(loaded.configuration.tools.files == .enabled(FilesToolOptions(exclude: [])))
    }

    /// A user `exclude:` list replaces the default: the loaded options hold
    /// the user patterns in document order, and not the dotfolder.
    @Test func aUserFilesExcludeReplacesTheDefault() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  files:\n    exclude:\n      - build/\n      - \"*.log\"\n")

        #expect(
            loaded.configuration.tools.files == .enabled(FilesToolOptions(exclude: ["build/", "*.log"])))
    }

    /// An unknown key inside a tool body is an error that names the dotted
    /// section and the key (plan.md §2.4).
    @Test func unknownKeyInsideAToolBodyIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "tools.shell", key: "storDirectory")) {
            try fixture.loadProjectConfig(
                """
                tools:
                  shell:
                    storDirectory: /var/shell
                """)
        }
    }

    /// The skills body decodes one key, so any other key in it is unknown.
    @Test func anUnknownKeyInTheSkillsBodyIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "tools.skills", key: "watch")) {
            try fixture.loadProjectConfig(
                """
                tools:
                  skills:
                    watch: true
                """)
        }
    }

    /// The skills body decodes the marketplace list, with the repository
    /// and the branch of each entry.
    @Test func skillsBodyDecodesTheMarketplaceList() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              skills:
                marketplaces:
                  - url: https://github.com/swissarmyhammer/skills.git
                    ref: code-context
            """)

        let expected = SkillsToolOptions(marketplaces: [
            MarketplaceSource("https://github.com/swissarmyhammer/skills.git", ref: "code-context")
        ])
        #expect(loaded.configuration.tools.skills == .enabled(expected))
    }

    /// The code context body decodes its two policies, and a scalar
    /// `false` disables the capability.
    @Test func codeContextBodyDecodesTheInstallPolicy() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        let configured = try fixture.loadProjectConfig(
            "tools:\n  codeContext:\n    autoInstall: false\n    semanticSearch: false\n")
        let disabled = try fixture.loadProjectConfig("tools:\n  codeContext: false\n")

        #expect(
            configured.configuration.tools.codeContext
                == .enabled(CodeContextToolOptions(autoInstall: false, semanticSearch: false)))
        #expect(disabled.configuration.tools.codeContext == .disabled)
    }

    /// An unknown tool section under `tools:` is a warning only, and the
    /// known tools still decode to their defaults.
    @Test func unknownToolSectionGivesAWarningOnly() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        let loaded = try fixture.loadProjectConfig(
            """
            tools:
              frobnicator:
                speed: 3
            """)

        #expect(loaded.warnings == [.unknownToolSection(name: "frobnicator")])
        #expect(loaded.warnings[0].description.contains("frobnicator"))
        #expect(loaded.configuration.tools == (try fixture.makeLoader().builtinConfiguration.tools))
    }

    // MARK: - The git section

    /// With no `git:` key, the git tools are on, with the defaults.
    @Test func noGitKeyEnablesTheGitTools() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "recording:\n  level: full\n")

        #expect(loaded.configuration.tools.git == .enabled(GitToolOptions()))
        #expect(loaded.configuration.tools.git.mountedOptions == GitToolOptions())
    }

    /// The scalar `git: false` and the body `enabled: false` each turn the
    /// git tools off.
    @Test(arguments: ["git: false", "git:\n    enabled: false"])
    func eachOffShapeMountsNoGitTools(body: String) throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig("tools:\n  \(body)\n")

        #expect(loaded.configuration.tools.git.mountedOptions == nil)
        #expect(loaded.warnings.isEmpty)
    }

    /// An unknown key in the git body is an error that names `tools.git`
    /// and the key, as in each other tool body.
    @Test func anUnknownKeyInTheGitBodyIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "tools.git", key: "verbs")) {
            try fixture.loadProjectConfig("tools:\n  git:\n    verbs: []\n")
        }
    }

    /// The document that `config init` writes holds `tools.git.enabled:
    /// true`, and it reads back to exactly the builtin configuration, with
    /// the git tools on.
    @Test func theConfigInitDocumentReadsBackWithTheGitToolsOn() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        let builtin = try fixture.makeLoader().builtinConfiguration

        let text = try ConfigurationYAML.documentText(for: builtin, secrets: .omitted)
        let loaded = try fixture.loadProjectConfig(text)

        #expect(text.contains("  git:\n    enabled: true\n"))
        #expect(loaded.configuration == builtin)
        #expect(loaded.configuration.tools.git.mountedOptions == GitToolOptions())
    }

    // MARK: - The mcp tri-state

    /// Omitted `mcp:` means MCP is on with no configured servers — the
    /// stock-config default that still accepts client-supplied servers.
    @Test func omittedMCPIsOnWithNoServers() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  files: {}\n")

        #expect(loaded.configuration.tools.mcp == .enabled(servers: []))
    }

    /// An `mcp:` list decodes its stdio and http server entries, keeping
    /// the document order.
    @Test func mcpListDecodesTheServersInOrder() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              mcp:
                - name: github
                  command: /usr/local/bin/github-mcp
                  args:
                    - --verbose
                  env:
                    TOKEN: hunter2
                - name: docs
                  url: https://example.com/mcp
                  headers:
                    Authorization: Bearer sesame
            """)

        let expected = MCPToolSection.enabled(servers: [
            MCPServerConfiguration(
                name: "github",
                transport: .stdio(
                    command: "/usr/local/bin/github-mcp",
                    args: ["--verbose"],
                    env: ["TOKEN": "hunter2"])),
            MCPServerConfiguration(
                name: "docs",
                transport: .http(
                    url: "https://example.com/mcp",
                    headers: ["Authorization": "Bearer sesame"])),
        ])
        #expect(loaded.configuration.tools.mcp == expected)
    }

    /// `mcp: false` is fully off, and that state differs from an empty
    /// server list: the off state also refuses client-supplied servers.
    @Test func mcpFalseIsFullyOff() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  mcp: false\n")

        #expect(loaded.configuration.tools.mcp == .disabled)
        #expect(MCPToolSection.disabled != MCPToolSection.enabled(servers: []))
    }

    /// An unknown key inside an mcp server entry is an error that names
    /// `tools.mcp` and the key.
    @Test func unknownKeyInAServerEntryIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "tools.mcp", key: "stray")) {
            try fixture.loadProjectConfig(
                """
                tools:
                  mcp:
                    - name: github
                      command: /usr/local/bin/github-mcp
                      stray: 1
                """)
        }
    }

    /// A server entry names exactly one transport: both `command` and `url`,
    /// or neither, is an error whose message names the two keys.
    @Test(arguments: [
        "- name: both\n      command: /usr/bin/one\n      url: https://example.com/mcp",
        "- name: neither",
    ])
    func serverEntryRequiresExactlyOneTransport(entry: String) throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        let error = #expect(throws: (any Error).self) {
            try fixture.loadProjectConfig("tools:\n  mcp:\n    \(entry)\n")
        }

        let message = String(describing: error)
        #expect(message.contains("command"))
        #expect(message.contains("url"))
    }

    // MARK: - Encoding

    /// The codec encodes what it decodes: a disabled tool, an option body
    /// and a server list survive a round trip through `Codable`.
    @Test func codecRoundTripsThroughCodable() throws {
        var tools = ToolsConfiguration()
        tools.shell = .disabled
        tools.files = .enabled(FilesToolOptions(readOnly: true, exclude: ["build/"]))
        tools.mcp = .enabled(servers: [
            MCPServerConfiguration(
                name: "github",
                transport: .stdio(command: "/usr/local/bin/github-mcp", args: [], env: [:]))
        ])

        let encoded = try JSONEncoder().encode(tools)
        let decoded = try JSONDecoder().decode(ToolsConfiguration.self, from: encoded)

        #expect(decoded == tools)
    }
}
