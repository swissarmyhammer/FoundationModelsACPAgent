import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsHooks
import FoundationModelsRouter
import HuggingFace

/// The composed agent of a host: the configuration stack of a dotfolder
/// name, a router over a model path, and the `RoutedACPAgent` that
/// resolves the profile (cli-plan.md §5.10).
///
/// The work has two steps, and only the first one is slow or can fail:
///
/// 1. ``compose(name:workingDirectory:home:mode:sandboxProbe:environment:modelSource:stubChunkGate:stubScript:transcriptLocation:secretStore:userDeviceTokens:huggingFaceTokenProvider:sessionToolFactories:reporting:)``
///    loads the configuration, builds the router and resolves the profile.
///    It is `async` and `throws`. A host calls it one time, before it opens
///    a connection.
/// 2. ``agent(boundTo:)`` binds the composed agent to one
///    `AgentSideConnection` and gives it back as `any Agent`. It is
///    synchronous and does not throw, so the factory closure of
///    `AgentSideConnection` calls it directly. It starts no transport and
///    no serve loop of its own.
///
/// A host that runs the agent in its own process writes:
///
/// ```swift
/// let composed = try await ComposedAgent.compose(
///     name: try DotfolderName("my-host"), workingDirectory: projectDirectory,
///     home: .makeCustom(synced: syncedFolder, local: localFolder, projects: projectsFolder),
///     mode: .sandboxed)
/// let connection = await AgentSideConnection(stream: transport) { connection in
///     composed.agent(boundTo: connection)
/// }
/// ```
///
/// ``serve(over:logger:)`` does the same two lines in one call. The
/// `acp-agent` executable uses it for its stdio and in-process modes.
///
/// After the connection closed, and before the process ends, the host
/// calls ``waitForConnectionTeardown()`` and then ``closeOpenSessions()``,
/// so the agent closes each open session.
///
/// Where a frontend appends its own tools: `ToolCatalog`
/// is the one place this package composes the per-session tool surface.
/// A capability behind the code-mode surface is one
/// `builder.withCapability(myCapability)` call in
/// `ToolCatalog.makeRegistry(context:)`; a stand-alone tool is one plain
/// `FoundationModels.Tool` appended in `ToolCatalog.sessionSurface(context:)`,
/// the way the `skills` tool is.
public struct ComposedAgent: Sendable {
  /// Which model path the router resolves the profile through.
  public enum ModelSource: Equatable, Sendable {
    /// `LiveModelLoader`, which loads each model through the Extras
    /// `MLXModelLoader`: the configured models download on first use
    /// and load as resident weights. Nothing here is scripted or
    /// stubbed.
    case live

    /// The library's deterministic `EchoModel` path: every session
    /// answers a prompt with the prompt itself, no metadata is
    /// fetched, no weights download, and nothing loads.
    case stub
  }

  /// The prefix of the throwaway cache directory a stub router writes
  /// its stub metadata under. The real caches directory must never hold
  /// that metadata: it names real model ids, and a later live run would
  /// read the fake sizes back.
  private static let stubCacheDirectoryPrefix = "acp-agent-stub-cache-"

  /// The prefix of the throwaway directory the router's own recordings
  /// root stands at — see ``makeRecordingsDirectory()``.
  private static let recordingsDirectoryPrefix = "acp-agent-recordings-"

  /// The composed agent, with its profile resolved.
  public let agent: RoutedACPAgent

  /// The model path ``agent`` resolves through.
  public let modelSource: ModelSource

  /// The configuration of the start-up load — the first of the two
  /// loads of cli-plan.md §5.10, keyed by the directory this
  /// composition was built for. Each session later loads its own
  /// stack again, keyed by the session's `cwd`.
  public let configuration: AgentConfiguration

