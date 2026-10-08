import Foundation
import FoundationModelsExtras
import FoundationModelsSkills

// MARK: - The per-tool codec

/// The option type of one mapping-bodied `tools:` entry (plan.md §11.2).
/// The body is the tool package's own option type — there is no `enabled:`
/// key, because `false` sits outside the body — and `init()` is the
/// defaults an enabling shape (`absent`, `{}`, null, `true`) gives. The
/// exceptions are the ``SwitchableToolOptions`` bodies, which also take
/// `enabled:`.
public protocol ToolSectionOptions: Codable, Equatable, Sendable {
    /// The defaults the tool gets when the config enables it without a body.
    init()
}

/// The option type of a tool body that also takes `enabled:`, so that a
/// config can say `tools.<name>.enabled: false` beside the scalar
/// `<name>: false` of the shared codec. ``WebToolOptions`` and
/// ``GitToolOptions`` are these bodies.
public protocol SwitchableToolOptions: ToolSectionOptions {
    /// Whether the capability mounts.
    var enabled: Bool { get }
}

extension SingleValueDecodingContainer {
    /// The §11.2 scalar probe: the codec first checks for a scalar boolean,
    /// then decodes the body. `nil` means the value is not a boolean.
    var scalarBooleanFlag: Bool? {
        try? decode(Bool.self)
    }
}

/// One tool's decoded `tools:` entry (plan.md §11.2). One rule, five
/// shapes: an absent key, `{}`, null and `true` each give `.enabled` with
/// the option defaults; a mapping body gives `.enabled` with the decoded
/// options; and a scalar `false` gives `.disabled`. Absent and null decode
/// at the section level through `decodeIfPresent`, so this codec sees the
/// other three shapes.
public enum ToolSection<Options: ToolSectionOptions>: Codable, Equatable, Sendable {
    /// The tool is off: it is not constructed and never reaches the model.
    case disabled

    /// The tool is on, with these options.
    case enabled(Options)

    /// Decodes the scalar boolean first, then the mapping body.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = container.scalarBooleanFlag {
            self = flag ? .enabled(Options()) : .disabled
            return
        }
        self = .enabled(try container.decode(Options.self))
    }

    /// Encodes `false` for `.disabled` and the option body for `.enabled`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .disabled:
            try container.encode(false)
        case .enabled(let options):
            try container.encode(options)
        }
    }
}

// MARK: - The option bodies

/// The `tools.files:` body — the three flags and the exclude list of
/// `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:excludePatterns:)`
/// that config may set (plan.md §11.3). The root set is session state, not
/// config, so it is not here.
///
/// ```yaml
/// tools:
///   files:
///     exclude:
///       - .acp-agent/
///       - build/
/// ```
public struct FilesToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// Whether the writing verbs are refused.
    public var readOnly: Bool

    /// Whether a path may traverse a symbolic link.
    public var allowSymlinks: Bool

    /// Whether each change is recorded for the session.
    public var recordsChanges: Bool

    /// The exclude patterns, in gitignore syntax, that the search verbs of
    /// the files capability (`files.grep`, `files.glob` and each other verb
    /// that walks a tree) skip. A read or a write of an explicit path does
    /// not change, and a call that sets `respectGitIgnore: false` does not
    /// turn these patterns off.
    ///
    /// `nil` means that no layer set the key. ``ConfigurationLoader`` then
    /// puts in ``defaultExclude(dotfolderName:)``, thus a loaded
    /// configuration holds the list in effect. A list replaces the default,
    /// and an empty list turns the exclusion off. A configuration that does
    /// not come from the loader and keeps `nil` excludes no path.
    public var exclude: [String]?

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case readOnly, allowSymlinks, recordsChanges, exclude
    }

    /// Makes options; each omitted flag keeps the builder call's default,
    /// which is `false`, and an omitted exclude list is `nil`.
    public init(
        readOnly: Bool = false, allowSymlinks: Bool = false, recordsChanges: Bool = false,
        exclude: [String]? = nil
    ) {
        self.readOnly = readOnly
        self.allowSymlinks = allowSymlinks
        self.recordsChanges = recordsChanges
        self.exclude = exclude
    }

    /// The defaults: writable, no symlink traversal, no change recording,
    /// and no exclude list set.
    public init() {
        self.init(readOnly: false)
    }

    /// Decodes each present key and keeps the default for each absent one.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? readOnly
        allowSymlinks =
            try container.decodeIfPresent(Bool.self, forKey: .allowSymlinks) ?? allowSymlinks
        recordsChanges =
            try container.decodeIfPresent(Bool.self, forKey: .recordsChanges) ?? recordsChanges
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude)
    }

    /// The default exclude list of a host whose dotfolder is `.<name>/`:
    /// the dotfolder itself, which holds the transcripts of the agent. The
    /// search verbs then do not give the agent its own earlier output as a
    /// search result.
    ///
    /// - Parameter name: The dotfolder name of the host, such as
    ///   `acp-agent`.
    /// - Returns: The one gitignore pattern `.<name>/`.
    public static func defaultExclude(dotfolderName name: DotfolderName) -> [String] {
        [".\(name.rawValue)/"]
    }
}

