import Foundation
import FoundationModelsExtras
import FoundationModelsMultitool

/// The one list of folders that each settings stack of the agent comes from
/// (ACPA-16, D98): `config.yaml` and `Instructions.md`, the skills, the
/// agents and the rules.
///
/// Each stack has three levels, lowest precedence first:
///
/// 1. The built-in level: the defaults layer that the environment variable
///    `<NAME>_DEFAULTS_DIR` names (the dotfolder name of the kind in upper
///    case). When the variable is not set, the skills stack has the folder
///    of the built-in skills of Multitool (`BuiltinSkills.directory`, D200)
///    as this layer, and each other kind has no layer. The builtin file
///    `builtin.config.yaml` is not a layer of the stack:
///    ``ConfigurationLoader`` puts it under the stack.
/// 2. The user level, which the ``AgentHome`` of the host gives (task
///    ^98a44n7). With a custom home it is a folder in the synced root:
///    `<synced>/` for `config.yaml` and `Instructions.md`, `<synced>/_skills/`
///    for the skills, and `<synced>/` for the agents. The settings folders
///    in the root start with `_`, because a name that starts with `_` is
///    never a valid agent id. With the XDG home of the `acp-agent` CLI, it
///    is the XDG folder of the dotfolder name of the kind,
///    `$XDG_CONFIG_HOME/<dotfolder>/` or `~/.config/<dotfolder>/`.
/// 3. The session level: the project dotfolder `<cwd>/.<dotfolder>/` of the
///    working directory of the session. It wins.
///
/// The rules follow TestudoApp decision D63 and the plan of
/// FoundationModelsRules, not the pattern above:
///
/// - The user level of a custom home is `Rules/` next to the synced root
///   (`<iCloud container>/Rules/` next to `Agents/`). With the XDG home, it
///   is `$XDG_CONFIG_HOME/agents/rules/`.
/// - The session level is `<cwd>/.agents/rules/`. The name `.rules` is not
///   used, because Zed has a `.rules` file.
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

    /// The rules, in the folders of D63: ``rulesUserFolderName`` next to
    /// the synced root, or `agents/rules/` in the XDG config home, and
    /// `<cwd>/.agents/rules/`. FoundationModelsRules reads no stack yet,
    /// thus only the folders are set here.
    case rules
  }

  /// The folder in the synced root of a custom home that holds the skills.
  public static let skillsFolderName = "_skills"

  /// The folder in an agent folder that holds the rules of that agent:
  /// the agent layer of D63, `<agent folder>/_rules/`. The name starts with
  /// `_`, thus a `_rules/` folder in the synced root is never an agent.
  public static let rulesFolderName = "_rules"

  /// The name of the rules stack: the prefix of its defaults variable
  /// `RULES_DEFAULTS_DIR`, and the folder of the rules in the agents
  /// dotfolder (`<cwd>/.agents/rules/`, `$XDG_CONFIG_HOME/agents/rules/`).
  public static let rulesDotfolderName = "rules"

  /// The folder next to the synced root of a custom home that holds the
  /// user rules: `<iCloud container>/Rules/` next to `Agents/` (D63).
  public static let rulesUserFolderName = "Rules"

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
    if case .rules = kind {
      return rulesStack(workingDirectory: workingDirectory)
    }
    return DotfolderStack(
      name: dotfolder, workingDirectory: workingDirectory,
      defaultsDirectory: Self.builtinDirectory(of: kind),
      userDirectory: home.userLayerRoot(
        dotfolder: dotfolder, folderInRoot: Self.folderInRoot(of: kind)),
      environment: environment)
  }

  /// The rules stack of D63: the defaults layer of `RULES_DEFAULTS_DIR`,
  /// when it is set, the user rules folder of the home, and
  /// `<workingDirectory>/.agents/rules/`.
  ///
  /// - Parameter workingDirectory: The working directory of the session.
  /// - Returns: The stack.
  private func rulesStack(workingDirectory: URL) -> DotfolderStack {
    let derived = DotfolderStack(
      name: Self.rulesDotfolderName, workingDirectory: workingDirectory,
      userDirectory: rulesUserFolder, environment: environment)
    let project = workingDirectory
      .appendingPathComponent(".\(ToolCatalog.agentsDotfolderName)", isDirectory: true)
      .appendingPathComponent(Self.rulesDotfolderName, isDirectory: true)
    return DotfolderStack(
      layers: derived.layers.map {
        $0.source == .project ? DotfolderStack.Layer(source: .project, root: project) : $0
      })
  }

  /// The user rules folder of the home: ``rulesUserFolderName`` next to
  /// the synced root of a custom home, or `<config home>/agents/rules/` of
  /// the XDG home.
  private var rulesUserFolder: URL {
    switch home.settingsLayout {
    case .xdg(let configHome):
      configHome
        .appendingPathComponent(ToolCatalog.agentsDotfolderName, isDirectory: true)
        .appendingPathComponent(Self.rulesDotfolderName, isDirectory: true)
    case .rooted:
      home.synced.deletingLastPathComponent()
        .appendingPathComponent(Self.rulesUserFolderName, isDirectory: true)
    }
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

  /// The built-in defaults layer of `kind`: the folder that the stack uses
  /// as its defaults layer when the environment names no
  /// `<NAME>_DEFAULTS_DIR`.
  ///
  /// Only the skills have a built-in layer: the skills that Multitool ships
  /// (D200). A write never goes to this layer (D175), thus a skill with
  /// the same name in the user layer or in the project layer replaces a
  /// built-in skill.
  ///
  /// - Parameter kind: The kind of settings.
  /// - Returns: The folder, or `nil` for no built-in layer.
  private static func builtinDirectory(of kind: Kind) -> URL? {
    switch kind {
    case .skills:
      BuiltinSkills.directory
    case .configuration, .agents, .rules:
      nil
    }
  }

  /// The folder of the user layer of `kind` in the synced root of a custom
  /// home.
  ///
  /// - Parameter kind: The kind of settings.
  /// - Returns: The folder name, or `nil` for the synced root itself.
  private static func folderInRoot(of kind: Kind) -> String? {
    switch kind {
    case .configuration, .agents, .rules:
      nil
    case .skills:
      skillsFolderName
    }
  }
}