  /// Composes the agent: the configuration of `workingDirectory`'s
  /// stack under `name`, a router over `modelSource`, and the
  /// `RoutedACPAgent` construction that resolves the profile.
  ///
  /// The layered `config.yaml` of `workingDirectory` selects the profile
  /// the agent resolves at start. With no file in any
  /// layer the in-code default applies. Each session later loads its own
  /// stack again, keyed by the session's `cwd`.
  ///
  /// The composition also makes the ``AgentHooks`` of the agent, in the
  /// ``AgentHome/hooksDirectory`` of `home`, and gives its dispatcher to
  /// the router and to the agent.
  ///
  /// Call this one time, before the first connection. Then give each
  /// connection the agent with ``agent(boundTo:)``.
  ///
  /// - Parameters:
  ///   - name: The dotfolder name the host chose. It
  ///     roots the configuration stack and the transcript directory.
  ///   - workingDirectory: The directory whose dotfolder stack the
  ///     start-up configuration loads from.
  ///   - home: The home of the host (task ^98a44n7). Each folder outside
  ///     the project comes from it: the user layer of each settings stack
  ///     (``SettingsFolders``), the hook data and the snapshot timelines,
  ///     the skills marketplace cache, the model cache, the metadata cache
  ///     of the router, the project store, and the machine state of each
  ///     project. An app gives ``AgentHome/makeCustom(synced:local:projects:)``
  ///     with two folders of its iCloud container and a folder in
  ///     Application Support; never a folder in
  ///     Caches or in a temporary folder for the local root, because macOS
  ///     can delete those, and the snapshot timelines and the models must
  ///     persist. The `acp-agent` CLI gives
  ///     ``AgentHome/makeXDG(name:environment:)``. The model check of `doctor`
  ///     reads the model cache of the same home.
  ///   - mode: The tool mode of the host (ACPA-19b, D128 (d)). It has no
  ///     default value, so a host must select one. `validate(probe:)`
  ///     refuses `.open` in a sandboxed process. In `.sandboxed` no
  ///     session gets a tool that starts a child process: no shell, no
  ///     stdio MCP server and no code context. An app in the App Sandbox
  ///     gives `.sandboxed`; the `acp-agent` CLI gives `.open`. The
  ///     `initialize` result gives the mode in `_meta.sah.mode`
  ///     (``RoutedACPAgent/toolMode``).
  ///   - sandboxProbe: The probe that tells if the process is sandboxed.
  ///     The default reads the current process. A test gives
  ///     `.fixed(_:)`.
  ///   - openTestudoDownloadURL: The URL of the download page of
  ///     OpenTestudo, or `nil` (the default) for none (ACPA-19c, D128 (i)).
  ///     In `.sandboxed` the instructions of each session tell the user
  ///     that work that needs a child process needs OpenTestudo, and give
  ///     this URL (``RoutedACPAgent/openTestudoDownloadURL``). With `nil`,
  ///     the instructions give no link. In `.open` the instructions do not
  ///     name OpenTestudo.
  ///   - environment: The environment the stacks read their defaults
  ///     layer from, and the session tools read. The process environment
  ///     by default.
  ///   - modelSource: The model path to build the router over.
  ///     ``ModelSource/live`` by default.
  ///   - stubChunkGate: The path of a named pipe that a stub answer reads
  ///     one byte from before each chunk, or `nil` (the default) for the
  ///     one-chunk echo. Only ``ModelSource/stub`` reads it. A test holds
  ///     a prompt open with it, with no clock.
  ///   - stubScript: The path of a JSON script file for the stub model
  ///     (``ScriptedStubScript``), or `nil` (the default) for the echo. Only
  ///     ``ModelSource/stub`` reads it. Each session of the stub model then
  ///     plays the entry of the script that its first prompt matches, and
  ///     echoes when no entry matches. The script has its own `gate` step,
  ///     thus `stubChunkGate` is not read when a script is given.
  ///   - transcriptLocation: The transcript location that wins over the
  ///     `transcripts.location` of every config layer, or `nil` (the
  ///     default) to let the config files decide. A host that runs the
  ///     agent in its own process sets it here, and needs no config file
  ///     for it. The start-up load and each later session request use
  ///     it: `session/new`, `session/resume`, `session/list` and
  ///     `session/delete` (``RoutedACPAgent/transcriptLocation``). The
  ///     override is not a config layer, so `config show` and
  ///     `LoadedConfiguration.sources` do not show it.
  ///   - secretStore: The store that gives the value of each secret
  ///     reference `keychain:<name>` of the configuration, or `nil` (the
  ///     default) for the login Keychain under the service `name`. An app
  ///     gives the synchronizable items of iCloud Keychain here
  ///     (`KeychainSecretStore(service:synchronizable:)` with
  ///     `synchronizable: true`).
  ///   - userDeviceTokens: The bearer tokens of the devices of the user, or
  ///     none (the default). A host that serves ACP over HTTP gives the
  ///     token of each paired device here; a connection with one of them
  ///     is `userDevice`, and a connection with any other token is
  ///     `external` (``RoutedACPAgent/userDeviceTokens``). The `acp-agent`
  ///     CLI gives no value: its stdio and in-process connections carry no
  ///     token and are `userDevice`.
  ///   - huggingFaceTokenProvider: The provider of the Hugging Face token
  ///     of the host (task ^4avf24e), a `TokenProvider` of swift-huggingface.
  ///     The live router sends its token on each download of a model and on
  ///     each sizing request of the model metadata. The default
  ///     `.environment` reads `HF_TOKEN`, then `~/.cache/huggingface/token`,
  ///     as the `acp-agent` CLI always did. An app gives its own provider,
  ///     for example `.custom { ... }` over its Keychain, so the agent does
  ///     not read the token in the Hugging Face folder of the user. The stub
  ///     path ignores it, because it downloads and sizes nothing.
  ///   - progress: The progress object the resolution reports into, or
  ///     `nil` for a fresh unobserved one. A caller that draws a
  ///     download bar makes the object first, hands it here, and
  ///     observes the same object while this call runs: the whole
  ///     resolution stands inside the agent's construction, so nothing
  ///     can be observed after this returns.
  ///   - sessionToolFactories: Factories of tools for each session. The
  ///     composition of each session runs them with the context of the
  ///     session (``SessionToolContext``), and mounts the tools after the
  ///     tools of the catalog. The default is none.
  /// - Returns: The composed agent, the model path it was built over, and
  ///   the configuration the load resolved.
  /// - Throws: `ToolModeError.openModeInSandbox` when `mode` is `.open` in
  ///   a sandboxed process, before any other work; the configuration load
  ///   errors, the creation error of a
  ///   throwaway directory of the router, or `ProfileResolutionError`
  ///   when the profile does not resolve. Each is fatal before the wire
  ///   opens.
  public static func compose(
    name: DotfolderName,
    workingDirectory: URL,
    home: AgentHome,
    mode: ToolMode,
    sandboxProbe: SandboxProbe = .live,
    openTestudoDownloadURL: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    modelSource: ModelSource = .live,
    stubChunkGate: String? = nil,
    stubScript: String? = nil,
    transcriptLocation: TranscriptLocation? = nil,
    secretStore: (any SecretStore)? = nil,
    userDeviceTokens: Set<String> = [],
    huggingFaceTokenProvider: TokenProvider = .environment,
    sessionToolFactories: [SessionToolFactory] = [],
    reporting progress: ResolutionProgress? = nil
  ) async throws -> ComposedAgent {
    // The check comes first, so a wrong mode fails before the router
    // builds and before any tool registers.
    try mode.validate(probe: sandboxProbe)
    let configuration = try ConfigurationLoader(
      settingsFolders: SettingsFolders(name: name, home: home, environment: environment),
      workingDirectory: workingDirectory, transcriptLocation: transcriptLocation,
      secretStore: secretStore
    ).load().configuration
    let hooks = AgentHooks(dataDirectory: home.hooksDirectory)
    let agent = try await RoutedACPAgent(
      name: name,
      router: try makeRouter(
        for: modelSource,
        gatedBy: stubChunkGate,
        scriptedBy: stubScript,
        recordingInto: try makeRecordingsDirectory(),
        hooks: hooks.dispatcher,
        home: home,
        huggingFaceTokenProvider: huggingFaceTokenProvider),
      hooks: hooks,
      configuration: configuration,
      reporting: progress,
      home: home,
      mode: mode,
      sandboxProbe: sandboxProbe,
      openTestudoDownloadURL: openTestudoDownloadURL,
      environment: environment,
      transcriptLocation: transcriptLocation,
      secretStore: secretStore,
      userDeviceTokens: userDeviceTokens)
    await agent.registerSessionToolFactories(sessionToolFactories)
    return ComposedAgent(
      agent: agent, modelSource: modelSource, configuration: configuration)
  }