/// The `tools.shell:` body — the one option of
/// `withShell(storeDirectory:sandbox:outputChunkStream:)` that config may
/// set (plan.md §11.3). The sandbox comes from the `sandbox:` section
/// (§11.7) and the chunk stream is runtime wiring, so neither is here.
public struct ShellToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// Where the shell capability stores command output, or `nil` for the
    /// capability's own default location.
    public var storeDirectory: URL?

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case storeDirectory
    }

    /// Makes options with the store directory stated.
    public init(storeDirectory: URL?) {
        self.storeDirectory = storeDirectory
    }

    /// The default: the capability's own store location.
    public init() {
        self.init(storeDirectory: nil)
    }

    /// Decodes `storeDirectory` from a path string when present.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeDirectory = try container.decodeIfPresent(String.self, forKey: .storeDirectory)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Encodes the same path string `init(from:)` reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(storeDirectory?.path, forKey: .storeDirectory)
    }
}

/// The `tools.skills:` body. The skills package reads its own dotfolder
/// stack (plan.md §14.2), so the one option is the list of remote skill
/// marketplaces. Each entry is a `MarketplaceSource` of the skills package:
/// `url` is necessary, and `ref`, `sha`, `path`, `alias`, `select`,
/// `autoUpdate` and `grants` are optional. The marketplace layers are below
/// the full local stack, and the last entry wins over the entries before it.
///
/// ```yaml
/// tools:
///   skills:
///     marketplaces:
///       - url: https://github.com/swissarmyhammer/skills.git
///         ref: code-context
/// ```
public struct SkillsToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// The remote skill marketplaces, in document order.
    public var marketplaces: [MarketplaceSource]

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case marketplaces
    }

    /// Makes options with the marketplace list stated.
    public init(marketplaces: [MarketplaceSource]) {
        self.marketplaces = marketplaces
    }

    /// The default: no marketplace, thus the local dotfolder stack alone.
    public init() {
        self.init(marketplaces: [])
    }

    /// Decodes `marketplaces` when present and keeps the empty default
    /// when absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marketplaces =
            try container.decodeIfPresent([MarketplaceSource].self, forKey: .marketplaces) ?? []
    }
}

/// The `tools.codeContext:` body. The workspace root is the session working
/// directory and the embedder is the profile's embedding slot, so neither is
/// here.
public struct CodeContextToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// Whether a language server that is not installed is installed
    /// automatically.
    public var autoInstall: Bool

    /// Whether the index embeds each chunk with the profile's embedding
    /// slot, which is what the `searchCode` verb ranks with. The embedding
    /// pass of a large repository is long, and it uses the same GPU as the
    /// model. With `false`, the context gets no embedder, so the index calls
    /// no model: each other verb works, and `searchCode` answers with an
    /// error that says the embedding layer is off.
    public var semanticSearch: Bool

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case autoInstall, semanticSearch
    }

    /// Makes options with each policy stated.
    public init(autoInstall: Bool = true, semanticSearch: Bool = true) {
        self.autoInstall = autoInstall
        self.semanticSearch = semanticSearch
    }

    /// The defaults: automatic install is on, as in the code context
    /// package, and semantic search is on.
    public init() {
        self.init(autoInstall: true)
    }

    /// Decodes each present key and keeps the default for each absent one.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoInstall = try container.decodeIfPresent(Bool.self, forKey: .autoInstall) ?? autoInstall
        semanticSearch =
            try container.decodeIfPresent(Bool.self, forKey: .semanticSearch) ?? semanticSearch
    }
}

