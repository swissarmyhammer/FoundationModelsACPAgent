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
/// 2. The user level, which the ``AgentHome`` of the host gives (task
///    ^98a44n7). With a custom home it is a folder in the synced root:
///    `<synced>/` for `config.yaml` and `Instructions.md`, `<synced>/_skills/`
///    for the skills, `<synced>/_rules/` for the rules, and `<synced>/` for
///    the agents. The settings folders in the root start with `_`, because a
///    name that starts with `_` is never a valid agent id. With the XDG home
///    of the `acp-agent` CLI, it is the XDG folder of the dotfolder name of
///    the kind, `$XDG_CONFIG_HOME/<dotfolder>/` or `~/.config/<dotfolder>/`.
/// 3. The session level: the project dotfolder `<cwd>/.<dotfolder>/` of the
///    working directory of the session. It wins.
///
/// The home always gives the user layer, thus no stack derives a folder of
/// the home directory or of `XDG_CONFIG_HOME` on its own.
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

    /// The folder in the synced root of a custom home that holds the skills.
    public static let skillsFolderName = "_skills"

    /// The folder in the synced root of a custom home that holds the rules.
    public static let rulesFolderName = "_rules"

    /// The dotfolder name of the rules stack.
    public static let rulesDotfolderName = "rules"

    /// The dotfolder name of the host: the dotfolder name of the
    /// configuration stack.
    public let name: DotfolderName

    /// The home of the host, which gives the user layer of each stack.
    public let home: AgentHome

    /// The environment that each stack reads its defaults layer from.
    public let environment: [String: String]

    /// Makes the settings folders of a host.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name of the host.
    ///   - home: The home of the host, which gives the user layer of each
    ///     stack.
    ///   - environment: The environment that each stack reads its defaults
    ///     layer from.
    public init(name: DotfolderName, home: AgentHome, environment: [String: String]) {
        self.name = name
        self.home = home
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
        return DotfolderStack(
            name: dotfolder, workingDirectory: workingDirectory,
            userDirectory: home.userLayerRoot(dotfolder: dotfolder, folderInRoot: Self.folderInRoot(of: kind)),
            environment: environment)
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

    /// The folder of the user layer of `kind` in the synced root of a custom
    /// home.
    ///
    /// - Parameter kind: The kind of settings.
    /// - Returns: The folder name, or `nil` for the synced root itself.
    private static func folderInRoot(of kind: Kind) -> String? {
        switch kind {
        case .configuration, .agents:
            nil
        case .skills:
            skillsFolderName
        case .rules:
            rulesFolderName
        }
    }
}
