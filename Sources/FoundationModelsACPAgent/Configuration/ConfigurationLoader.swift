import Foundation
import FoundationModelsExtras
import Logging

/// A schema failure the loader finds in the merged `config.yaml` tree before
/// the decode.
public enum ConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The document's root is a scalar or a list, so it holds no section.
    case documentNotAMapping
    /// A known section holds a key it does not decode.
    case unknownKey(section: String, key: String)
    /// A map whose keys are a closed set holds a key that is not in the
    /// set, such as a provider name of `tools.web.apiKeys` that no provider
    /// has. The error lists the valid keys, because a person cannot see
    /// them in the document.
    case unknownMapKey(section: String, key: String, validKeys: [String])

    /// A human-readable reason that names the section and the key.
    public var description: String {
        switch self {
        case .documentNotAMapping:
            return "\(ConfigurationLoader.configFileName): the document must be a mapping of sections"
        case .unknownKey(let section, let key):
            return "\(ConfigurationLoader.configFileName): unknown key \"\(key)\" in section \"\(section)\""
        case .unknownMapKey(let section, let key, let validKeys):
            return "\(ConfigurationLoader.configFileName): unknown key \"\(key)\" in section \"\(section)\"; "
                + "the valid keys are \(validKeys.joined(separator: ", "))"
        }
    }
}

extension ConfigurationError {
    /// Throws `.unknownKey` for the first key of `body`, in key order, that
    /// `knownKeys` does not contain. A body that is not a mapping has no
    /// keys to check.
    static func checkKeys(of body: YAMLValue, against knownKeys: Set<String>, section: String)
        throws
    {
        guard case .dictionary(let keys) = body else {
            return
        }
        if let unknownKey = keys.keys.sorted().first(where: { !knownKeys.contains($0) }) {
            throw ConfigurationError.unknownKey(section: section, key: unknownKey)
        }
    }
}

/// A condition the loader reports and continues past.
public enum ConfigurationWarning: Equatable, Sendable, CustomStringConvertible {
    /// A top-level section no schema section is named after.
    case unknownSection(name: String)

    /// A key under `tools:` that names no tool in the roster.
    case unknownToolSection(name: String)

    /// A `tools:` entry that tries to turn off a tool that is always on:
    /// `tools.skills: false`, `tools.agents: false`, or
    /// `tools.agents.enabled: false`. The loader ignores the request, and
    /// the tool stays on. `section` is the key of the tool under `tools:`.
    case cannotDisable(section: String)

    /// A secret reference `keychain:<name>` whose store has no item for the
    /// name (ACPA-18, D101). The key acts as not set. `keyPath` is the
    /// dotted key path of the secret, such as `tools.web.apiKeys.tavily`, or
    /// `tools.mcp.<server>.headers.<header>` for an MCP server, and
    /// `reference` is the name. The warning never holds a value.
    case unresolvedSecret(keyPath: String, reference: String)

    /// A secret reference `keychain:<name>` whose lookup threw, for example
    /// because the Keychain is locked or refused the access (ACPA-18, D101).
    /// The key acts as not set. `keyPath` is the dotted key path of the
    /// secret, and `reference` is the name. The warning never holds a value,
    /// and it does not hold the error of the store.
    case unreadableSecret(keyPath: String, reference: String)

    /// A human-readable message that names the section.
    public var description: String {
        switch self {
        case .unknownSection(let name):
            return "\(ConfigurationLoader.configFileName): unknown section \"\(name)\" is ignored"
        case .unknownToolSection(let name):
            return
                "\(ConfigurationLoader.configFileName): unknown tool section \"tools.\(name)\" is ignored"
        case .cannotDisable(let section):
            return
                "\(ConfigurationLoader.configFileName): the tool section \"tools.\(section)\" cannot be turned off; the tool stays on"
        case .unresolvedSecret(let keyPath, let reference):
            return
                "\(ConfigurationLoader.configFileName): the secret store has no item for the reference \"\(ConfiguredSecret.referencePrefix)\(reference)\" of \"\(keyPath)\"; the key is not set"
        case .unreadableSecret(let keyPath, let reference):
            return
                "\(ConfigurationLoader.configFileName): the secret store could not read the item for the reference \"\(ConfiguredSecret.referencePrefix)\(reference)\" of \"\(keyPath)\"; the lookup failed and the key is not set"
        }
    }
}

extension ConfigurationWarning {
    /// Writes the log record of this warning: one `warning` record with a
    /// fixed message, and the section name in its metadata. The record never
    /// holds a value of the section, because a value can be a secret.
    func log() {
        ACPAgentTelemetry.logger(.configuration).warning(
            logMessage,
            metadata: [ACPAgentTelemetry.LogMetadataKey.configSection: "\(sectionKeyPath)"])
    }