/// The name of one key of the `tools.web.apiKeys` map. Each name selects one
/// keyed search provider of the Multitool web capability (task ^ba231ka).
///
/// The cases are in the order of the Multitool provider table. The agent
/// does not set the provider order: a key only adds its provider, and
/// Multitool puts the providers in its table order.
public enum WebAPIKeyName: String, CaseIterable, Hashable, Sendable {
    /// The Brave Search API.
    case brave
    /// The Tavily search API.
    case tavily
    /// The Exa search API.
    case exa
    /// The Serper search API.
    case serper
    /// The Kagi search API.
    case kagi
    /// The base URL of a SearXNG instance that the user runs. It is not a
    /// key, but it selects a provider in the same way.
    case searxngURL

    /// The environment variable that Multitool reads for this provider. A
    /// configured value is put into the environment under this name, and it
    /// wins over the process environment.
    public var environmentVariable: String {
        switch self {
        case .brave: "BRAVE_SEARCH_API_KEY"
        case .searxngURL: "SEARXNG_URL"
        case .tavily, .exa, .serper, .kagi: rawValue.uppercased() + "_API_KEY"
        }
    }

    /// Each valid key name, in the provider table order. An error that
    /// refuses an unknown name lists them.
    public static var validNames: [String] {
        allCases.map(\.rawValue)
    }
}

/// The `tools.web:` body (task ^ba231ka): whether the web capability mounts,
/// and the API keys that select keyed search providers.
///
/// ```yaml
/// tools:
///   web:
///     enabled: true
///     apiKeys:
///       tavily: tvly-...
/// ```
///
/// The web body has an `enabled:` key, so that a config can say
/// `tools.web.enabled: false`. The scalar `web: false` of the shared codec
/// turns the tool off too.
///
/// No form of this type shows a key value: each key is a
/// ``ConfiguredSecret``. An encoder that sets
/// ``Swift/CodingUserInfoKey/omitsConfiguredSecrets`` gets an empty
/// `apiKeys` map.
public struct WebToolOptions: SwitchableToolOptions, KeyCheckedSection {
    /// Whether the web capability mounts.
    public var enabled: Bool

    /// The configured API keys, by provider key name.
    public var apiKeys: [WebAPIKeyName: ConfiguredSecret]

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, apiKeys
    }

    /// Makes options.
    ///
    /// - Parameters:
    ///   - enabled: Whether the web capability mounts. The default is `true`.
    ///   - apiKeys: The configured API keys. The default is none, thus the
    ///     keys come from the process environment alone.
    public init(enabled: Bool = true, apiKeys: [WebAPIKeyName: ConfiguredSecret] = [:]) {
        self.enabled = enabled
        self.apiKeys = apiKeys
    }

    /// The defaults: on, with no configured key.
    public init() {
        self.init(enabled: true)
    }

    /// Decodes each present key and keeps the default for each absent one.
    /// A key name of `apiKeys` that is not a ``WebAPIKeyName`` is an error
    /// that names the valid names.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        let named =
            try container.decodeIfPresent([String: ConfiguredSecret].self, forKey: .apiKeys) ?? [:]
        apiKeys = try Dictionary(
            uniqueKeysWithValues: named.map { name, secret in
                guard let keyName = WebAPIKeyName(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .apiKeys, in: container,
                        debugDescription: ConfigurationError.unknownMapKey(
                            section: Self.apiKeysSection, key: name, validKeys: WebAPIKeyName.validNames
                        ).description)
                }
                return (keyName, secret)
            })
    }

    /// Encodes `enabled`, and each key name with the redacted form of its
    /// value. With ``Swift/CodingUserInfoKey/omitsConfiguredSecrets`` set,
    /// the `apiKeys` map is empty.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        let written = encoder.omitsConfiguredSecrets ? [:] : apiKeys
        try container.encode(
            Dictionary(uniqueKeysWithValues: written.map { ($0.key.rawValue, $0.value) }),
            forKey: .apiKeys)
    }

    /// The dotted section of the `apiKeys` map, such as an error names.
    static var apiKeysSection: String {
        ToolsConfiguration.dottedSection(ToolsConfiguration.CodingKeys.web.stringValue)
            + LoadedConfiguration.keyPathSeparator + CodingKeys.apiKeys.stringValue
    }

    /// The process environment with each configured key put in under the
    /// variable of its provider. A configured key wins over the process
    /// environment for the same variable.
    ///
    /// - Parameter processEnvironment: The environment of the process.
    /// - Returns: The environment that the web capability reads its keys
    ///   from.
    public func environment(mergedOver processEnvironment: [String: String]) -> [String: String] {
        processEnvironment.merging(
            apiKeys.map { ($0.key.environmentVariable, $0.value.value) }
        ) { _, configured in configured }
    }
}

