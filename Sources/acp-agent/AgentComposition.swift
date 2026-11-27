import ACPImport
import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentKanban
import FoundationModelsKanban
import FoundationModelsRouter
import Logging

/// The CLI choices every subcommand shares (cli-plan.md §5.10): the
/// dotfolder name, and the model choice of the executable.
/// `run` and `acp` both build their agent through ``compose(workingDirectory:environment:reporting:)``,
/// so the two modes cannot drift apart.
///
/// The composition itself is the public `ComposedAgent` of the library, so
/// a host that runs the agent in its own process composes the same agent
/// with no copy of this code. There is no configuration wizardry: the
/// dotfolder name is the one choice a frontend makes, and everything else
/// derives.
enum AgentComposition {
  /// The dotfolder name — the frontend's one choice.
  ///
  /// The name roots the configuration stack — `$XDG_CONFIG_HOME/acp-agent/`
  /// of the XDG home for the user layer (``home(environment:)``),
  /// `<cwd>/.acp-agent/` for the project layer — and
  /// the transcript directory, and it is the fallback for the profile's
  /// name. It never goes on the wire: `initialize` reports the package
  /// identity instead, because the dotfolder name is the private choice
  /// of the user.
  static let dotfolderName = "acp-agent"

  /// The model path of the current task: ``AgentModelChoice/live`` unless
  /// the executable that started the CLI chose the stub.
  ///
  /// The executable binds it with `withValue` around the whole run
  /// (``AcpAgentCommand/launch(modelChoice:)``), and a task that the run
  /// starts inherits it. A unit test binds it with a test trait. The
  /// environment never selects the model.
  @TaskLocal static var modelChoice: AgentModelChoice = .live

  /// The environment variable that names the folder of the home of the
  /// CLI (task ^98a44n7). `--home` sets it too (``HomeOptions``). With no
  /// value, the home is the XDG home. See ``home(environment:)``.
  static let homeVariable = "ACP_AGENT_HOME"

  /// The folder of the synced root in the folder of ``homeVariable``.
  static let syncedFolderName = "synced"

  /// The folder of the local root in the folder of ``homeVariable``.
  static let localFolderName = "local"

  /// The environment variable that names the folder of the configuration
  /// of Claude Code, in place of `~/.claude`. The CLI gives that folder as
  /// the Claude Code import root (``importRoots(environment:homeDirectory:)``).
  static let claudeConfigVariable = "CLAUDE_CONFIG_DIR"

  /// The log metadata key of the environment variable that a warning of
  /// the composition names.
  static let variableMetadataKey = "variable"

  /// The log metadata key of the folder that the composition uses in
  /// place of the folder that a variable names.
  static let fallbackMetadataKey = "fallback"

  /// The label of the logger of the composition. Each warning makes a new
  /// logger with this label, so the warning uses the logging system as it
  /// is at the time of the warning.
  private static let logLabel = "\(dotfolderName).composition"

  /// The folder of each source agent in the home folder, when no variable
  /// names it (D209).
  static let importRootFolderNames: [ImportSourceAgent: String] = [
    .claudeCode: ".claude",
    .codex: ".codex",
  ]

  /// The version the CLI reports. One binary and one version: `--version`
  /// prints this, and `initialize` reports the same value as the build
  /// version of its `info`.
  ///
  /// It stands here because the agent type is named in this file alone
  /// (cli-plan.md §4).
  static let version = RoutedACPAgent.buildVersion

  /// What one composition gives: the public `ComposedAgent` of the library.
  ///
  /// The name stands here so that the `run` and `acp` files do not import
  /// the library: they reach the agent through an ACP connection only
  /// (cli-plan.md §4).
  typealias Composed = ComposedAgent

