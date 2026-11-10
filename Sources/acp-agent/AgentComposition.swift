import Foundation
import FoundationModelsACPAgent
import FoundationModelsKanban
import FoundationModelsRouter

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

  /// Composes the agent of the CLI through the public library helper
  /// `ComposedAgent.compose(name:workingDirectory:home:environment:modelSource:stubChunkGate:stubScript:transcriptLocation:secretStore:userDeviceTokens:huggingFaceTokenProvider:sessionToolFactories:reporting:)`.
  /// The CLI gives no `transcriptLocation`: its config files decide.
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
    reporting progress: ResolutionProgress? = nil
  ) async throws -> ComposedAgent {
    try await ComposedAgent.compose(
      name: DotfolderName(dotfolderName),
      workingDirectory: workingDirectory,
      home: try home(environment: environment),
      environment: environment,
      modelSource: modelSource(),
      stubChunkGate: stubChunkGate(),
      stubScript: stubScript(),
      sessionToolFactories: [kanbanToolFactory],
      reporting: progress)
  }

  /// The factory of the `kanban` tool of each session. It asks the shared
  /// ``KanbanHost`` for a view of the board of the folder of the session. The
  /// host keeps one engine for each folder, and the view lives as long as the
  /// tool holds it, so the release of the session releases the view. The
  /// Multitool registry of the session mounts the tool under the noun
  /// `kanban`, and the model reaches it with `tools.kanban.runKanban`. The model
  /// writes through this view with the actor of the session. A tunnel call of
  /// a person reaches the same graph, and the graph records the actor of its
  /// viewer. The actor name has the tag of the session, so the `undoChange`
  /// of one session does not reverse the change of another session in the
  /// same folder. The factory makes no tool when `tools.kanban` is off.
  static let kanbanToolFactory: SessionToolFactory = { context in
    guard context.tools.kanban.mountedOptions != nil else { return [] }
    let graph = try await KanbanHost.shared.session(
      workingDirectory: context.workingDirectory, actor: context.actorName)
    return [
      SessionOperationMount(
        noun: KanbanOperationTool.noun, tool: KanbanOperationTool(KanbanTool(graph: graph)))
    ]
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
  /// - Returns: The loader. Construction touches no file.
  /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
  static func makeConfigurationLoader(
    workingDirectory: URL, environment: [String: String],
    secretStore: (any SecretStore)? = nil
  ) throws -> ConfigurationLoader {
    ConfigurationLoader(
      settingsFolders: SettingsFolders(
        name: try DotfolderName(dotfolderName), home: try home(environment: environment),
        environment: environment),
      workingDirectory: workingDirectory,
      secretStore: secretStore)
  }
}