    /// The fixed message of the log record of this warning.
    private var logMessage: Logger.Message {
        switch self {
        case .unknownSection:
            "The configuration has an unknown section. The loader ignored the section."
        case .unknownToolSection:
            "The configuration has an unknown tool section. The loader ignored the section."
        case .cannotDisable:
            "The configuration turns off a tool that is always on. The tool stays on."
        case .unresolvedSecret:
            "The secret store has no item for a secret reference of the configuration. The key is not set."
        case .unreadableSecret:
            "The secret store could not read the item for a secret reference of the configuration. The key is not set."
        }
    }

    /// The key path of the section that this warning is about: the section
    /// name, `tools.<name>` for a tool section, or the key path of a secret.
    var sectionKeyPath: String {
        switch self {
        case .unknownSection(let name):
            name
        case .unknownToolSection(let name), .cannotDisable(let name):
            ToolsConfiguration.dottedSection(name)
        case .unresolvedSecret(let keyPath, _), .unreadableSecret(let keyPath, _):
            keyPath
        }
    }
}

/// What one load gives: the decoded configuration, the warnings the loader
/// logged on the way, and the layer that set each key.
public struct LoadedConfiguration: Equatable, Sendable {
    /// The separator of a dotted key path, such as `recording.level`.
    public static let keyPathSeparator = "."

    /// The merged and decoded configuration.
    public let configuration: AgentConfiguration

    /// Each warning the load logged, in document order.
    public let warnings: [ConfigurationWarning]

    /// The layer that set each key a layer set, by dotted key path such as
    /// `recording.level` (cli-plan.md §5.11). A section key names the
    /// layer that introduced the section. A key with no entry was set by
    /// no layer: its value is the builtin default. `DotfolderStack.Source`
    /// has no builtin case, so a report maps the absent entry to
    /// `ConfigurationLayerName.builtin`.
    public let sources: [String: DotfolderStack.Source]
}

/// Loads `config.yaml` through the configuration stack.
/// Layer 1 is the builtin file `builtin.config.yaml`, a resource of
/// this library. Over it is the configuration stack of ``SettingsFolders``:
/// the user layer under the project layer `<cwd>/.<name>/`. The user layer
/// is the root settings folder of the host when the host gives one, and
/// otherwise `~/.config/<name>/` (or `$XDG_CONFIG_HOME/<name>/` when that
/// variable is set and absolute). Both dotfolder layers render untrusted.
/// Layer 1 is not a template and sets no source, thus a key that only
/// layer 1 sets reports the builtin layer.
///
/// The project layer resolves per session, so one loader serves one
/// working directory. Two loaders with two working directories see two
/// project layers.
public struct ConfigurationLoader: Sendable {
    /// The file each layer contributes.
    public static let configFileName = "config.yaml"

    /// The dotfolder name the stack is rooted at.
    public let name: DotfolderName

    /// The settings folders the stack comes from. The doctor reads the
    /// skills and agents stacks of the same folders.
    public let settingsFolders: SettingsFolders

    /// The stack the loader resolves `config.yaml` against: the
    /// ``SettingsFolders/Kind/configuration`` stack of ``settingsFolders``.
    public let stack: DotfolderStack

    /// The transcript location that a host gives in code, or `nil` when
    /// the files decide. When it is not `nil`, each ``load()`` puts it over
    /// the `transcripts.location` of every layer.
    ///
    /// The override is not a layer, so ``LoadedConfiguration/sources`` does
    /// not show it: the entry of `transcripts.location` names the file
    /// layer that set the key, or no layer. `config show` does not show a
    /// code override either; the `acp-agent` CLI never gives one.
    public let transcriptLocation: TranscriptLocation?

    /// The store that gives the value of each secret reference
    /// `keychain:<name>` of the configuration (ACPA-18, D101). Each
    /// ``load()`` resolves the references through it after the decode.
    public let secretStore: any SecretStore

    /// Gives the tree of layer 1, under the dotfolder stack.
    private let builtinLayer: @Sendable () throws -> YAMLValue