  /// Binds one more connection to ``agent`` (ACPA-5) and gives back the
  /// `Agent` that serves it: a ``RoutedACPConnection`` that names the
  /// connection on each call. An earlier connection stays bound.
  ///
  /// Call it from the factory closure of `AgentSideConnection`. It is
  /// synchronous and does not throw. It starts no transport and no serve
  /// loop: the connection that called it serves the agent.
  ///
  /// - Parameter connection: The connection around the agent.
  /// - Returns: The `Agent` of `connection`.
  public func agent(boundTo connection: AgentSideConnection) -> any Agent {
    agent.bind(connection: connection)
  }

  /// Binds ``agent`` to the agent side of `transport`, so a client
  /// on the other end drives it over ACP.
  ///
  /// The `acp-agent` executable hands the agent to a connection here
  /// alone. `run` gives one end of `InMemoryTransport.pair()`, and `acp`
  /// gives stdin and stdout; nothing else about the two modes differs
  /// (cli-plan.md §4).
  ///
  /// - Parameters:
  ///   - transport: The wire end the agent serves on.
  ///   - logger: The diagnostic sink of the connection. It writes
  ///     to stderr or nowhere, never to stdout (cli-plan.md §5.6).
  /// - Returns: The bound connection.
  public func serve(
    over transport: any ACPTransport, logger: ACPLogger = .disabled
  ) async -> AgentSideConnection {
    await AgentSideConnection(stream: transport, logger: logger) { connection in
      agent(boundTo: connection)
    }
  }

