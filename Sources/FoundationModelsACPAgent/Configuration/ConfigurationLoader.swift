import Foundation
import FoundationModelsExtras
import Logging

/// A schema failure the loader finds in the merged `config.yaml` tree before
/// the decode (plan.md §2.4).
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

/// A condition the loader reports and continues past (plan.md §2.4).
public enum ConfigurationWarning: Equatable, Sendable, CustomStringConvertible {
    /// A top-level section no schema section is named after.
    case unknownSection(name: String)

    /// A key under `tools:` that names no tool in the roster (plan.md
    /// §11.2).
    case unknownToolSection(name: String)

    /// A human-readable message that names the section.
    public var description: String {
        switch self {
        case .unknownSection(let name):
            return "\(ConfigurationLoader.configFileName): unknown section \"\(name)\" is ignored"
        case .unknownToolSection(let name):
            return
                "\(ConfigurationLoader.configFileName): unknown tool section \"tools.\(name)\" is ignored"
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
        }
    }

    /// The key path of the section that this warning is about: the section
    /// name, or `tools.<name>` for a tool section.
    private var sectionKeyPath: String {
        switch self {
        case .unknownSection(let name):
            name
        case .unknownToolSection(let name):
            ToolsConfiguration.dottedSection(name)
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

/// Loads `config.yaml` through the configuration stack (plan.md §2.2).
/// Layer 1 is the builtin file `builtin.config.yaml`, a resource of
/// this library. Over it is the dotfolder stack: the user layer
/// `~/.config/<name>/` (or `$XDG_CONFIG_HOME/<name>/` when that variable is
/// set and absolute) under the project layer `<cwd>/.<name>/`. Both
/// dotfolder layers render untrusted. Layer 1 is not a template and sets no
/// source, thus a key that only layer 1 sets reports the builtin layer.
///
/// The project layer resolves per session, so one loader serves one
/// working directory. Two loaders with two working directories see two
/// project layers.
public struct ConfigurationLoader: Sendable {
    /// The file each layer contributes.
    public static let configFileName = "config.yaml"

    /// The dotfolder name the stack is rooted at.
    public let name: DotfolderName

    /// The two-layer stack the loader resolves `config.yaml` against.
    public let stack: DotfolderStack

    /// Gives the tree of layer 1, under the dotfolder stack.
    private let builtinLayer: @Sendable () throws -> YAMLValue

    /// Builds the stack for `name`, over the builtin configuration file.
    ///
    /// - Parameters:
    ///   - name: The validated dotfolder name.
    ///   - workingDirectory: The session working directory; the project
    ///     layer roots at `<workingDirectory>/.<name>/`.
    ///   - userDirectory: The user layer root, or `nil` to derive it from
    ///     `environment` and the home directory. Tests inject a value so
    ///     they never touch the real home directory.
    ///   - environment: The environment `XDG_CONFIG_HOME` is read from.
    public init(
        name: DotfolderName,
        workingDirectory: URL,
        userDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            name: name, workingDirectory: workingDirectory, userDirectory: userDirectory,
            environment: environment, builtinLayer: BuiltinConfigurationFile.root)
    }

    /// Builds the stack for `name`, over the layer 1 tree that
    /// `builtinLayer` gives.
    ///
    /// - Parameters:
    ///   - name: The validated dotfolder name.
    ///   - workingDirectory: The session working directory.
    ///   - userDirectory: The user layer root, or `nil` to derive it.
    ///   - environment: The environment `XDG_CONFIG_HOME` is read from.
    ///   - builtinLayer: Gives the tree of layer 1. Each load calls it.
    init(
        name: DotfolderName,
        workingDirectory: URL,
        userDirectory: URL?,
        environment: [String: String],
        builtinLayer: @escaping @Sendable () throws -> YAMLValue
    ) {
        self.name = name
        self.stack = DotfolderStack(
            name: name.rawValue,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment)
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

    /// Loads, merges, checks and decodes `config.yaml`.
    ///
    /// The merged dotfolder tree goes over layer 1, the builtin file. With
    /// no file in any dotfolder layer the result is
    /// ``builtinConfiguration``. Each value that no layer sets and that the
    /// dotfolder name gives, such as the default of `tools.files.exclude`,
    /// is put in after the decode. An unknown top-level section is logged
    /// and returned as a warning. An unknown key inside a known section is
    /// an error.
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
        let warnings = try Self.schemaWarnings(in: root)
        for warning in warnings {
            warning.log()
        }
        return LoadedConfiguration(
            configuration: resolvingDotfolderDefaults(of: try Self.configuration(from: root)),
            warnings: warnings,
            sources: Self.sources(in: document))
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
