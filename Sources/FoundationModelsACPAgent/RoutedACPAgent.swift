import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsHooks
import FoundationModelsMultitool
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
/// One agent serves each client connection (ACPA-5, D120), as a listener
/// with a connection table (``connections``): ``bind(connection:)`` gives
/// each connection its own ``RoutedACPConnection``, which names the
/// connection on each call. The `Agent` methods of the agent itself serve
/// the ``ConnectionId/direct`` caller: a test or an in-process host with no
/// wire.
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

    /// The session directory of the router that resolved
    /// ``residentProfile`` (`Router.sessionDirectory`). Each session that
    /// the profile vends or restores registers in it, so the agent changes
    /// the record of a session through it: the title at the first prompt,
    /// and the additional directories at each mount. Router writes each
    /// change to the `index.md` of the session folder.
    nonisolated let sessionDirectory: RouterSessionDirectory

    /// The connection table (ACPA-5, D120): one row for each bound
    /// connection and one for ``ConnectionId/direct``, with the client
    /// capabilities of the `initialize` of each and its trust, and the owner
    /// and the starter of each session (D11, D120 c).
    ///
    /// The order rule reads it: a `session/*` request of a connection whose
    /// row has no capabilities came before the `initialize` of that
    /// connection, and is refused.
    nonisolated let connections = ConnectionTable()

    /// The bearer tokens of the devices of the user, as the host gave them
    /// (ACPA-5b, D120 b). ``bind(connection:)`` gives `userDevice` to a
    /// connection whose bearer token is one of them, and `external` to a
    /// connection with any other token. The agent keeps no store of tokens:
    /// the host owns the pairing of the devices.
    public nonisolated let userDeviceTokens: Set<String>

    /// The client capabilities of the `initialize` of one connection.
    ///
    /// - Parameter id: The id of the connection.
    /// - Returns: The capabilities, or `nil` before the first `initialize` of
    ///   the connection.
    public nonisolated func clientCapabilities(of id: ConnectionId) -> NegotiatedClientCapabilities? {
        connections.clientCapabilities(of: id)
    }

    /// The settings folders of the agent (ACPA-16, D98): ``name``, the
    /// ``AgentHome`` of the host, and ``environment``. Each stack of each
    /// session comes from them: the configuration stack of each
    /// ``makeConfigurationLoader(workingDirectory:)`` and the skills and
    /// agents stacks of each ``CatalogContext``.
    nonisolated let settingsFolders: SettingsFolders

    /// The environment of the host. The per-session dotfolder stacks read
    /// their defaults layer from it. Each session composition gives it to its
    /// ``CatalogContext``, so the session tools read the values that the
    /// host gave (``CatalogContext/environment``).
    nonisolated let environment: [String: String]

    /// The home of the host (task ^98a44n7): each folder outside the project
    /// that the agent and its sessions read or write comes from it, through
    /// ``settingsFolders``.
    public nonisolated var home: AgentHome {
        settingsFolders.home
    }

    /// The transcript location that the host gave in code, or `nil` when
    /// the config files decide.
    ///
    /// `session/new`, `session/resume` and `session/delete` read the
    /// configuration of their `cwd` from ``settingsStore``, and
    /// `session/list` loads it through
    /// ``makeConfigurationLoader(workingDirectory:)``. The store and each
    /// loader get this value. Thus `session/new`, `session/resume`,
    /// `session/list` (with a `cwd` filter and across the project store of
    /// the home) and `session/delete` all record or read under this
    /// location, and it wins over the `transcripts.location` of every
    /// config layer.
    public nonisolated let transcriptLocation: TranscriptLocation?

    /// The store that gives the value of each secret reference
    /// `keychain:<name>` of the configuration (ACPA-18, D101).
    ///
    /// The host gives it, or the initializer sets the login Keychain under
    /// the service ``name``. The configuration load reads the references
    /// through it.
    nonisolated let secretStore: any SecretStore

    /// The settings of the agent in memory (ACPA-17, D100(f)): one settings
    /// object for each level, over ``settingsFolders``,
    /// ``transcriptLocation`` and ``secretStore``. The session start paths
    /// read the merged settings of their `cwd` from it, and not from a fresh
    /// load of the files.
    nonisolated let settingsStore: SettingsStore

    /// The one `settings` endpoint of the agent over ``settingsStore``
    /// (EXTRAS-9 rule 9): the initializer makes it next to the store, and
    /// each session composition gives this same instance to its
    /// ``SettingsTool`` (``CatalogContext/settingsEndpoint``). Thus the
    /// schema is built one time for the agent, and each tool gives one cursor
    /// sequence.
    nonisolated let settingsEndpoint: SettingsGraph

    /// The one `snapshots` endpoint of the agent over the snapshot store of
    /// ``hooks`` (MT-13), for the GraphQL tunnel (ACPA-13): a client reaches
    /// it with no session, because it has the server scope. Each session's
    /// `snapshots` capability makes its own endpoint over the same store,
    /// with the same session-key maps, and one store has one change log, so
    /// each gives the same cursor (EXTRAS-9 rule 1).
    nonisolated let snapshotsEndpoint: SnapshotsGraph

    /// The open `_sah/graphql/subscribe` subscriptions of each connection
    /// (ACPA-13). The close of a connection cancels its subscriptions.
    nonisolated let graphQLSubscriptions = GraphQLTunnelSubscriptions()

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

    /// Binds one more wire connection to this agent (ACPA-5, D120 a), and
    /// gives back the `Agent` that serves it.
    ///
    /// The bind adds a row to ``connections``. Its id is the
    /// `Acp-Connection-Id` that the transport gives
    /// (`AgentSideConnection.connectionInfo`, the HTTP transport); a
    /// transport with no connection header gets a new id from the agent. It
    /// does not replace an earlier connection: each bound connection is
    /// served at the same time, and each session sends its updates through
    /// its own connection.
    /// Call it from the `AgentSideConnection` factory closure, and give back
    /// the result:
    ///
    /// ```swift
    /// let connection = await AgentSideConnection(stream: transport) { connection in
    ///     agent.bind(connection: connection)
    /// }
    /// ```
    ///
    /// The row keeps the connection weakly, so the caller that made the
    /// connection keeps it for as long as it serves.
    ///
    /// The bind also starts the teardown task of the connection. It waits
    /// for `AgentSideConnection.closed`, then it removes the row and frees
    /// each session that the connection owns
    /// (``tearDownConnection(_:after:)``), and then it ends. Thus a client
    /// that goes away with no `session/close` (the end of the input, a failed
    /// input stream, or a local close) leaves its sessions running with no
    /// owner (D68), for another client to take. The task holds this agent
    /// strongly until its end, so the row of a closed connection is always
    /// removed. The hold adds no lifetime, because the read loop of the
    /// connection already keeps this agent until the loop ends, and `closed`
    /// fires at the end of that loop. A host closes the sessions at its own
    /// end (``closeOpenSessions()``).
    ///
    /// The trust of the connection comes from its credential (ACPA-5b,
    /// D120 b), and never from the client: `initialize` does not change it.
    /// A bearer token in ``userDeviceTokens`` gives `userDevice`; any other
    /// token, or an HTTP connection with no token, gives `external`. Stdio
    /// and `InMemoryTransport` carry no connection header, and they serve
    /// the in-process UI and the local CLI, so their trust is `userDevice`
    /// (``ConnectionTrust/init(credentialOf:userDeviceTokens:)``).
    ///
    /// - Parameter connection: The new connection.
    /// - Returns: The `Agent` of the connection, which names the connection
    ///   on each call to this agent.
    public nonisolated func bind(connection: AgentSideConnection) -> RoutedACPConnection {
        let info = connection.connectionInfo
        let id = ConnectionId.make(for: info)
        connections.add(
            connection, id: id, trust: ConnectionTrust(credentialOf: info, userDeviceTokens: userDeviceTokens))
        // Never wait for `closed` in an inbound handler: the value waits
        // for each handler to end. This task is not a handler.
        let teardown = Task {
            await tearDownConnection(id, after: await connection.closed)
        }
        connectionTeardowns.withLock { $0[id] = teardown }
        return RoutedACPConnection(id: id, agent: self)
    }

    /// The teardown task of each connection that ``bind(connection:)``
    /// bound, keyed by the connection id. See ``bind(connection:)``.
    private nonisolated let connectionTeardowns = Mutex<[ConnectionId: Task<Void, Never>]>([:])

    /// Waits until the teardown of each bound connection ended: each one
    /// closed, its row is gone, and its sessions are free (ACPA-5d). Returns
    /// at once before the first ``bind(connection:)``.
    ///
    /// The wait is for the rows, not for the sessions: a closed connection
    /// does not close its sessions, and they go on (D68). A host that ends
    /// the process after its connections closed calls this, and then
    /// ``closeOpenSessions()``, so the history of each session is written and
    /// the MCP servers stop before the exit. A connection that is still open
    /// keeps this wait; a host that closed one connection of many waits with
    /// ``waitForTeardown(of:)``.
    public nonisolated func waitForConnectionTeardown() async {
        for teardown in connectionTeardowns.withLock({ Array($0.values) }) {
            await teardown.value
        }
    }

    /// Waits until the teardown of one bound connection ended: it closed,
    /// its row is gone, and its sessions are free. Returns at once for an id
    /// that ``bind(connection:)`` did not give.
    ///
    /// - Parameter id: The id of the connection.
    public nonisolated func waitForTeardown(of id: ConnectionId) async {
        await connectionTeardowns.withLock { $0[id] }?.value
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
    ///   - home: The home of the host (``home``). Each stack of each session
    ///     reads its user layer from it (``SettingsFolders``), and each
    ///     session takes its skills marketplace cache and the folder of its
    ///     machine state from it. Tests give a custom home in throwaway
    ///     folders, so they never touch the real home directory.
    ///   - environment: The environment of the host: the stacks read their
    ///     defaults layer from it, and the session tools read it
    ///     (``CatalogContext/environment``).
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
    ///   - userDeviceTokens: The bearer tokens of the devices of the user,
    ///     or none (the default) — see ``userDeviceTokens``. A host with no
    ///     HTTP server gives none: its stdio and in-process connections are
    ///     `userDevice` with no token.
    /// - Throws: `ProfileResolutionError` when the profile does not
    ///   resolve; an error of the schema builder of ``settingsEndpoint``.
    public init(
        name: DotfolderName,
        router: Router,
        hooks: AgentHooks,
        configuration: AgentConfiguration = AgentConfiguration(),
        reporting: ResolutionProgress? = nil,
        home: AgentHome,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace,
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil,
        userDeviceTokens: Set<String> = []
    ) async throws {
        self.name = name
        self.sessionDirectory = router.sessionDirectory
        self.hooks = hooks
        self.userDeviceTokens = userDeviceTokens
        self.settingsFolders = SettingsFolders(name: name, home: home, environment: environment)
        self.environment = environment
        self.inlineSettleGrace = inlineSettleGrace
        self.transcriptLocation = transcriptLocation
        self.secretStore = secretStore ?? KeychainSecretStore.loginKeychain(for: name)
        self.settingsStore = SettingsStore(
            settingsFolders: settingsFolders, transcriptLocation: transcriptLocation,
            secretStore: self.secretStore)
        self.settingsEndpoint = try SettingsGraph(store: settingsStore)
        // The sessions of one working directory share one key, so the
        // endpoint reads the key of each session, and the ACP session of each
        // Router session that owns the store, from the one map that the
        // `snapshots` capability of each session reads too.
        self.snapshotsEndpoint = SnapshotSessionKeys.shared.makeEndpoint(over: hooks.snapshotStore)
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
    /// The rule reads the connection of the request: each connection
    /// initializes for itself.
    ///
    /// - Parameters:
    ///   - method: The wire name of the session request.
    ///   - caller: The connection of the request.
    /// - Throws: `RequestError.initializeRequired(before:)`, a JSON-RPC
    ///   invalid-request error, when no `initialize` came first.
    func requireInitialized(before method: String, from caller: ConnectionId) throws {
        guard connections.clientCapabilities(of: caller) != nil else {
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
