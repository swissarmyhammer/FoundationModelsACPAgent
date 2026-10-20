import Foundation
import FoundationModelsExtras
import FoundationModelsSkills

// MARK: - The per-tool codec

/// The option type of one mapping-bodied `tools:` entry.
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
/// ``SwitchOnlyToolOptions`` are these bodies.
public protocol SwitchableToolOptions: ToolSectionOptions {
    /// Whether the capability mounts.
    var enabled: Bool { get }
}

extension SingleValueDecodingContainer {
    /// The scalar probe of a `tools:` entry: the codec first checks for a
    /// scalar boolean,
    /// then decodes the body. `nil` means the value is not a boolean.
    var scalarBooleanFlag: Bool? {
        try? decode(Bool.self)
    }
}

/// One tool's decoded `tools:` entry. One rule, five
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

/// The decode of one `tools:` entry for a tool that is always on, such as
/// the skills tool. The config cannot turn the tool off (the user decided
/// this on 2026-10-19): each scalar boolean, `{}` and null give the option
/// defaults, and a mapping body gives the decoded options. The loader gives
/// a ``ConfigurationWarning/cannotDisable(section:)`` for a scalar `false`.
struct AlwaysOnToolSection<Options: ToolSectionOptions>: Decodable {
    /// The options of the tool.
    let options: Options

    /// Decodes the scalar boolean first, then the mapping body.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.scalarBooleanFlag == nil else {
            options = Options()
            return
        }
        options = try container.decode(Options.self)
    }
}

// MARK: - The option bodies