  /// Waits until ``agent`` removed the row of each connection that
  /// ``agent(boundTo:)`` bound, after the close of that connection, and
  /// freed its sessions (``RoutedACPAgent/waitForConnectionTeardown()``).
  ///
  /// A closed connection does not close its sessions: they go on with no
  /// owner (ACPA-5d, D68). A host that ends its process calls this, and
  /// then ``closeOpenSessions()``.
  public func waitForConnectionTeardown() async {
    await agent.waitForConnectionTeardown()
  }

  /// Closes each open session of ``agent``, as `session/close` does, at
  /// the end of the host (``RoutedACPAgent/closeOpenSessions()``).
  ///
  /// A host does not have to send `session/close`: it calls this after
  /// its connections closed and before the process exits, so the agent
  /// writes the history of each session and stops its MCP servers.
  public func closeOpenSessions() async {
    await agent.closeOpenSessions()
  }

  /// The orderly shutdown of the host at the end of the process
  /// (``RoutedACPAgent/shutdown()``): the live sessions are suspended first, and the working
  /// agent runs stay restorable.
  public func shutdown() async {
    await agent.shutdown()
  }

  /// The end of the host process, in the one correct order: runs the orderly shutdown
  /// (``shutdown()``), and then waits until the connections are torn down
  /// (``waitForConnectionTeardown()``) (``RoutedACPAgent/shutdownAfterConnectionTeardown()``).
  ///
  /// `acp-agent acp` and `acp-agent run` call it when the process ends. The order matters:
  /// a closed connection is torn down only after its open prompts end, so the shutdown must pause
  /// the open work first.
  public func shutdownAfterConnectionTeardown() async {
    await agent.shutdownAfterConnectionTeardown()
  }

  /// Makes the router of one model path.
  ///
  /// Both paths take the recordings directory, because that directory is
  /// what sets the recorder on: a router built without one holds the
  /// no-op sink, and every event of every session drops.
  /// Each session then names its own root, and Router records the
  /// session to `<root>/<sessionId>/`.
  ///
  /// The live loader takes no progress callback. The callback of its
  /// init receives only the loads of the Extras model pool. A router load
  /// gives its download bytes to the `ResolutionProgress` of the resolve,
  /// and the download bar of cli-plan.md §5.7 observes that object.
  ///
  /// - Parameters:
  ///   - modelSource: The model path to build the router over.
  ///   - chunkGate: The path of the named pipe of a stub answer, or
  ///     `nil` for the library's one-chunk echo. The live path ignores
  ///     it.
  ///   - stubScript: The path of the script file of the stub model, or
  ///     `nil` for the echo. The live path ignores it. A script wins over
  ///     `chunkGate`.
  ///   - recordingsDirectory: The router's own recordings root — see
  ///     ``makeRecordingsDirectory()``.
  ///   - hooks: The dispatcher that each session of the router sends its
  ///     hook events to: the ``AgentHooks/dispatcher`` of the agent.
  ///   - home: The home of the host. The live path takes the metadata cache
  ///     of the router (``AgentHome/routerCacheDirectory``) and the model
  ///     cache (``AgentHome/modelCacheDirectory``) from it. The stub path
  ///     ignores it, because it downloads nothing and keeps its stub
  ///     metadata in a throwaway folder.
  ///   - huggingFaceTokenProvider: The provider of the Hugging Face token of
  ///     the host. The live path gives it to the loader, for each download,
  ///     and to the `HuggingFaceMetadataSource` of the router, for each
  ///     sizing request. The stub path ignores it.
  /// - Returns: A router over `LiveModelLoader` for ``ModelSource/live``,
  ///   or the library's `EchoModel` router — stub machine, stub
  ///   metadata, echo loader — for ``ModelSource/stub``.
  /// - Throws: The directory-creation error of the stub cache, or the
  ///   ``ScriptedStubScriptError`` of a script file that cannot be read or
  ///   is not valid.
  static func makeRouter(
    for modelSource: ModelSource,
    gatedBy chunkGate: String?,
    scriptedBy stubScript: String? = nil,
    recordingInto recordingsDirectory: URL,
    hooks: HookDispatcher,
    home: AgentHome,
    huggingFaceTokenProvider: TokenProvider
  ) throws -> Router {
    switch modelSource {
    case .live:
      Router(
        cacheDir: home.routerCacheDirectory,
        recordingsDir: recordingsDirectory,
        metadataSource: HuggingFaceMetadataSource(tokenProvider: huggingFaceTokenProvider),
        loader: makeLiveModelLoader(
          modelCacheDirectory: home.modelCacheDirectory, tokenProvider: huggingFaceTokenProvider),
        hooks: hooks)
    case .stub:
      EchoModel.makeRouter(
        cacheDirectory: try makeStubCacheDirectory(),
        recordingsDirectory: recordingsDirectory,
        loader: try makeStubLoader(gatedBy: chunkGate, scriptedBy: stubScript),
        hooks: hooks)
    }
  }