extension WebToolOptions: CustomStringConvertible {
    /// Whether the tool is on, and the configured key names. It never
    /// shows a key value.
    public var description: String {
        let names = WebAPIKeyName.allCases.filter { apiKeys[$0] != nil }.map(\.rawValue)
        return "WebToolOptions(enabled: \(enabled), apiKeys: [\(names.joined(separator: ", "))])"
    }
}

extension ToolSection where Options: SwitchableToolOptions {
    /// The options of a section that mounts the capability, or `nil` when
    /// the section is off by either shape: the scalar `<name>: false`, or
    /// the body `<name>: {enabled: false}`.
    public var mountedOptions: Options? {
        guard case .enabled(let options) = self, options.enabled else {
            return nil
        }
        return options
    }
}

/// The `tools.git:` body: whether the git capability mounts.
///
/// ```yaml
/// tools:
///   git:
///     enabled: true
/// ```
///
/// The git verbs — `tools.git.blame`, `show`, `log`, `commit`, `status`,
/// `branches`, `changes` and `diff` — only read the repository, thus the
/// capability is on by default. Its root is the session working directory,
/// so the section has no root key. The scalar `git: false` of the shared
/// codec turns the tool off too.
public struct GitToolOptions: SwitchableToolOptions, KeyCheckedSection {
    /// Whether the git capability mounts.
    public var enabled: Bool

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
    }

    /// Makes options.
    ///
    /// - Parameter enabled: Whether the git capability mounts. The default
    ///   is `true`.
    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// The defaults: on.
    public init() {
        self.init(enabled: true)
    }

    /// Decodes `enabled` when present, and keeps the default when absent.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    }
}

// MARK: - The mcp entry

/// One config-derived MCP server entry (plan.md §7.3, §11.5): a name and
/// exactly one transport. `env` and `headers` are YAML mappings here; the
/// MCP composition changes them into the wire's `{name, value}` pairs.
public struct MCPServerConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// How a server is reached (plan.md §11.5). There are two transports:
    /// stdio and http. v2 removed `sse`, and the ACP tunnel is
    /// unstable-schema only.
    public enum Transport: Equatable, Sendable {
        /// A spawned subprocess speaking stdio. The command must be an
        /// absolute path; the MCP composition enforces that at spawn, and
        /// `env` layers onto the inherited environment.
        case stdio(command: String, args: [String], env: [String: String])

        /// A remote endpoint speaking http, with the headers carrying any
        /// authorization.
        case http(url: String, headers: [String: String])
    }

    /// The server's name — the noun its tools mount under, as
    /// `tools.<name>.<verb>`.
    public var name: String

    /// How the server is reached.
    public var transport: Transport

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name, command, args, env, url, headers
    }

    /// Makes a server entry.
    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    /// Decodes the entry. Exactly one of `command` and `url` picks the
    /// transport, and each remaining key must belong to that transport.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        let url = try container.decodeIfPresent(String.self, forKey: .url)
        switch (command, url) {
        case (let command?, nil):
            try Self.check(container, excludes: .headers, forTransport: "command")
            transport = .stdio(
                command: command,
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:])
        case (nil, let url?):
            try Self.check(container, excludes: .args, forTransport: "url")
            try Self.check(container, excludes: .env, forTransport: "url")
            transport = .http(
                url: url,
                headers: try container.decodeIfPresent([String: String].self, forKey: .headers)
                    ?? [:])
        case (nil, nil), (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container,
                debugDescription:
                    "mcp server \"\(name)\" must set exactly one of command (stdio) and url (http)")
        }
    }

    /// Encodes the same keys `init(from:)` reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch transport {
        case .stdio(let command, let args, let env):
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(env, forKey: .env)
        case .http(let url, let headers):
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        }
    }

    /// Throws when `key` is present although it belongs to the other
    /// transport than the one `transportKey` picked.
    private static func check(
        _ container: KeyedDecodingContainer<CodingKeys>, excludes key: CodingKeys,
        forTransport transportKey: String
    ) throws {
        if container.contains(key) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription:
                    "mcp server key \"\(key.stringValue)\" does not apply to a \(transportKey) server")
        }
    }
}