    /// Builds the configuration stack of `settingsFolders` for one working
    /// directory, over the builtin configuration file.
    ///
    /// - Parameters:
    ///   - settingsFolders: The settings folders of the host. Their
    ///     ``SettingsFolders/name`` is the dotfolder name of the loader.
    ///   - workingDirectory: The session working directory; the project
    ///     layer roots at `<workingDirectory>/.<name>/`.
    ///   - transcriptLocation: The transcript location that wins over every
    ///     layer, or `nil` (the default) to let the files decide — see
    ///     ``transcriptLocation``.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` (the default) for the login Keychain under
    ///     the service `name` (``KeychainSecretStore/loginKeychain(for:)``).
    ///     A test gives an ``InMemorySecretStore``.
    public init(
        settingsFolders: SettingsFolders,
        workingDirectory: URL,
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil
    ) {
        self.init(
            settingsFolders: settingsFolders, workingDirectory: workingDirectory,
            transcriptLocation: transcriptLocation, secretStore: secretStore,
            builtinLayer: BuiltinConfigurationFile.root)
    }

    /// Builds the stack for `name`, over the builtin configuration file.
    ///
    /// The user layer root of the configuration stack is the root settings
    /// folder of ``SettingsFolders``, thus `userDirectory` goes to the
    /// settings folders as their root.
    ///
    /// - Parameters:
    ///   - name: The validated dotfolder name.
    ///   - workingDirectory: The session working directory; the project
    ///     layer roots at `<workingDirectory>/.<name>/`.
    ///   - userDirectory: The user layer root, or `nil` to derive it from
    ///     `environment` and the home directory. Tests inject a value so
    ///     they never touch the real home directory.
    ///   - environment: The environment `XDG_CONFIG_HOME` is read from.
    ///   - transcriptLocation: The transcript location that wins over every
    ///     layer, or `nil` (the default) to let the files decide — see
    ///     ``transcriptLocation``.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` (the default) for the login Keychain under
    ///     the service `name` (``KeychainSecretStore/loginKeychain(for:)``).
    ///     A test gives an ``InMemorySecretStore``.
    public init(
        name: DotfolderName,
        workingDirectory: URL,
        userDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil
    ) {
        self.init(
            name: name, workingDirectory: workingDirectory, userDirectory: userDirectory,
            environment: environment, transcriptLocation: transcriptLocation,
            secretStore: secretStore, builtinLayer: BuiltinConfigurationFile.root)
    }

    /// Builds the stack for `name`, over the layer 1 tree that
    /// `builtinLayer` gives.
    ///
    /// - Parameters:
    ///   - name: The validated dotfolder name.
    ///   - workingDirectory: The session working directory.
    ///   - userDirectory: The user layer root, or `nil` to derive it.
    ///   - environment: The environment `XDG_CONFIG_HOME` is read from.
    ///   - transcriptLocation: The transcript location that wins over every
    ///     layer, or `nil` to let the files decide.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` for the login Keychain under the service
    ///     `name`.
    ///   - builtinLayer: Gives the tree of layer 1. Each load calls it.
    init(
        name: DotfolderName,
        workingDirectory: URL,
        userDirectory: URL?,
        environment: [String: String],
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil,
        builtinLayer: @escaping @Sendable () throws -> YAMLValue
    ) {
        self.init(
            settingsFolders: SettingsFolders(
                name: name, rootSettingsFolder: userDirectory, environment: environment),
            workingDirectory: workingDirectory, transcriptLocation: transcriptLocation,
            secretStore: secretStore, builtinLayer: builtinLayer)
    }

    /// Builds the configuration stack of `settingsFolders`, over the layer 1
    /// tree that `builtinLayer` gives.
    ///
    /// - Parameters:
    ///   - settingsFolders: The settings folders of the host.
    ///   - workingDirectory: The session working directory.
    ///   - transcriptLocation: The transcript location that wins over every
    ///     layer, or `nil` to let the files decide.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` for the login Keychain under the service
    ///     `name`.
    ///   - builtinLayer: Gives the tree of layer 1. Each load calls it.
    init(
        settingsFolders: SettingsFolders,
        workingDirectory: URL,
        transcriptLocation: TranscriptLocation?,
        secretStore: (any SecretStore)?,
        builtinLayer: @escaping @Sendable () throws -> YAMLValue
    ) {
        self.name = settingsFolders.name
        self.settingsFolders = settingsFolders
        self.stack = settingsFolders.stack(for: .configuration, workingDirectory: workingDirectory)
        self.transcriptLocation = transcriptLocation
        self.secretStore = secretStore ?? KeychainSecretStore.loginKeychain(for: settingsFolders.name)
        self.builtinLayer = builtinLayer
    }

    /// The configuration a load gives when no layer holds a file:
    /// `AgentConfiguration()` with each default that the dotfolder name
    /// gives. The files tools exclude the dotfolder `.<name>/`, which holds
    /// the transcripts of the agent (``FilesToolOptions/exclude``).
    ///
    /// `config init` writes this configuration, thus the file it writes
    /// loads back to the same value.
    public var builtinConfiguration: AgentConfiguration {
        resolvingDotfolderDefaults(of: AgentConfiguration())
    }