/// The `tools.files:` body — the three flags and the exclude list of
/// `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:excludePatterns:)`
/// that config may set. The root set is session state, not
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
/// set. The sandbox comes from the `sandbox:` section and the chunk stream
/// is runtime wiring, so neither is here.
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
/// stack, so the one option is the list of remote skill
/// marketplaces. Each entry is a `MarketplaceSource` of the skills package:
/// `url` is necessary, and `ref`, `sha`, `path`, `alias`, `select`,
/// `autoUpdate` and `grants` are optional. The marketplace layers are below
/// the full local stack, and the last entry wins over the entries before it.
///
/// The default list has one marketplace: ``defaultMarketplaceURL`` on the
/// branch ``defaultMarketplaceRef``. The agent registry reads the same list,
/// thus this marketplace also gives the marketplace agents. An empty list
/// turns the marketplaces off.
///
/// The skills tool is always on. The scalar `skills: false` does not turn
/// it off: the loader gives a warning, and the options are the defaults.
///
/// ```yaml
/// tools:
///   skills:
///     marketplaces:
///       - url: https://github.com/swissarmyhammer/skills.git
///         ref: main
/// ```
public struct SkillsToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// The repository of the default marketplace. It is the HTTPS form: a
    /// marketplace URL is HTTPS only, and this public repository needs no
    /// credential.
    public static let defaultMarketplaceURL = "https://github.com/swissarmyhammer/skills.git"

    /// The branch of the default marketplace.
    public static let defaultMarketplaceRef = "main"

    /// The default marketplace list: the one marketplace
    /// ``defaultMarketplaceURL`` on ``defaultMarketplaceRef``.
    public static let defaultMarketplaces = [
        MarketplaceSource(defaultMarketplaceURL, ref: defaultMarketplaceRef)
    ]

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

    /// The default: the marketplaces of ``defaultMarketplaces``, below the
    /// local dotfolder stack.
    public init() {
        self.init(marketplaces: Self.defaultMarketplaces)
    }

    /// Decodes `marketplaces` when present and keeps
    /// ``defaultMarketplaces`` when absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marketplaces =
            try container.decodeIfPresent([MarketplaceSource].self, forKey: .marketplaces)
            ?? Self.defaultMarketplaces
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
/// ``ConfiguredSecret``: a literal, or a `keychain:<name>` reference whose
/// value ``ConfigurationLoader`` gets from its ``SecretStore``. An encoder
/// that sets ``Swift/CodingUserInfoKey/omitsConfiguredSecrets`` gets an
/// `apiKeys` map with the references only.
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

    /// Encodes `enabled`, and each key name with the shown form of its
    /// value: `keychain:<name>` for a reference, and the redacted form for a
    /// literal. With ``Swift/CodingUserInfoKey/omitsConfiguredSecrets`` set,
    /// the `apiKeys` map holds the references only.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        let written = encoder.omitsConfiguredSecrets ? apiKeys.filter { $0.value.reference != nil } : apiKeys
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
    /// environment for the same variable. A reference that has no value puts
    /// nothing in, thus it never gives an empty key.
    ///
    /// - Parameter processEnvironment: The environment of the process.
    /// - Returns: The environment that the web capability reads its keys
    ///   from.
    public func environment(mergedOver processEnvironment: [String: String]) -> [String: String] {
        processEnvironment.merging(
            apiKeys.compactMap { name, secret in secret.value.map { (name.environmentVariable, $0) } }
        ) { _, configured in configured }
    }

    /// These options with the value of each `keychain:<name>` reference
    /// from `store`. A literal key does not change.
    ///
    /// A reference with no item, or a reference whose lookup throws, is
    /// left out, thus its key acts as not set. A reference with no item
    /// adds one ``ConfigurationWarning/unresolvedSecret(keyPath:reference:)``
    /// to `warnings`. A reference whose lookup throws adds one
    /// ``ConfigurationWarning/unreadableSecret(keyPath:reference:)``. The
    /// warnings come in the provider table order. No warning holds a value.
    ///
    /// - Parameters:
    ///   - store: The store that gives the value of each reference.
    ///   - warnings: The warnings of the load. This adds one warning for
    ///     each reference that has no value.
    /// - Returns: The options with each reference resolved.
    func resolvingSecrets(
        through store: any SecretStore, warnings: inout [ConfigurationWarning]
    ) -> WebToolOptions {
        var resolved = self
        for name in WebAPIKeyName.allCases {
            guard let reference = apiKeys[name]?.reference else {
                continue
            }
            let value = Self.value(
                of: reference, keyPath: Self.keyPath(of: name), from: store, warnings: &warnings)
            resolved.apiKeys[name] = value.map { ConfiguredSecret(reference: reference, value: $0) }
        }
        return resolved
    }

    /// The value of one secret reference from `store`.
    ///
    /// A `nil` result of the store adds one
    /// ``ConfigurationWarning/unresolvedSecret(keyPath:reference:)``. An
    /// error of the store adds one
    /// ``ConfigurationWarning/unreadableSecret(keyPath:reference:)``. The
    /// warning does not hold the error: the warning names only the
    /// reference, and it never holds a value.
    ///
    /// - Parameters:
    ///   - reference: The reference name.
    ///   - keyPath: The dotted key path of the secret.
    ///   - store: The store that gives the value.
    ///   - warnings: The warnings of the load.
    /// - Returns: The value, or `nil` when the store has no item or the
    ///   lookup failed.
    private static func value(
        of reference: String, keyPath: String, from store: any SecretStore,
        warnings: inout [ConfigurationWarning]
    ) -> String? {
        let value: String?
        do {
            value = try store.value(forReference: reference)
        } catch {
            warnings.append(.unreadableSecret(keyPath: keyPath, reference: reference))
            return nil
        }
        if value == nil {
            warnings.append(.unresolvedSecret(keyPath: keyPath, reference: reference))
        }
        return value
    }

    /// The dotted key path of one key of the `apiKeys` map, such as
    /// `tools.web.apiKeys.tavily`.
    ///
    /// - Parameter name: The key name.
    /// - Returns: The key path.
    static func keyPath(of name: WebAPIKeyName) -> String {
        apiKeysSection + LoadedConfiguration.keyPathSeparator + name.rawValue
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

/// The body of a tool section whose only key is `enabled`: whether the
/// capability mounts. The capability is on by default, and the scalar
/// `<name>: false` of the shared codec turns it off too. ``GitToolOptions``
/// and ``EnvironmentToolOptions`` are names of this type.
public struct SwitchOnlyToolOptions: SwitchableToolOptions, KeyCheckedSection {
    /// Whether the capability mounts.
    public var enabled: Bool

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
    }

    /// Makes options.
    ///
    /// - Parameter enabled: Whether the capability mounts. The default is
    ///   `true`.
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
/// so the section has no root key.
public typealias GitToolOptions = SwitchOnlyToolOptions

/// The `tools.environment:` body: whether the environment capability mounts.
///
/// ```yaml
/// tools:
///   environment:
///     enabled: true
/// ```
///
/// The environment verbs — `tools.environment.variables`, `os` and `now` —
/// only read the process, thus the capability is on by default (the user
/// decided this on 2026-10-09). `variables` gives the model each variable of
/// the agent process, secrets too: set `enabled: false` to keep them out of
/// the model context. The section has no variable filter.
public typealias EnvironmentToolOptions = SwitchOnlyToolOptions

// MARK: - The mcp entry

/// One config-derived MCP server entry: a name and
/// exactly one transport. `env` and `headers` are YAML mappings here; the
/// MCP composition changes them into the wire's `{name, value}` pairs.
public struct MCPServerConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// How a server is reached. There are two transports:
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
/// not options). The three states: omitted means on with no
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

/// The `tools:` section: the roster of built-in
/// capabilities, each on unless the config sets it off. Absence enables —
/// a user with no config gets every capability with its defaults — and
/// disabling is per tool: there is no `tools: false` switch and no `only:`
/// allowlist.
///
/// The skills tool and the standalone `agents` tool are always on (the user
/// decided this on 2026-10-19). The skills entry has no off state, and the
/// roster has no agents entry, because the agents section has no option
/// other than `enabled`. A config that tries to turn one of them off still
/// loads: the loader gives a ``ConfigurationWarning/cannotDisable(section:)``
/// warning, and the tool stays on.
public struct ToolsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// The files capability's entry.
    public var files = ToolSection<FilesToolOptions>.enabled(FilesToolOptions())

    /// The shell capability's entry.
    public var shell = ToolSection<ShellToolOptions>.enabled(ShellToolOptions())

    /// The options of the skills tool, which is always on.
    public var skills = SkillsToolOptions()

    /// The code context capability's entry.
    public var codeContext = ToolSection<CodeContextToolOptions>.enabled(CodeContextToolOptions())

    /// The web capability's entry: `tools.web.search` and
    /// `tools.web.fetch`, with the keyless providers when no key is set.
    public var web = ToolSection<WebToolOptions>.enabled(WebToolOptions())

    /// The git capability's entry: the read-only `tools.git` verbs over the
    /// session working directory.
    public var git = ToolSection<GitToolOptions>.enabled(GitToolOptions())

    /// The environment capability's entry: the read-only
    /// `tools.environment` verbs `variables`, `os` and `now`.
    public var environment = ToolSection<EnvironmentToolOptions>.enabled(EnvironmentToolOptions())

    /// The mcp entry — the one list-bodied section.
    public var mcp = MCPToolSection.enabled(servers: [])

    /// The YAML spelling of each tool key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case files, shell, skills, codeContext, web, git, environment, mcp
    }

    /// The key of the standalone `agents` tool under `tools:`. The tool is
    /// always on, thus the roster has no property and no coding key for it.
    /// The key stays known, so that the loader gives no unknown-tool-section
    /// warning for it.
    static let agentsKey = "agents"

    /// The body keys of the `agents` section. `enabled` is the one key: the
    /// value `true` changes nothing, and the value `false` gives a warning.
    static let agentsBodyKeys: Set<String> = [SwitchOnlyToolOptions.CodingKeys.enabled.stringValue]

    /// The default roster: every built-in on, with its defaults.
    public init() {}

    /// Decodes each named tool and keeps the enabled default for each
    /// absent or null one. A key that names no tool, and the `agents` key,
    /// are not read here: the loader checks them before the decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files =
            try container.decodeIfPresent(ToolSection<FilesToolOptions>.self, forKey: .files)
            ?? files
        shell =
            try container.decodeIfPresent(ToolSection<ShellToolOptions>.self, forKey: .shell)
            ?? shell
        skills =
            try container.decodeIfPresent(
                AlwaysOnToolSection<SkillsToolOptions>.self, forKey: .skills)?.options
            ?? skills
        codeContext =
            try container.decodeIfPresent(
                ToolSection<CodeContextToolOptions>.self, forKey: .codeContext)
            ?? codeContext
        web = try container.decodeIfPresent(ToolSection<WebToolOptions>.self, forKey: .web) ?? web
        git = try container.decodeIfPresent(ToolSection<GitToolOptions>.self, forKey: .git) ?? git
        environment =
            try container.decodeIfPresent(
                ToolSection<EnvironmentToolOptions>.self, forKey: .environment)
            ?? environment
        mcp = try container.decodeIfPresent(MCPToolSection.self, forKey: .mcp) ?? mcp
    }
}