/// The `mcp:` entry — the one tool section whose body is a list (servers,
/// not options; plan.md §11.2). The three states: omitted means on with no
/// configured servers (the client's per-session `mcpServers` still
/// connect), a list means those servers plus the client's, and a scalar
/// `false` means fully off — the MCP composition then also refuses
/// client-supplied servers and logs the refusal.
public enum MCPToolSection: Codable, Equatable, Sendable {
    /// MCP is fully off, and client-supplied servers are refused too. This
    /// differs from `.enabled(servers: [])`, which still accepts them.
    case disabled

    /// MCP is on with these config-derived servers, in document order.
    case enabled(servers: [MCPServerConfiguration])

    /// Decodes the scalar boolean first, then the server list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = container.scalarBooleanFlag {
            self = flag ? .enabled(servers: []) : .disabled
            return
        }
        self = .enabled(servers: try container.decode([MCPServerConfiguration].self))
    }

    /// Encodes `false` for `.disabled` and the server list for `.enabled`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .disabled:
            try container.encode(false)
        case .enabled(let servers):
            try container.encode(servers)
        }
    }
}

// MARK: - The tools section

/// The `tools:` section (plan.md §11.2): the roster of built-in
/// capabilities, each on unless the config sets it off. Absence enables —
/// a user with no config gets every capability with its defaults — and
/// disabling is per tool: there is no `tools: false` switch and no `only:`
/// allowlist.
public struct ToolsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// The files capability's entry.
    public var files = ToolSection<FilesToolOptions>.enabled(FilesToolOptions())

    /// The shell capability's entry.
    public var shell = ToolSection<ShellToolOptions>.enabled(ShellToolOptions())

    /// The skills tool's entry.
    public var skills = ToolSection<SkillsToolOptions>.enabled(SkillsToolOptions())

    /// The code context capability's entry.
    public var codeContext = ToolSection<CodeContextToolOptions>.enabled(CodeContextToolOptions())

    /// The web capability's entry: `tools.web.search` and
    /// `tools.web.fetch`, with the keyless providers when no key is set.
    public var web = ToolSection<WebToolOptions>.enabled(WebToolOptions())

    /// The git capability's entry: the read-only `tools.git` verbs over the
    /// session working directory.
    public var git = ToolSection<GitToolOptions>.enabled(GitToolOptions())

    /// The mcp entry — the one list-bodied section.
    public var mcp = MCPToolSection.enabled(servers: [])

    /// The YAML spelling of each tool key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case files, shell, skills, codeContext, web, git, mcp
    }

    /// The default roster: every built-in on, with its defaults.
    public init() {}

    /// Decodes each named tool and keeps the enabled default for each
    /// absent or null one. A key that names no tool is not read here: the
    /// loader reports it as a warning before the decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files =
            try container.decodeIfPresent(ToolSection<FilesToolOptions>.self, forKey: .files)
            ?? files
        shell =
            try container.decodeIfPresent(ToolSection<ShellToolOptions>.self, forKey: .shell)
            ?? shell
        skills =
            try container.decodeIfPresent(ToolSection<SkillsToolOptions>.self, forKey: .skills)
            ?? skills
        codeContext =
            try container.decodeIfPresent(
                ToolSection<CodeContextToolOptions>.self, forKey: .codeContext)
            ?? codeContext
        web = try container.decodeIfPresent(ToolSection<WebToolOptions>.self, forKey: .web) ?? web
        git = try container.decodeIfPresent(ToolSection<GitToolOptions>.self, forKey: .git) ?? git
        mcp = try container.decodeIfPresent(MCPToolSection.self, forKey: .mcp) ?? mcp
    }
}

extension ToolsConfiguration {
    /// The known body keys of each mapping-bodied tool, by the tool's YAML
    /// spelling. `mcp` is not here: its body is a list of server entries,
    /// each checked against `MCPServerConfiguration.knownKeys`. The tests of
    /// ``BuiltinConfigurationFile`` read it to make sure that the builtin
    /// file names each key.
    static let optionKeys: [String: Set<String>] = [
        CodingKeys.files.stringValue: FilesToolOptions.knownKeys,
        CodingKeys.shell.stringValue: ShellToolOptions.knownKeys,
        CodingKeys.skills.stringValue: SkillsToolOptions.knownKeys,
        CodingKeys.codeContext.stringValue: CodeContextToolOptions.knownKeys,
        CodingKeys.web.stringValue: WebToolOptions.knownKeys,
        CodingKeys.git.stringValue: GitToolOptions.knownKeys,
    ]

