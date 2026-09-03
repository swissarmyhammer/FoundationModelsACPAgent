import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import os

/// The logger of the session surface: the order rule and the ignored
/// notifications.
private let sessionLogger = Logger(subsystem: RoutedACPAgent.implementation.name, category: "Session")

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
/// per-cwd composition pipeline and the actor-held session table. The
/// remaining session handlers land in later tasks; until then each one
/// applies the order rule and then refuses with method-not-found, so the
/// conformance compiles and the wire shape stays honest.
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

    /// The bound wire connection, or `nil` before ``bind(connection:)``.
    ///
    /// A `Mutex` holds it outside actor isolation, because the
    /// connection factory closure is synchronous and binds during
    /// `AgentSideConnection` construction.
    private nonisolated let connectionHolder = Mutex<AgentSideConnection?>(nil)

    /// Binds the wire connection this agent notifies through.
    ///
    /// The prompt turn sends every `session/update` through this
    /// connection, and registers its post-response work with the
    /// connection's `afterRespondingToCurrentRequest(_:)` (plan.md §8.1).
    /// Call it from the `AgentSideConnection` factory closure.
    ///
    /// - Parameter connection: The connection around this agent.
    public nonisolated func bind(connection: AgentSideConnection) {
        connectionHolder.withLock { $0 = connection }
    }

    /// The bound connection, or `nil` before ``bind(connection:)``.
    nonisolated var boundConnection: AgentSideConnection? {
        connectionHolder.withLock { $0 }
    }

    /// Creates an agent for the dotfolder `name` and resolves the
    /// configured profile to a resident one (plan.md §1: `config →
    /// ProfileDefinition → Router.resolve → resident profile`).
    ///
    /// The default `configuration` is the in-code layer-1 default (plan.md
    /// §2.2): a coding profile that operates on a 16 GB machine.
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
            sessionLogger.warning("\(method, privacy: .public) before initialize; refused")
            throw RequestError.initializeRequired(before: method)
        }
    }

    /// Applies the order rule, then refuses a session request that no task
    /// has implemented yet.
    ///
    /// - Parameter method: The wire name of the session request.
    /// - Returns: Never; the function always throws.
    /// - Throws: The order rule's invalid-request error, or
    ///   `RequestError.methodNotFound(method)`.
    private func refuseUnimplemented<Response>(_ method: String) throws -> Response {
        try requireInitialized(before: method)
        throw RequestError.methodNotFound(method)
    }

    // MARK: - Session baseline (plan.md §7 to §10)

    // `newSession` lives in `Agent/SessionSetup.swift` (plan.md §7.1).

    // `listSessions` lives in `Agent/SessionList.swift` (plan.md §9).

    // `resumeSession` lives in `Agent/SessionResume.swift` (plan.md §7.4).

    /// Refuses until the session-close task lands.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionClose)
    }

    // `prompt` and `sessionCancel` live in `Agent/PromptTurn.swift`
    // (plan.md §8.1–§8.3).

    // MARK: - Capability-gated (plan.md §10.2, §15; later tasks)

    /// Refuses until the session-delete task lands.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionDelete)
    }

    // `setSessionConfigOption` lives in `Agent/ConfigOptions.swift`
    // (plan.md §15).
}

/// The wire names of the session requests this agent serves, as the
/// generated routing table spells them.
enum ACPMethod {
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
    /// `session/delete`.
    static let sessionDelete = "session/delete"
    /// `session/set_config_option`.
    static let sessionSetConfigOption = "session/set_config_option"
}
