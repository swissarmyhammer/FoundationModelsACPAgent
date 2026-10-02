import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Logging
import Synchronization

/// The composed ACP agent over the Router runtime (plan.md §1).
///
/// This is the wire package's `Agent` conformance. Each ACP noun names its
/// peer in the Router stack, and a noun with no peer is off, honestly. The
/// runtime stays wire-free: `RoutedSession` is Router's session surface, and
/// this type translates between it and the protocol.
///
/// The handshake lives in `Agent/Initialization.swift` (plan.md §5): the
/// implementation identity, the protocol version negotiation, the advertised
/// capabilities, and the reading of the client's capabilities.
///
/// There is no authentication surface (plan.md §6). The `initialize`
/// response omits `authMethods` and `capabilities.auth`, so `auth/login` and
/// `auth/logout` keep the wire package's default: `-32601`, the method is not
/// available on this agent. The agent never raises `-32000`.
///
/// `session/new` lives in `Agent/SessionSetup.swift` (plan.md §7.1): the
/// per-cwd composition pipeline and the actor-held session table. Each
/// remaining session handler lives beside it in its own `Agent/` file, and
/// the file comments below name where.
public actor RoutedACPAgent: Agent {
    /// The frontend-supplied dotfolder name (plan.md §2.1). It roots the
    /// configuration stack and the transcript directory. It never goes on
    /// the wire: `initialize` reports ``implementation`` instead (§5).
    public let name: DotfolderName

    /// The resident profile, resolved at construction and held strongly
    /// for the life of the agent (plan.md §1).
    ///
    /// Every `RoutedModel` holds its owning profile weakly, and each
    /// public `makeSession` traps once the profile is released; only the
    /// vended session retains it. This reference keeps the resident
    /// models alive between sessions.
    public nonisolated let residentProfile: LanguageModelProfile

    /// The client's capabilities as read at the latest `initialize`, or
    /// `nil` before the first one (plan.md §5).
    ///
    /// The order rule reads this: a `session/*` request that finds it `nil`
    /// came before `initialize`, and is refused.
    public internal(set) var negotiatedClientCapabilities: NegotiatedClientCapabilities?

    /// The user layer root override, or `nil` to derive the XDG location
    /// from ``environment`` and the home directory (plan.md §2.2). Tests
    /// inject a value so they never touch the real home directory, the
    /// same seam `ConfigurationLoader` documents.
    nonisolated let userDirectory: URL?

    /// The environment the per-session dotfolder stack reads
    /// `XDG_CONFIG_HOME` from.
    nonisolated let environment: [String: String]

    /// The live sessions, keyed by the ACP session id (plan.md §7.1).
    /// Each entry carries its own config, instructions, confinement,
    /// transcript directory, and idle/busy state.
    var sessions: [SessionId: ActiveSession] = [:]

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
    /// (plan.md §14.1, source 2), in registration order. They join
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
    /// connection's `afterRespondingToCurrentRequest(_:)` (plan.md §8.1).
    /// Call it from the `AgentSideConnection` factory closure.
    ///
    /// The agent keeps the connection weakly, so the caller that made the
    /// connection keeps it for as long as it serves. When the caller lets
    /// the connection go, the agent goes too, and gives back its models.
    ///
    /// - Parameter connection: The connection around this agent.
    public nonisolated func bind(connection: AgentSideConnection) {
        connectionHolder.withLock { $0.connection = connection }
    }

    /// The bound connection, or `nil` before ``bind(connection:)`` and
    /// after the release of the connection.
    nonisolated var boundConnection: AgentSideConnection? {
        connectionHolder.withLock { $0.connection }
    }

    /// Creates an agent for the dotfolder `name` and resolves the
    /// configured profile to a resident one (plan.md §1: `config →
    /// ProfileDefinition → Router.resolve → resident profile`).
    ///
    /// The default `configuration` is the in-code layer-1 default (plan.md
    /// §2.2): a coding profile that operates on a 32 GB machine
    /// (cli-plan.md §7).
    ///
    /// - Parameters:
    ///   - name: The dotfolder name the frontend chose (plan.md §2.1). It
    ///     is also the fallback for the profile's name.
    ///   - router: The router that resolves the profile and owns its
    ///     residency.
    ///   - configuration: The agent configuration whose `profile` section
    ///     is resolved.
    ///   - reporting: The UI-bindable resolution progress, or `nil` for a
    ///     fresh unobserved one.
    ///   - userDirectory: The user layer root, or `nil` to derive it from
    ///     `environment` and the home directory. Tests inject a value so
    ///     they never touch the real home directory.
    ///   - environment: The environment `XDG_CONFIG_HOME` is read from.
    /// - Throws: `ProfileResolutionError` when the profile does not
    ///   resolve.
    public init(
        name: DotfolderName,
        router: Router,
        configuration: AgentConfiguration = AgentConfiguration(),
        reporting: ResolutionProgress? = nil,
        userDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        self.name = name
        self.userDirectory = userDirectory
        self.environment = environment
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

    /// Applies the order rule (plan.md §5): a client MUST initialize before
    /// it makes a session request.
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

    // MARK: - Session baseline (plan.md §7 to §10)

    // `newSession` lives in `Agent/SessionSetup.swift` (plan.md §7.1).

    // `listSessions` lives in `Agent/SessionList.swift` (plan.md §9).

    // `resumeSession` lives in `Agent/SessionResume.swift` (plan.md §7.4).

    // `closeSession` and `deleteSession` live in
    // `Agent/SessionLifecycle.swift` (plan.md §10).

    // `prompt` and `sessionCancel` live in `Agent/PromptExecution.swift`
    // (plan.md §8.1–§8.3).

    // MARK: - Capability-gated (plan.md §15)

    // `setSessionConfigOption` lives in `Agent/ConfigOptions.swift`
    // (plan.md §15).
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