    /// The location of the builtin configuration file
    /// `builtin.config.yaml`, layer 1 of the stack, in the resource bundle
    /// of this library. `config path` shows it in the builtin row.
    ///
    /// - Returns: The file URL.
    /// - Throws: ``BuiltinConfigurationFileError/missing(fileName:)`` when
    ///   the bundle has no such file.
    public static func builtinConfigurationFileURL() throws -> URL {
        try BuiltinConfigurationFile.url()
    }

    /// Loads, merges, checks and decodes `config.yaml`.
    ///
    /// The merged dotfolder tree goes over layer 1, the builtin file. With
    /// no file in any dotfolder layer the result is
    /// ``builtinConfiguration``. Each value that no layer sets and that the
    /// dotfolder name gives, such as the default of `tools.files.exclude`,
    /// is put in after the decode. An unknown top-level section is logged
    /// and returned as a warning. An unknown key inside a known section is
    /// an error. Each secret reference `keychain:<name>` then gets its value
    /// from ``secretStore``; a reference with no value is left out, and it
    /// is logged and returned as a warning. A ``transcriptLocation`` that is
    /// not `nil` then replaces the decoded `transcripts.location`.
    ///
    /// - Returns: The decoded configuration and the warnings.
    /// - Throws: `ConfigurationError` for a schema failure;
    ///   `LayeredYAMLDocumentError` for a layer that cannot be read,
    ///   rendered or parsed; ``BuiltinConfigurationFileError`` or
    ///   `YAMLValueParsingError` for a builtin file that cannot be read or
    ///   parsed; `YAMLValueDecodingError` for a value that does not decode,
    ///   such as a `recording.level` other than `off` or `full`.
    public func load() throws -> LoadedConfiguration {
        let document = try LayeredYAMLDocument.load(
            Self.configFileName,
            from: stack,
            engine: TemplateEngine(partials: stack),
            context: TemplateContext())
        let root = try layeredRoot(over: document)
        let schemaWarnings = try Self.schemaWarnings(in: root)
        Self.log(schemaWarnings)
        var secretWarnings: [ConfigurationWarning] = []
        let decoded = resolvingSecrets(of: try Self.configuration(from: root), warnings: &secretWarnings)
        Self.log(secretWarnings)
        return LoadedConfiguration(
            configuration: resolvingCodeOverride(of: resolvingDotfolderDefaults(of: decoded)),
            warnings: schemaWarnings + secretWarnings,
            sources: Self.sources(in: document))
    }

    /// Writes one log record for each warning, in the order of `warnings`.
    ///
    /// - Parameter warnings: The warnings to log.
    private static func log(_ warnings: [ConfigurationWarning]) {
        for warning in warnings {
            warning.log()
        }
    }

    /// `configuration` with the value of each secret reference from
    /// ``secretStore``. The secrets of the schema are the web API keys, and
    /// the `env` and `headers` values of each `mcp` server. A web section
    /// that is off by the scalar `web: false` holds no key, and the scalar
    /// `mcp: false` holds no server. The web warnings come first, then the
    /// mcp warnings.
    ///
    /// - Parameters:
    ///   - configuration: The decoded configuration.
    ///   - warnings: The warnings of the load. This adds one
    ///     ``ConfigurationWarning/unresolvedSecret(keyPath:reference:)`` for
    ///     each reference with no item, and one
    ///     ``ConfigurationWarning/unreadableSecret(keyPath:reference:)`` for
    ///     each reference whose lookup threw.
    /// - Returns: The configuration with each reference resolved, and each
    ///   reference with no value left out.
    private func resolvingSecrets(
        of configuration: AgentConfiguration, warnings: inout [ConfigurationWarning]
    ) -> AgentConfiguration {
        var resolved = configuration
        if case .enabled(let options) = configuration.tools.web {
            resolved.tools.web = .enabled(options.resolvingSecrets(through: secretStore, warnings: &warnings))
        }
        resolved.tools.mcp = configuration.tools.mcp.resolvingSecrets(through: secretStore, warnings: &warnings)
        return resolved
    }

    /// `configuration` with ``transcriptLocation`` over its
    /// `transcripts.location` when the host gave one.
    ///
    /// - Parameter configuration: The decoded configuration.
    /// - Returns: The configuration in effect.
    private func resolvingCodeOverride(of configuration: AgentConfiguration) -> AgentConfiguration {
        guard let transcriptLocation else {
            return configuration
        }
        var resolved = configuration
        resolved.transcripts.location = transcriptLocation
        return resolved
    }