    /// The key checks of the `tools:` body (plan.md §11.2), run by the
    /// loader before the decode.
    ///
    /// - Returns: One warning per unknown tool key, in key order — an
    ///   unknown tool section is a warning only, unlike an unknown key in
    ///   a checked section.
    /// - Throws: `ConfigurationError.unknownKey` for a key a known tool
    ///   body does not decode, named with the dotted section, such as
    ///   `tools.shell`.
    static func schemaWarnings(inBody body: YAMLValue) throws -> [ConfigurationWarning] {
        guard case .dictionary(let sections) = body else {
            return []
        }
        return try sections.sorted { $0.key < $1.key }.compactMap { section in
            try schemaWarning(forTool: section.key, body: section.value)
        }
    }

    /// The warning one tool entry gives, after its body keys pass.
    ///
    /// - Returns: The unknown-tool-section warning when no roster entry has
    ///   this name; `nil` when the tool is known and its body keys pass.
    /// - Throws: `ConfigurationError.unknownKey` for the first key, in key
    ///   order, that the tool's body does not decode.
    private static func schemaWarning(forTool name: String, body: YAMLValue) throws
        -> ConfigurationWarning?
    {
        if name == CodingKeys.mcp.stringValue {
            try checkServerEntryKeys(inBody: body)
            return nil
        }
        guard let bodyKeys = optionKeys[name] else {
            return .unknownToolSection(name: name)
        }
        try ConfigurationError.checkKeys(
            of: body, against: bodyKeys, section: dottedSection(name))
        if name == CodingKeys.web.stringValue {
            try checkAPIKeyNames(inBody: body)
        }
        return nil
    }

    /// Checks each key of the `apiKeys` map of a `web:` body against the
    /// provider key names. A body or a map that is not a mapping has no
    /// keys to check: the decode reports its shape error.
    ///
    /// - Parameter body: The `web:` body.
    /// - Throws: `ConfigurationError.unknownMapKey` for the first key, in
    ///   key order, that names no provider. The error lists the valid names.
    private static func checkAPIKeyNames(inBody body: YAMLValue) throws {
        guard case .dictionary(let keys) = body,
            case .dictionary(let names)? = keys[WebToolOptions.CodingKeys.apiKeys.stringValue]
        else {
            return
        }
        let unknown = names.keys.sorted().first { WebAPIKeyName(rawValue: $0) == nil }
        if let unknown {
            throw ConfigurationError.unknownMapKey(
                section: WebToolOptions.apiKeysSection, key: unknown,
                validKeys: WebAPIKeyName.validNames)
        }
    }

    /// Checks each mapping entry of an `mcp:` server list against the
    /// server entry's known keys. A body that is not a list, and an entry
    /// that is not a mapping, has no keys to check: the decode reports its
    /// shape error.
    private static func checkServerEntryKeys(inBody body: YAMLValue) throws {
        guard case .array(let entries) = body else {
            return
        }
        for entry in entries {
            try ConfigurationError.checkKeys(
                of: entry, against: MCPServerConfiguration.knownKeys,
                section: dottedSection(CodingKeys.mcp.stringValue))
        }
    }

    /// The dotted section name of one tool, such as `tools.shell`. An error
    /// inside a tool body carries it, and so does the log record of an
    /// unknown tool section.
    ///
    /// - Parameter name: The key of the tool under `tools:`.
    /// - Returns: The key path of the tool section.
    static func dottedSection(_ name: String) -> String {
        "\(AgentConfiguration.CodingKeys.tools.stringValue).\(name)"
    }

    /// The roster with each default that the dotfolder name gives: an
    /// enabled files section with no exclude list gets
    /// ``FilesToolOptions/defaultExclude(dotfolderName:)``. A set list, an
    /// empty list included, and a disabled files section do not change.
    ///
    /// - Parameter name: The dotfolder name of the loader.
    /// - Returns: The roster with the defaults put in.
    func resolvingDotfolderDefaults(_ name: DotfolderName) -> ToolsConfiguration {
        guard case .enabled(var options) = files, options.exclude == nil else {
            return self
        }
        options.exclude = FilesToolOptions.defaultExclude(dotfolderName: name)
        var resolved = self
        resolved.files = .enabled(options)
        return resolved
    }
}
