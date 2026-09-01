import Foundation
import FoundationModelsExtras

// MARK: - The per-tool codec

/// The option type of one mapping-bodied `tools:` entry (plan.md §11.2).
/// The body is the tool package's own option type — there is no `enabled:`
/// key, because `false` sits outside the body — and `init()` is the
/// defaults an enabling shape (`absent`, `{}`, null, `true`) gives.
public protocol ToolSectionOptions: Codable, Equatable, Sendable {
    /// The defaults the tool gets when the config enables it without a body.
    init()
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

/// The `tools.files:` body — the three flags of
/// `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:)`
/// that config may set (plan.md §11.3). The root set is session state, not
/// config, so it is not here.
public struct FilesToolOptions: ToolSectionOptions, KeyCheckedSection {
    /// Whether the writing verbs are refused.
    public var readOnly: Bool

    /// Whether a path may traverse a symbolic link.
    public var allowSymlinks: Bool

    /// Whether each change is recorded for the session.
    public var recordsChanges: Bool

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case readOnly, allowSymlinks, recordsChanges
    }

    /// Makes options; each omitted flag keeps the builder call's default,
    /// which is `false`.
    public init(readOnly: Bool = false, allowSymlinks: Bool = false, recordsChanges: Bool = false) {
        self.readOnly = readOnly
        self.allowSymlinks = allowSymlinks
        self.recordsChanges = recordsChanges
    }

    /// The defaults: writable, no symlink traversal, no change recording.
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
/// stack (plan.md §14.2) and takes no config options, so the body decodes
/// no key and every key in it is unknown.
public struct SkillsToolOptions: ToolSectionOptions {
    /// The empty key set the loader checks the body against: an enabling
    /// body is `{}` or absent.
    static let knownKeys: Set<String> = []

    /// The one value there is.
    public init() {}
}

// MARK: - The mcp entry

/// One config-derived MCP server entry (plan.md §7.3, §11.5): a name and
/// exactly one transport. `env` and `headers` are YAML mappings here; the
/// MCP composition turns them into the wire's `{name, value}` pairs.
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
/// capabilities, each on unless the config turns it off. Absence enables —
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

    /// The mcp entry — the one list-bodied section.
    public var mcp = MCPToolSection.enabled(servers: [])

    /// The YAML spelling of each tool key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case files, shell, skills, mcp
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
        mcp = try container.decodeIfPresent(MCPToolSection.self, forKey: .mcp) ?? mcp
    }
}

extension ToolsConfiguration {
    /// The known body keys of each mapping-bodied tool, by the tool's YAML
    /// spelling. `mcp` is not here: its body is a list of server entries,
    /// each checked against `MCPServerConfiguration.knownKeys`.
    private static let optionKeys: [String: Set<String>] = [
        CodingKeys.files.stringValue: FilesToolOptions.knownKeys,
        CodingKeys.shell.stringValue: ShellToolOptions.knownKeys,
        CodingKeys.skills.stringValue: SkillsToolOptions.knownKeys,
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
        return nil
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

    /// The dotted section name an error inside a tool body carries, such as
    /// `tools.shell`.
    private static func dottedSection(_ name: String) -> String {
        "\(AgentConfiguration.CodingKeys.tools.stringValue).\(name)"
    }
}