    /// The tree of layer 1 with the merged dotfolder tree over it.
    ///
    /// - Parameter document: The merged dotfolder layers.
    /// - Returns: The tree of layer 1 alone when no dotfolder layer holds a
    ///   file, and the merged tree of all the layers otherwise.
    /// - Throws: What the layer 1 source throws.
    private func layeredRoot(over document: LayeredYAMLDocument) throws -> YAMLValue {
        let builtinRoot = try builtinLayer()
        guard document.root != .null else {
            return builtinRoot
        }
        return builtinRoot.layered(under: document.root)
    }

    /// `configuration` with each default that the dotfolder name of this
    /// loader gives put in where no layer set a value.
    ///
    /// - Parameter configuration: The decoded configuration.
    /// - Returns: The configuration in effect.
    private func resolvingDotfolderDefaults(of configuration: AgentConfiguration)
        -> AgentConfiguration
    {
        var resolved = configuration
        resolved.tools = configuration.tools.resolvingDotfolderDefaults(name)
        return resolved
    }

    /// The layer that set each key of `document`'s merged tree, by dotted
    /// key path — the per-key provenance the document holds, copied out
    /// before the document goes out of scope.
    ///
    /// - Parameter document: The merged document.
    /// - Returns: One entry per key path the document has a source for. A
    ///   key that holds the separator itself is not told apart from a
    ///   nested path; the first entry wins.
    private static func sources(in document: LayeredYAMLDocument) -> [String: DotfolderStack.Source] {
        let entries = keyPaths(in: document.root, under: []).compactMap { keyPath in
            document.source(of: keyPath).map {
                (keyPath.joined(separator: LoadedConfiguration.keyPathSeparator), $0)
            }
        }
        return Dictionary(entries, uniquingKeysWith: { first, _ in first })
    }

    /// Every key path of a mapping tree, depth first: each key of `value`
    /// under `parent`, then each key of its mapping children. A scalar or
    /// a list holds no key.
    ///
    /// - Parameters:
    ///   - value: The tree to walk.
    ///   - parent: The key path of `value` itself; empty at the root.
    /// - Returns: The key paths, each as its components.
    private static func keyPaths(in value: YAMLValue, under parent: [String]) -> [[String]] {
        guard case .dictionary(let children) = value else {
            return []
        }
        return children.flatMap { key, child in
            let keyPath = parent + [key]
            return [keyPath] + keyPaths(in: child, under: keyPath)
        }
    }

    /// The decoded merged tree, or the in-code defaults when the tree is
    /// empty.
    private static func configuration(from root: YAMLValue) throws -> AgentConfiguration {
        guard root != .null else {
            return AgentConfiguration()
        }
        return try root.decoded(as: AgentConfiguration.self)
    }

    /// The warnings a walk of the merged tree against
    /// `AgentConfiguration.sectionSchemas` gives.
    ///
    /// - Returns: The warnings in key order: one per unknown top-level
    ///   section, and one per unknown tool key under `tools:`.
    /// - Throws: `ConfigurationError.documentNotAMapping` when the root is
    ///   a scalar or a list; `ConfigurationError.unknownKey` for a key a
    ///   checked section or a known tool body does not decode.
    private static func schemaWarnings(in root: YAMLValue) throws -> [ConfigurationWarning] {
        switch root {
        case .null:
            return []
        case .dictionary(let sections):
            return try sections.sorted { $0.key < $1.key }.flatMap { section in
                try schemaWarnings(forSection: section.key, body: section.value)
            }
        case .string, .int, .double, .bool, .array:
            throw ConfigurationError.documentNotAMapping
        }
    }

    /// The warnings one top-level section gives, after its keys pass.
    ///
    /// - Returns: The unknown-section warning when no schema section has
    ///   this name; the tool-roster warnings for `tools:`; nothing when the
    ///   section is known and its keys pass.
    /// - Throws: `ConfigurationError.unknownKey` for the first key, in key
    ///   order, that a checked section or a known tool body does not
    ///   decode.
    private static func schemaWarnings(forSection name: String, body: YAMLValue) throws
        -> [ConfigurationWarning]
    {
        guard let schema = AgentConfiguration.sectionSchemas[name] else {
            return [.unknownSection(name: name)]
        }
        switch schema {
        case .checked(let knownKeys):
            try ConfigurationError.checkKeys(of: body, against: knownKeys, section: name)
            return []
        case .toolRoster:
            return try ToolsConfiguration.schemaWarnings(inBody: body)
        }
    }
}