extension ToolsConfiguration {
    /// The known body keys of each mapping-bodied tool of the roster, by the
    /// tool's YAML spelling. `mcp` is not here: its body is a list of server
    /// entries, each checked against `MCPServerConfiguration.knownKeys`. The
    /// `agents` section is not here either, because the roster has no agents
    /// entry: ``agentsBodyKeys`` holds its keys. The tests of
    /// ``BuiltinConfigurationFile`` read it to make sure that the builtin
    /// file names each key.
    static let optionKeys: [String: Set<String>] = [
        CodingKeys.files.stringValue: FilesToolOptions.knownKeys,
        CodingKeys.shell.stringValue: ShellToolOptions.knownKeys,
        CodingKeys.skills.stringValue: SkillsToolOptions.knownKeys,
        CodingKeys.codeContext.stringValue: CodeContextToolOptions.knownKeys,
        CodingKeys.web.stringValue: WebToolOptions.knownKeys,
        CodingKeys.git.stringValue: GitToolOptions.knownKeys,
        CodingKeys.environment.stringValue: EnvironmentToolOptions.knownKeys,
    ]

    /// The key checks of the `tools:` body, run by the
    /// loader before the decode.
    ///
    /// - Returns: One warning per unknown tool key and one per entry that
    ///   tries to turn off a tool that is always on, in key order. An
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
    /// - Returns: The unknown-tool-section warning when no tool has this
    ///   name; the cannot-disable warning when the entry tries to turn off
    ///   a tool that is always on; `nil` when the tool is known and its body
    ///   keys pass.
    /// - Throws: `ConfigurationError.unknownKey` for the first key, in key
    ///   order, that the tool's body does not decode.
    private static func schemaWarning(forTool name: String, body: YAMLValue) throws
        -> ConfigurationWarning?
    {
        if name == CodingKeys.mcp.stringValue {
            try checkServerEntryKeys(inBody: body)
            return nil
        }
        guard let bodyKeys = bodyKeys(ofTool: name) else {
            return .unknownToolSection(name: name)
        }
        try ConfigurationError.checkKeys(
            of: body, against: bodyKeys, section: dottedSection(name))
        if name == CodingKeys.web.stringValue {
            try checkAPIKeyNames(inBody: body)
        }
        return turnsOffAnAlwaysOnTool(name, body: body) ? .cannotDisable(section: name) : nil
    }

    /// The known body keys of one tool.
    ///
    /// - Parameter name: The key of the tool under `tools:`.
    /// - Returns: The body keys, or `nil` when no tool has this name.
    private static func bodyKeys(ofTool name: String) -> Set<String>? {
        name == agentsKey ? agentsBodyKeys : optionKeys[name]
    }

    /// Whether one entry tries to turn off a tool that is always on: the
    /// scalar `skills: false`, the scalar `agents: false`, or the body
    /// `agents: {enabled: false}`.
    ///
    /// - Parameters:
    ///   - name: The key of the tool under `tools:`.
    ///   - body: The body of the entry.
    /// - Returns: `true` when the entry asks for the tool to be off.
    private static func turnsOffAnAlwaysOnTool(_ name: String, body: YAMLValue) -> Bool {
        switch (name, body) {
        case (CodingKeys.skills.stringValue, .bool(false)), (agentsKey, .bool(false)):
            return true
        case (agentsKey, .dictionary(let keys)):
            return keys[SwitchOnlyToolOptions.CodingKeys.enabled.stringValue] == .bool(false)
        default:
            return false
        }
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