  /// Makes the loader of the live path over one model cache folder and one
  /// token provider.
  ///
  /// - Parameters:
  ///   - modelCacheDirectory: The Hugging Face hub cache folder of the home
  ///     (``AgentHome/modelCacheDirectory``). Each download writes to it,
  ///     and each load reads the weights from it, also when `HF_HUB_CACHE`
  ///     or `HF_HOME` of the process names a different folder.
  ///   - tokenProvider: The provider of the Hugging Face token of the host,
  ///     which each download sends.
  /// - Returns: The live loader over that cache.
  static func makeLiveModelLoader(modelCacheDirectory: URL, tokenProvider: TokenProvider)
    -> LiveModelLoader
  {
    LiveModelLoader(cacheDirectory: modelCacheDirectory, tokenProvider: tokenProvider)
  }

  /// Makes the loader of the stub path.
  ///
  /// - Parameters:
  ///   - chunkGate: The path of the named pipe, or `nil`.
  ///   - stubScript: The path of the script file, or `nil`.
  /// - Returns: A loader over ``ScriptedLLMContainer`` when `stubScript` is
  ///   given. Else the library's own stub loader when `chunkGate` is `nil`,
  ///   and one over ``GatedEchoLLMContainer`` otherwise. Each container of
  ///   the loader shares one ``StubChunkGate``.
  /// - Throws: The ``ScriptedStubScriptError`` of a script file that cannot
  ///   be read or is not valid. The file is read here, once, so a bad file
  ///   stops the composition before the wire opens.
  private static func makeStubLoader(
    gatedBy chunkGate: String?, scriptedBy stubScript: String?
  ) throws -> StubModelLoader {
    if let stubScript {
      let script = try ScriptedStubScript.load(fromPath: stubScript)
      return StubModelLoader { _ in ScriptedLLMContainer(playbook: .sessions(script)) }
    }
    guard let chunkGate else {
      return StubModelLoader()
    }
    let gate = StubChunkGate(path: chunkGate)
    return StubModelLoader { _ in GatedEchoLLMContainer(gate: gate) }
  }

  /// Makes a fresh throwaway directory for a stub router's cache — see
  /// ``stubCacheDirectoryPrefix``.
  ///
  /// - Returns: The created directory, under the temporary directory.
  /// - Throws: The directory-creation error.
  private static func makeStubCacheDirectory() throws -> URL {
    try makeThrowawayDirectory(prefix: stubCacheDirectoryPrefix)
  }

  /// Makes the router's own recordings root: a fresh throwaway
  /// directory, one for each composition.
  ///
  /// The router root is the switch, and not a destination. Router writes
  /// each session to the root that session was given — the project's
  /// `transcripts.location` — so nothing a user reads is written here.
  /// Three facts make a throwaway directory the correct switch:
  ///
  /// - `JSONLRecorder` locks its own root. Two agent processes in one
  ///   project would then contend for one lock, and the process that
  ///   loses records nothing. A root per process cannot contend.
  /// - A session that names no root of its own records under the router
  ///   root. The librarian sessions of the tool catalog are such
  ///   sessions, and a project root would mix them into the project's
  ///   own transcripts.
  /// - An `acp` server opens sessions in directories other than the one
  ///   it started in, so its start-up directory must not become a
  ///   recording root.
  ///
  /// - Returns: The created directory, under the temporary directory.
  /// - Throws: The directory-creation error.
  private static func makeRecordingsDirectory() throws -> URL {
    try makeThrowawayDirectory(prefix: recordingsDirectoryPrefix)
  }

  /// Makes a fresh directory under the temporary directory, named
  /// `prefix` and a new UUID.
  ///
  /// - Parameter prefix: The name prefix, which says what the directory
  ///   is for.
  /// - Returns: The created directory.
  /// - Throws: The directory-creation error.
  private static func makeThrowawayDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
