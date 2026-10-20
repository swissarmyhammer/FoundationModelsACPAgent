import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsHooks
import FoundationModelsRouter
import Logging
import Synchronization

/// The composed ACP agent over the Router runtime.
///
/// This is the wire package's `Agent` conformance. Each ACP noun names its
/// peer in the Router stack, and a noun with no peer is off, honestly. The
/// runtime stays wire-free: `RoutedSession` is Router's session surface, and
/// this type translates between it and the protocol.
///
/// The handshake lives in `Agent/Initialization.swift`: the
/// implementation identity, the protocol version negotiation, the advertised
/// capabilities, and the reading of the client's capabilities.
///
/// There is no authentication surface: a local on-device agent has
/// nothing to authenticate. The `initialize`
/// response omits `authMethods` and `capabilities.auth`, so `auth/login` and
/// `auth/logout` keep the wire package's default: `-32601`, the method is not
/// available on this agent. The agent never raises `-32000`.
///
/// `session/new` lives in `Agent/SessionSetup.swift`: the
/// per-cwd composition pipeline and the actor-held session table. Each
/// remaining session handler lives beside it in its own `Agent/` file, and
/// the file comments below name where.
public actor RoutedACPAgent: Agent {
    /// The frontend-supplied dotfolder name. It roots the
    /// configuration stack and the transcript directory. It never goes on
    /// the wire, because it is the private choice of the user:
    /// `initialize` reports ``implementation`` instead.
    public let name: DotfolderName

    /// The resident profile, resolved at construction and held strongly
    /// for the life of the agent.
    ///
    /// Every `RoutedModel` holds its owning profile weakly, and each
    /// public `makeSession` traps once the profile is released; only the
    /// vended session retains it. This reference keeps the resident
    /// models alive between sessions.
    public nonisolated let residentProfile: LanguageModelProfile

    /// The client's capabilities as read at the latest `initialize`, or
    /// `nil` before the first one.
    ///
    /// The order rule reads this: a `session/*` request that finds it `nil`
    /// came before `initialize`, and is refused.
    public internal(set) var negotiatedClientCapabilities: NegotiatedClientCapabilities?

    /// The settings folders of the agent (ACPA-16, D98): ``name``, the root
    /// settings folder of the host, and ``environment``. Each stack of each
    /// session comes from them: the configuration stack of each
    /// ``makeConfigurationLoader(workingDirectory:)`` and the skills and
    /// agents stacks of each ``CatalogContext``.
    nonisolated let settingsFolders: SettingsFolders

    /// The environment of the host. The per-session dotfolder stacks read
    /// their defaults layer from it, and with no root settings folder
    /// `XDG_CONFIG_HOME` too. Each session composition gives it to its
    /// ``CatalogContext``, so the session tools read the values that the
    /// host gave (``CatalogContext/environment``).
    nonisolated let environment: [String: String]

    /// The transcript location that the host gave in code, or `nil` when
    /// the config files decide.
    ///
    /// Each session request loads the configuration of its `cwd` again, and
    /// each of those loads goes through ``makeConfigurationLoader(workingDirectory:)``,
    /// which gives this value to the loader. Thus `session/new`,
    /// `session/resume`, `session/list` (with a `cwd` filter and across the
    /// project registry) and `session/delete` all record or read under this
    /// location, and it wins over the `transcripts.location` of every config
    /// layer.
    public nonisolated let transcriptLocation: TranscriptLocation?

    /// The store that gives the value of each secret reference
    /// `keychain:<name>` of the configuration (ACPA-18, D101).
    ///
    /// The host gives it, or the initializer sets the login Keychain under
    /// the service ``name``. The configuration load reads the references
    /// through it.
    nonisolated let secretStore: any SecretStore

    /// The settle period of each session that this agent makes, in seconds:
    /// the ``CatalogContext/inlineSettleGrace`` of each session composition.
    /// The initializer sets ``CatalogContext/defaultInlineSettleGrace``, the
    /// one source of the value, when the caller gives no value. A test gives
    /// an other value, so that it can see the value in each session.
    nonisolated let inlineSettleGrace: TimeInterval

    /// The live sessions, keyed by the ACP session id. The ACP session
    /// id is the ULID of the root Router session.
    /// Each entry carries its own config, instructions, confinement,
    /// transcript directory, and idle/busy state.
    var sessions: [SessionId: ActiveSession] = [:]

    /// The waits of ``awaitPromptsFinished(of:)``, keyed by the session.
    /// ``promptFinished(_:sessionId:)`` resumes them when the session has no
    /// open prompt and the end work of the last prompt is done, and
    /// ``markSessionClosed(_:)`` resumes them when the session closes.
    var promptsFinishedWaits: [SessionId: [CheckedContinuation<Void, Never>]] = [:]

    /// The count of the end works of ``promptFinished(_:sessionId:)`` that
    /// run now, keyed by the session. A session with no running end work has
    /// no key.
    var promptEndWorkCount: [SessionId: Int] = [:]

    /// Records the number of open sessions in the `active_sessions` gauge
    /// (``AgentMetrics``).
    ///
    /// A closed session stays in ``sessions`` so that it stays resumable, so
    /// the count reads the entries that are not closed. Call it each time a
    /// session is added (`session/new`, `session/resume`), closed
    /// (`session/close`, `session/delete`) or removed.
    func recordActiveSessions() {
        AgentMetrics.recordActiveSessions(sessions.values.count { !$0.isClosed })
    }

    /// The registered linked `SlashCommandProviding` conformers
    /// (the code-backed command source), in registration order. They join
    /// every later session's command registry, after the catalog's own
    /// conformers and before the skills source.
    var commandProviders: [any SlashCommandProviding] = []

    /// Registers linked slash-command conformers for the sessions
    /// created after this call. The frontend seam of the code-backed
    /// lane; the test harness stubs it.
    ///
    /// - Parameter providers: The conformers to append, in order.
    func registerCommandProviders(_ providers: [any SlashCommandProviding]) {
        commandProviders.append(contentsOf: providers)
    }

    /// The host tools that ``registerHostTools(_:)`` registered. The surface
    /// of each later session mounts them after its own tools.
    var hostTools: [any FoundationModels.Tool] = []

    /// Registers tools of the host for the sessions that this agent opens
    /// or resumes after this call. It exists for the tests and for an
    /// in-process host that adds its own tools; the production composition
    /// does not call it. Each tool comes after the tools of the catalog, in
    /// the order of the calls.
    ///
    /// - Parameter tools: The tools to append, in order.
    func registerHostTools(_ tools: [any FoundationModels.Tool]) {
        hostTools.append(contentsOf: tools)
    }

    /// The hook objects of this agent: the dispatcher that the router of
    /// ``residentProfile`` sends the hook events of each session to, and the
    /// snapshot store of the `snapshots` capability of each session.
    nonisolated let hooks: AgentHooks

    /// Registers hook visitors of the host on the dispatcher of ``hooks``.
    /// It exists for the tests and for an in-process host that adds its own
    /// visitors after the agent is made. Each visitor comes after the
    /// visitors that are already registered, in the order of the calls. A
    /// visitor gets the events that the sessions send after this call.
    ///
    /// - Parameter visitors: The visitors to append, in order.
    func registerHookVisitors(_ visitors: [any HookVisitor]) {
        for visitor in visitors {
            hooks.dispatcher.register(visitor)
        }
    }

    /// The most answers in a row that run mail alone starts in each session
    /// that this agent opens later (`SessionConfiguration.mailOnlyAnswerLimit`).
    /// Production keeps the Router default. A test sets a small value with
    /// ``useMailOnlyAnswerLimit(_:)``, so the session pauses the delivery of
    /// its mail at once (task ^t03jd5h).
    var mailOnlyAnswerLimit = SessionConfiguration.defaultMailOnlyAnswerLimit

    /// Sets ``mailOnlyAnswerLimit`` for the sessions that this agent opens
    /// after this call. Only a test calls it.
    ///
    /// - Parameter limit: The limit.
    func useMailOnlyAnswerLimit(_ limit: Int) {
        mailOnlyAnswerLimit = limit
    }

    /// A weak reference to the bound wire connection.
    ///
    /// The connection keeps this agent strongly: its factory built the
    /// agent, and it serves each inbound call to it. A strong reference
    /// back would make a cycle that a closed connection never breaks. The
    /// agent would then live on, and keep the hold of each model of
    /// ``residentProfile`` in the model pool of the process (task
    /// `^173qn8n`). The caller of `AgentSideConnection.init` keeps the
    /// connection for as long as it serves.
    private struct ConnectionReference {
        /// The bound connection, or `nil` before the bind and after the
        /// release of the connection.
        weak var connection: AgentSideConnection?
    }

    /// The bound wire connection, or `nil` before ``bind(connection:)``.
    ///
    /// A `Mutex` holds it outside actor isolation, because the
    /// connection factory closure is synchronous and binds during
    /// `AgentSideConnection` construction.
    private nonisolated let connectionHolder = Mutex(ConnectionReference())

    /// Binds the wire connection this agent notifies through.
    ///
    /// Each prompt sends every `session/update` through this
    /// connection, and registers its post-response work with the
    /// connection's `afterRespondingToCurrentRequest(_:)`, so the
    /// response goes out before the notifications of the prompt.
    /// Call it from the `AgentSideConnection` factory closure.
    ///
    /// The agent keeps the connection weakly, so the caller that made the
    /// connection keeps it for as long as it serves.
    ///
    /// The bind also starts the teardown task. It waits for
    /// `AgentSideConnection.closed`, then it closes each open session as
    /// `session/close` does (``closeOpenSessions(after:)``), and then it
    /// ends. Thus a client that goes away with no `session/close` (the end
    /// of the input, a failed input stream, or a local close) leaves no
    /// session open. The task holds this agent strongly until its end: a
    /// weak hold can find the agent already gone, and then no session
    /// closes. The hold adds no lifetime, because the read loop of the
    /// connection already keeps this agent until the loop ends, and `closed`
    /// fires at the end of that loop. After the task ends, the agent goes
    /// when its caller lets it go, and gives back its models.
    ///
    /// - Parameter connection: The connection around this agent.
    public nonisolated func bind(connection: AgentSideConnection) {
        connectionHolder.withLock { $0.connection = connection }
        // Never wait for `closed` in an inbound handler: the value waits
        // for each handler to end. This task is not a handler.
        let teardown = Task {
            await closeOpenSessions(after: await connection.closed)
        }
        connectionTeardown.withLock { $0 = teardown }
    }

    /// The teardown task of the latest bound connection, or `nil` before
    /// ``bind(connection:)``. See ``bind(connection:)``.
    private nonisolated let connectionTeardown = Mutex<Task<Void, Never>?>(nil)

    /// Waits until the agent closed its open sessions after the close of
    /// the latest bound connection. Returns at once before
    /// ``bind(connection:)``.
    ///
    /// A host that ends the process after the connection closed calls this
    /// first, so the teardown can write the history of each session and
    /// stop the MCP servers before the exit.
    public nonisolated func waitForConnectionTeardown() async {
        await connectionTeardown.withLock { $0 }?.value
    }

    /// The bound connection, or `nil` before ``bind(connection:)`` and
    /// after the release of the connection.
    nonisolated var boundConnection: AgentSideConnection? {
        connectionHolder.withLock { $0.connection }
    }

    /// Creates an agent for the dotfolder `name` and resolves the
    /// configured profile to a resident one (`config →
    /// ProfileDefinition → Router.resolve → resident profile`).
    ///
    /// The default `configuration` is the in-code layer-1 default: a
    /// coding profile that operates on a 32 GB machine
    /// (cli-plan.md §7).
    ///
    /// - Parameters:
    ///   - name: The dotfolder name the frontend chose. It
    ///     is also the fallback for the profile's name.
    ///   - router: The router that resolves the profile and owns its
    ///     residency.
    ///   - hooks: The hook objects of the agent. The caller gives the same
    ///     ``AgentHooks/dispatcher`` to `Router.init(hooks:)` of `router`,
    ///     because the router does not publish its dispatcher.
    ///   - configuration: The agent configuration whose `profile` section
    ///     is resolved.
    ///   - reporting: The UI-bindable resolution progress, or `nil` for a
    ///     fresh unobserved one.
    ///   - rootSettingsFolder: The root settings folder of the host, or `nil`
    ///     (the default) for the XDG user layers of the CLI. With a root,
    ///     each stack of each session reads its user layer from the root and
    ///     no stack holds a folder in the home directory or in
    ///     `XDG_CONFIG_HOME` (``SettingsFolders``). Tests give a temporary
    ///     folder so they never touch the real home directory.
    ///   - environment: The environment of the host: the stacks read their
    ///     defaults layer from it, and with no root `XDG_CONFIG_HOME` too,
    ///     and the session tools read it (``CatalogContext/environment``).
    ///     Defaults to the environment of the process.
    ///   - inlineSettleGrace: The settle period of each session that the
    ///     agent makes, in seconds. Defaults to
    ///     ``CatalogContext/defaultInlineSettleGrace``.
    ///   - transcriptLocation: The transcript location that wins over every
    ///     config layer in each session request, or `nil` (the default) to
    ///     let the config files decide — see ``transcriptLocation``.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` (the default) for the login Keychain under
    ///     the service `name` — see ``secretStore``.
    /// - Throws: `ProfileResolutionError` when the profile does not
    ///   resolve.
    public init(
        name: DotfolderName,
        router: Router,
        hooks: AgentHooks,
        configuration: AgentConfiguration = AgentConfiguration(),
        reporting: ResolutionProgress? = nil,
        rootSettingsFolder: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace,
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil
    ) async throws {
        self.name = name
        self.hooks = hooks
        self.settingsFolders = SettingsFolders(
            name: name, rootSettingsFolder: rootSettingsFolder, environment: environment)
        self.environment = environment
        self.inlineSettleGrace = inlineSettleGrace
        self.transcriptLocation = transcriptLocation
        self.secretStore = secretStore ?? KeychainSecretStore.loginKeychain(for: name)
        let progress: ResolutionProgress
        if let reporting {
            progress = reporting
        } else {
            progress = await ResolutionProgress()
        }
        residentProfile = try await configuration.profile.resolveResident(
            fallbackName: name, router: router, reporting: progress)
    }

    // MARK: - The order rule

    /// Applies the order rule: a client MUST initialize before
    /// it makes a session request. A request that comes first gets an
    /// invalid-request error, so the agent never acts on capabilities
    /// that were not negotiated.
    ///
    /// - Parameter method: The wire name of the session request.
    /// - Throws: `RequestError.initializeRequired(before:)`, a JSON-RPC
    ///   invalid-request error, when no `initialize` came first.
    func requireInitialized(before method: String) throws {
        guard negotiatedClientCapabilities != nil else {
            ACPAgentTelemetry.logger(.session).warning(
                "A session request came before initialize. The agent refuses it.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.acpMethod: "\(method)"])
            throw RequestError.initializeRequired(before: method)
        }
    }

    // MARK: - Session baseline

    // `newSession` lives in `Agent/SessionSetup.swift`.

    // `listSessions` lives in `Agent/SessionList.swift`.

    // `resumeSession` lives in `Agent/SessionResume.swift`.

    // `closeSession` and `deleteSession` live in
    // `Agent/SessionLifecycle.swift`.

    // `prompt` and `sessionCancel` live in `Agent/PromptExecution.swift`.

    // MARK: - Capability-gated

    // `setSessionConfigOption` lives in `Agent/ConfigOptions.swift`.
}

/// The wire names of the requests and the notifications this agent serves, as
/// the generated routing table spells them.
enum ACPMethod {
    /// `initialize`.
    static let initialize = "initialize"
    /// `session/new`.
    static let sessionNew = "session/new"
    /// `session/list`.
    static let sessionList = "session/list"
    /// `session/resume`.
    static let sessionResume = "session/resume"
    /// `session/close`.
    static let sessionClose = "session/close"
    /// `session/prompt`.
    static let sessionPrompt = "session/prompt"
    /// `session/cancel`, a notification.
    static let sessionCancel = "session/cancel"
    /// `session/delete`.
    static let sessionDelete = "session/delete"
    /// `session/set_config_option`.
    static let sessionSetConfigOption = "session/set_config_option"
}
