import Foundation
import FoundationModelsExtras
import os

/// The logger the loader reports each unknown-section warning to.
private let configurationLogger = Logger(
    subsystem: "FoundationModelsACPAgent", category: "Configuration")

/// A schema failure the loader finds in the merged `config.yaml` tree before
/// the decode (plan.md §2.4).
public enum ConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The document's root is a scalar or a list, so it holds no section.
    case documentNotAMapping
    /// A known section holds a key it does not decode.
    case unknownKey(section: String, key: String)

    /// A human-readable reason that names the section and the key.
    public var description: String {
        switch self {
        case .documentNotAMapping:
            return "\(ConfigurationLoader.configFileName): the document must be a mapping of sections"
        case .unknownKey(let section, let key):
            return "\(ConfigurationLoader.configFileName): unknown key \"\(key)\" in section \"\(section)\""
        }
    }
}

/// A condition the loader reports and continues past (plan.md §2.4).
public enum ConfigurationWarning: Equatable, Sendable, CustomStringConvertible {
    /// A top-level section no schema section is named after.
    case unknownSection(name: String)

    /// A human-readable message that names the section.
    public var description: String {
        switch self {
        case .unknownSection(let name):
            return "\(ConfigurationLoader.configFileName): unknown section \"\(name)\" is ignored"
        }
    }
}

/// What one load gives: the decoded configuration and the warnings the
/// loader logged on the way.
public struct LoadedConfiguration: Equatable, Sendable {
    /// The merged and decoded configuration.
    public let configuration: AgentConfiguration

    /// Each warning the load logged, in document order.
    public let warnings: [ConfigurationWarning]
}

/// Loads `config.yaml` through the dotfolder stack (plan.md §2.2): the user
/// layer `~/.config/<name>/` (or `$XDG_CONFIG_HOME/<name>/` when that
/// variable is set and absolute) under the project layer `<cwd>/.<name>/`.
/// Both layers render untrusted; there is no defaults directory, because
/// the builtin defaults are `AgentConfiguration`'s property values.
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

    /// Builds the stack for `name`.
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
        self.name = name
        self.stack = DotfolderStack(
            name: name.rawValue,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment)
    }

    /// Loads, merges, checks and decodes `config.yaml`.
    ///
    /// With no file in any layer the result is `AgentConfiguration()`. An
    /// unknown top-level section is logged and returned as a warning. An
    /// unknown key inside a known section is an error.
    ///
    /// - Returns: The decoded configuration and the warnings.
    /// - Throws: `ConfigurationError` for a schema failure;
    ///   `LayeredYAMLDocumentError` for a layer that cannot be read,
    ///   rendered or parsed; `YAMLValueDecodingError` for a value that
    ///   does not decode, such as a `recording.level` other than `off` or
    ///   `full`.
    public func load() throws -> LoadedConfiguration {
        let document = try LayeredYAMLDocument.load(
            Self.configFileName,
            from: stack,
            engine: TemplateEngine(partials: stack),
            context: TemplateContext())
        let warnings = try Self.schemaWarnings(in: document.root)
        for warning in warnings {
            configurationLogger.warning("\(warning.description, privacy: .public)")
        }
        return LoadedConfiguration(
            configuration: try Self.configuration(from: document.root), warnings: warnings)
    }

    /// The decoded merged tree, or the builtin defaults when no layer
    /// contributed a document.
    private static func configuration(from root: YAMLValue) throws -> AgentConfiguration {
        guard root != .null else {
            return AgentConfiguration()
        }
        return try root.decoded(as: AgentConfiguration.self)
    }

    /// The warnings a walk of the merged tree against
    /// `AgentConfiguration.sectionSchemas` gives.
    ///
    /// - Returns: One warning per unknown top-level section, in key order.
    /// - Throws: `ConfigurationError.documentNotAMapping` when the root is
    ///   a scalar or a list; `ConfigurationError.unknownKey` for a key a
    ///   checked section does not decode.
    private static func schemaWarnings(in root: YAMLValue) throws -> [ConfigurationWarning] {
        switch root {
        case .null:
            return []
        case .dictionary(let sections):
            return try sections.sorted { $0.key < $1.key }.compactMap { section in
                try schemaWarning(forSection: section.key, body: section.value)
            }
        case .string, .int, .double, .bool, .array:
            throw ConfigurationError.documentNotAMapping
        }
    }

    /// The warning one top-level section gives, after its keys pass.
    ///
    /// - Returns: The unknown-section warning when no schema section has
    ///   this name; `nil` when the section is known and its keys pass.
    /// - Throws: `ConfigurationError.unknownKey` for the first key, in key
    ///   order, that a checked section does not decode.
    private static func schemaWarning(forSection name: String, body: YAMLValue) throws
        -> ConfigurationWarning?
    {
        guard let schema = AgentConfiguration.sectionSchemas[name] else {
            return .unknownSection(name: name)
        }
        guard case .checked(let knownKeys) = schema, case .dictionary(let keys) = body else {
            return nil
        }
        if let unknownKey = keys.keys.sorted().first(where: { !knownKeys.contains($0) }) {
            throw ConfigurationError.unknownKey(section: name, key: unknownKey)
        }
        return nil
    }
}