  /// The process working directory, as a directory URL. It roots the
  /// stack of the `acp` mode, and it is the `run` default (§5.4).
  static var processWorkingDirectory: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }

  /// Maps the model choice of the current task to the model path of the
  /// library composition.
  ///
  /// - Returns: `ComposedAgent.ModelSource.stub` for a stub choice, and
  ///   `ComposedAgent.ModelSource.live` otherwise.
  static func modelSource() -> ComposedAgent.ModelSource {
    switch modelChoice {
    case .live: .live
    case .stub: .stub
    }
  }

  /// The path of the chunk gate of the stub model of the current task.
  ///
  /// - Returns: The path of the named pipe, or `nil` for the live path and
  ///   for a stub with no gate.
  static func stubChunkGate() -> String? {
    guard case .stub(let chunkGate, _) = modelChoice else {
      return nil
    }
    return chunkGate
  }

  /// The path of the script file of the stub model of the current task.
  ///
  /// - Returns: The path of the script file, or `nil` for the live path and
  ///   for a stub with no script.
  static func stubScript() -> String? {
    guard case .stub(_, let script) = modelChoice else {
      return nil
    }
    return script
  }

  /// Reads the home of the CLI out of `environment` (task ^98a44n7).
  ///
  /// `--home <dir>` reaches this function as ``homeVariable`` too
  /// (``HomeOptions/environment(over:)``), so the option and the variable
  /// resolve the one way:
  ///
  /// - ``homeVariable`` names a folder: the custom home with the synced
  ///   root ``syncedFolderName`` and the local root ``localFolderName`` in
  ///   that folder, and the projects folder ``AgentHome/projectsFolderName``
  ///   in the synced root. A relative path resolves against the process
  ///   working directory.
  /// - With no ``homeVariable``, or an empty one: the XDG home of
  ///   ``dotfolderName``, which keeps the folders that the CLI always used.
  ///
  /// - Parameter environment: The environment to read. The XDG home also
  ///   reads its XDG and cache variables from it.
  /// - Returns: The home.
  /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
  static func home(environment: [String: String]) throws -> AgentHome {
    guard let path = environment[homeVariable], !path.isEmpty else {
      return .makeXDG(name: try DotfolderName(dotfolderName), environment: environment)
    }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let synced = folder.appendingPathComponent(syncedFolderName, isDirectory: true)
    return .makeCustom(
      synced: synced,
      local: folder.appendingPathComponent(localFolderName, isDirectory: true),
      projects: synced.appendingPathComponent(AgentHome.projectsFolderName, isDirectory: true))
  }

  /// The import roots of the CLI (D209): the folder of each source agent
  /// in the real home folder, `~/.claude` and `~/.codex`. When
  /// ``claudeConfigVariable`` names an absolute folder, that folder is the
  /// Claude Code root. When it names a path that is not absolute, the
  /// root stays `~/.claude`, and the CLI logs a warning that names the
  /// variable and that folder. The CLI runs outside the App Sandbox, so it
  /// can read each root.
  ///
  /// - Parameters:
  ///   - environment: The environment to read.
  ///   - homeDirectory: The home folder of the user.
  /// - Returns: The root of each source agent.
  static func importRoots(environment: [String: String], homeDirectory: URL) -> [ImportSourceAgent: URL] {
    var roots = importRootFolderNames.mapValues {
      homeDirectory.appendingPathComponent($0, isDirectory: true)
    }
    guard let folder = environment[claudeConfigVariable], !folder.isEmpty else { return roots }
    guard folder.hasPrefix("/") else {
      var metadata: Logger.Metadata = [variableMetadataKey: .string(claudeConfigVariable)]
      metadata[fallbackMetadataKey] = roots[.claudeCode].map { .string($0.path) }
      Logger(label: logLabel).warning(
        "The Claude Code configuration folder is not an absolute path. The import root is the folder in the home folder.",
        metadata: metadata)
      return roots
    }
    roots[.claudeCode] = URL(fileURLWithPath: folder, isDirectory: true)
    return roots
  }

  /// Composes the agent of the CLI through the public library helper
  /// `ComposedAgent.compose(name:workingDirectory:home:mode:sandboxProbe:environment:modelSource:stubChunkGate:stubScript:secretStore:userDeviceTokens:huggingFaceTokenProvider:sessionToolFactories:reporting:)`.
  ///
  /// The CLI adds its own choices only: ``dotfolderName``, the home that
  /// ``home(environment:)`` reads, and the model path and the stub gate
  /// that ``modelChoice`` selects. The library does the composition, so the
  /// CLI holds no copy of it.
  ///
  /// The CLI gives no secret store. The default store of the library is
  /// the login Keychain under the service ``dotfolderName``, and that is
  /// the store of the CLI (ACPA-18, D101).
  ///
  /// The CLI gives no Hugging Face token provider. The default provider of
  /// the library, `.environment`, reads `HF_TOKEN`, then
  /// `~/.cache/huggingface/token`, and that is the token of the CLI
  /// (task ^4avf24e).
  ///
  /// The CLI gives the import roots of ``importRoots(environment:homeDirectory:)``
  /// over the real home folder, so `list external sessions` lists the Claude Code and
  /// Codex sessions of the user (D209).
  ///
  /// The CLI always composes in the `open` tool mode (ACPA-19b): it runs
  /// outside the App Sandbox, so each session gets every tool that the
  /// configuration turns on, the shell, the stdio MCP servers and the code
  /// context too.
  ///
  /// With the XDG home, the hooks keep their data and the snapshot
  /// timeline in the XDG data home (ACPA-15, D96), the skills marketplace
  /// store reads its cache folder from `SKILLS_MARKETPLACE_CACHE`, and the
  /// live loader uses the Hugging Face cache that `HF_HUB_CACHE` or
  /// `HF_HOME` names, or `~/.cache/huggingface/hub`.
  ///
  /// - Parameters:
  ///   - workingDirectory: The directory whose dotfolder stack the
  ///     start-up configuration loads from.
  ///   - environment: The environment that ``home(environment:)`` reads
  ///     the home from.
  ///   - homeDirectory: The home folder of the user, which holds the
  ///     folders of the import roots (``importRoots(environment:homeDirectory:)``).
  ///     The real home folder by default. A test gives a temporary folder,
  ///     so the agent does not index the real sessions of other agents.
  ///   - progress: The progress object the resolution reports into, or
  ///     `nil` for a fresh unobserved one. A caller that draws the
  ///     download bar of cli-plan.md §5.7 makes the object first, hands
  ///     it here, and observes the same object while this call runs.
  /// - Returns: The composed agent, the model path it was built over, and
  ///   the configuration the load resolved.
  /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused,
  ///   and whatever the library composition throws. Each is fatal before
  ///   the wire opens.
  static func compose(
    workingDirectory: URL,
    environment: [String: String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    reporting progress: ResolutionProgress? = nil
  ) async throws -> ComposedAgent {
    let composed = try await ComposedAgent.compose(
      name: DotfolderName(dotfolderName),
      workingDirectory: workingDirectory,
      home: try home(environment: environment),
      mode: .open,
      environment: environment,
      modelSource: modelSource(),
      stubChunkGate: stubChunkGate(),
      stubScript: stubScript(),
      sessionToolFactories: [KanbanOperationTool.sessionToolFactory],
      reporting: progress,
      importRoots: importRoots(environment: environment, homeDirectory: homeDirectory))
    // The boards of the content catalog (D214) read the folders through the shared host.
    composed.useBoardContentSource(KanbanBoardContentSource())
    return composed
  }

  /// Makes the loader of `workingDirectory`'s stack under
  /// ``dotfolderName`` — the one construction the `config` reports and
  /// `doctor` share (cli-plan.md §5.10, §5.11).
  ///
  /// The stacks of its ``SettingsFolders`` take their user layers from the
  /// home that ``home(environment:)`` reads, the same home as the agent of
  /// ``compose(workingDirectory:environment:reporting:)``. The loader keeps
  /// the settings folders (``ConfigurationLoader/settingsFolders``), so
  /// `doctor` reads the home and the skills and agents stacks of the same
  /// folders.
  ///
  /// - Parameters:
  ///   - workingDirectory: The directory the project layer roots under.
  ///   - environment: The environment that ``home(environment:)`` reads
  ///     the home from.
  ///   - secretStore: The store that gives the value of each secret
  ///     reference `keychain:<name>`, or `nil` (the default) for the login
  ///     Keychain under the service ``dotfolderName``: the store of the CLI
  ///     (ACPA-18, D101). A test gives an in-memory store.
  ///   - fallbackProfileName: The profile of a load where no layer sets
  ///     `profile`, or where the name is unknown. A command that loads
  ///     gives ``fallbackProfileName(workingDirectory:environment:secretStore:fitSource:)``. The default
  ///     is ``BundledProfiles/smallestName``, for a command that only reads
  ///     the stack.
  /// - Returns: The loader. Construction touches no file.
  /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
  static func makeConfigurationLoader(
    workingDirectory: URL, environment: [String: String],
    secretStore: (any SecretStore)? = nil,
    fallbackProfileName: String = BundledProfiles.smallestName
  ) throws -> ConfigurationLoader {
    ConfigurationLoader(
      settingsFolders: try settingsFolders(environment: environment),
      workingDirectory: workingDirectory,
      secretStore: secretStore,
      fallbackProfileName: fallbackProfileName)
  }

  /// The settings folders of the CLI: the folders of ``dotfolderName`` over
  /// the home of ``home(environment:)``. Each command that reads or writes
  /// the settings of the CLI builds its store over these folders.
  ///
  /// - Parameter environment: The environment that the home and the
  ///   defaults layer are read from.
  /// - Returns: The settings folders. The call reads no file.
  /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
  static func settingsFolders(environment: [String: String]) throws -> SettingsFolders {
    SettingsFolders(
      name: try DotfolderName(dotfolderName), home: try home(environment: environment),
      environment: environment)
  }

  /// The profile of a load of the CLI where no layer sets `profile`: the
  /// choice of ``BundledProfiles/fallbackName(using:)``, the same function
  /// that the agent of ``compose(workingDirectory:environment:homeDirectory:reporting:)``
  /// calls, over a router with the same cluster mode as the router of the
  /// agent: the mode of the `cluster:` section of the user level.
  ///
  /// - Parameters:
  ///   - workingDirectory: The directory the loader of the section roots
  ///     under (``makeConfigurationLoader(workingDirectory:environment:secretStore:fallbackProfileName:)``).
  ///     The section is read from the user level only.
  ///   - environment: The environment that ``home(environment:)`` reads
  ///     the home from.
  ///   - secretStore: The store that gives the value of each login secret
  ///     of the section, or `nil` (the default) for the login Keychain of
  ///     the CLI. The first fit reads it, not this call's setup.
  ///   - fitSource: The fit source, or `nil` (the default) for the router
  ///     of ``modelChoice`` (`ComposedAgent.makeProfileFitSource`). A test
  ///     gives a stub.
  /// - Returns: The name of a bundled profile. `small` when no fit source
  ///   can be made, or when the section does not load.
  static func fallbackProfileName(
    workingDirectory: URL, environment: [String: String],
    secretStore: (any SecretStore)? = nil, fitSource: (any ProfileFitEstimating)? = nil
  ) async -> String {
    let source =
      fitSource
      ?? (try? makeConfigurationLoader(
        workingDirectory: workingDirectory, environment: environment, secretStore: secretStore)
      ).map { loader in
        ComposedAgent.makeProfileFitSource(
          for: modelSource(), home: loader.settingsFolders.home, userLevelOf: loader)
      }
    return await BundledProfiles.fallbackName(using: source)
  }
}
