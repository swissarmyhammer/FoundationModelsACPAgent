import Foundation
import FoundationModelsExtras

/// The one list of folders that each settings stack of the agent comes from
/// (ACPA-16, D98): `config.yaml` and `Instructions.md`, the skills, the
/// agents and the rules.
///
/// Each stack has three levels, lowest precedence first:
///
/// 1. The built-in level: the defaults layer that the environment variable
///    `<NAME>_DEFAULTS_DIR` names (the dotfolder name of the kind in upper
///    case). It has no layer when the variable is not set. The builtin file
///    `builtin.config.yaml` is not a layer of the stack:
///    ``ConfigurationLoader`` puts it under the stack.
/// 2. The user level. With a root settings folder from the host (in the app,
///    `<iCloud container>/Agents/`), it is a folder in the root:
///    `<root>/` for `config.yaml` and `Instructions.md`, `<root>/_skills/`
///    for the skills, `<root>/_rules/` for the rules, and `<root>/` for the
///    agents. The settings folders in the root start with `_`, because a
///    name that starts with `_` is never a valid agent id. With no root (the
///    `acp-agent` CLI), it is the XDG folder `$XDG_CONFIG_HOME/<name>/`, or
///    `~/.config/<name>/`.
/// 3. The session level: the project dotfolder `<cwd>/.<name>/` of the
///    working directory of the session. It wins.
///
/// With a root, no stack holds a folder in the home directory or in
/// `XDG_CONFIG_HOME`.
public struct SettingsFolders: Sendable {
    /// A kind of settings. Each kind has its own stack.
    public enum Kind: Sendable {
        /// `config.yaml` and `Instructions.md`, under the dotfolder name of
        /// the host.
        case configuration

        /// The skills, under the dotfolder name `skills`.
        case skills

        /// The agents, under the dotfolder name `agents`.
        case agents

        /// The rules, under the dotfolder name `rules`. FoundationModelsRules
        /// reads no stack yet, thus only the folders are set here.
        case rules
    }

    /// The folder in the root settings folder that holds the skills.
    public static let skillsFolderName = "_skills"

    /// The folder in the root settings folder that holds the rules.
    public static let rulesFolderName = "_rules"

    /// The dotfolder name of the rules stack.
    public static let rulesDotfolderName = "rules"

    /// The suffix of the environment variable that names the defaults layer
    /// of a dotfolder name, as `DotfolderStack(name:workingDirectory:environment:)`
    /// reads it.
    static let defaultsDirectoryVariableSuffix = "_DEFAULTS_DIR"

    /// The dotfolder name of the host: the dotfolder name of the
    /// configuration stack.
    public let name: DotfolderName

    /// The root settings folder of the host, or `nil` for the XDG user
    /// layers of the CLI.
    public let rootSettingsFolder: URL?

    /// The environment that each stack reads its defaults layer from, and,
    /// with no root, `XDG_CONFIG_HOME`.
    public let environment: [String: String]

    /// Makes the settings folders of a host.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name of the host.
    ///   - rootSettingsFolder: The root settings folder of the host, or
    ///     `nil` (the default) for the XDG user layers of the CLI.
    ///   - environment: The environment that each stack reads. The process
    ///     environment by default.
    public init(
        name: DotfolderName,
        rootSettingsFolder: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.name = name
        self.rootSettingsFolder = rootSettingsFolder
        self.environment = environment
    }

    /// The stack of `kind` for one working directory, lowest precedence
    /// first: the defaults layer, the user layer, the project layer.
    ///
    /// Making the stack reads no file.
    ///
    /// - Parameters:
    ///   - kind: The kind of settings.
    ///   - workingDirectory: The working directory of the session. The
    ///     project layer is `<workingDirectory>/.<dotfolder name>/`.
    /// - Returns: The stack.
    public func stack(for kind: Kind, workingDirectory: URL) -> DotfolderStack {
        let dotfolder = dotfolderName(of: kind)
        guard let rootSettingsFolder else {
            return DotfolderStack(name: dotfolder, workingDirectory: workingDirectory, environment: environment)
        }
        return DotfolderStack(
            layers: defaultsLayers(of: dotfolder) + [
                DotfolderStack.Layer(source: .user, root: Self.userLayerRoot(of: kind, in: rootSettingsFolder)),
                DotfolderStack.Layer(
                    source: .project,
                    root: workingDirectory.appendingPathComponent(".\(dotfolder)", isDirectory: true)),
            ])
    }

    /// The dotfolder name of the stack of `kind`.
    ///
    /// - Parameter kind: The kind of settings.
    /// - Returns: The bare dotfolder name, with no leading dot.
    public func dotfolderName(of kind: Kind) -> String {
        switch kind {
        case .configuration:
            name.rawValue
        case .skills:
            ToolCatalog.skillsDotfolderName
        case .agents:
            ToolCatalog.agentsDotfolderName
        case .rules:
            Self.rulesDotfolderName
        }
    }

    /// The user layer root of `kind` in the root settings folder.
    ///
    /// - Parameters:
    ///   - kind: The kind of settings.
    ///   - rootSettingsFolder: The root settings folder of the host.
    /// - Returns: The folder.
    private static func userLayerRoot(of kind: Kind, in rootSettingsFolder: URL) -> URL {
        switch kind {
        case .configuration, .agents:
            rootSettingsFolder
        case .skills:
            rootSettingsFolder.appendingPathComponent(skillsFolderName, isDirectory: true)
        case .rules:
            rootSettingsFolder.appendingPathComponent(rulesFolderName, isDirectory: true)
        }
    }

    /// The defaults layer of `dotfolder` that ``environment`` names, as
    /// `DotfolderStack(name:workingDirectory:environment:)` derives it.
    ///
    /// - Parameter dotfolder: The dotfolder name of a kind.
    /// - Returns: The one defaults layer, or no layer when the variable is
    ///   not set or is empty.
    private func defaultsLayers(of dotfolder: String) -> [DotfolderStack.Layer] {
        guard
            let path = environment[dotfolder.uppercased() + Self.defaultsDirectoryVariableSuffix],
            !path.isEmpty
        else {
            return []
        }
        return [DotfolderStack.Layer(source: .defaults, root: URL(fileURLWithPath: path, isDirectory: true))]
    }
}
