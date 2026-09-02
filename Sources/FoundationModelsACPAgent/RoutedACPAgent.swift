import FoundationModelsACP
import FoundationModelsRouter
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
/// The session handlers land in later tasks. Until then each one applies
/// the order rule and then refuses with method-not-found, so the
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
    /// - Throws: `ProfileResolutionError` when the profile does not
    ///   resolve.
    public init(
        name: DotfolderName,
        router: Router,
        configuration: AgentConfiguration = AgentConfiguration(),
        reporting: ResolutionProgress? = nil
    ) async throws {
        self.name = name
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

    // MARK: - Session baseline (plan.md §7 to §10; later tasks)

    /// Refuses until the session-setup task lands.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionNew)
    }

    /// Refuses until the session-list task lands.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try refuseUnimplemented(ACPMethod.sessionList)
    }

    /// Refuses until the session-resume task lands.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionResume)
    }

    /// Refuses until the session-close task lands.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionClose)
    }

    /// Refuses until the prompt-turn task lands.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try refuseUnimplemented(ACPMethod.sessionPrompt)
    }

    /// A notification, so it has no response. With no session table yet,
    /// every id is unknown: log and ignore (plan.md §10.1).
    public func sessionCancel(_ params: CancelSessionNotification) async {
        sessionLogger.notice(
            "session/cancel for unknown session \(params.sessionId.rawValue, privacy: .public); ignored")
    }

    // MARK: - Capability-gated (plan.md §10.2, §15; later tasks)

    /// Refuses until the session-delete task lands.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try refuseUnimplemented(ACPMethod.sessionDelete)
    }

    /// Refuses until the config-options task lands.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try refuseUnimplemented(ACPMethod.sessionSetConfigOption)
    }
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
