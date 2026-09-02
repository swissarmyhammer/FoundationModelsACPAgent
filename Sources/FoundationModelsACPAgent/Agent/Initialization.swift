import FoundationModelsACP
import os

/// The logger of the handshake: the version negotiation and the client
/// identity.
private let initializationLogger = Logger(
    subsystem: RoutedACPAgent.implementation.name, category: "Initialization")

/// The client's capabilities as `initialize` read them (plan.md §5), with
/// the spec's own rule applied: absent means unsupported.
///
/// Stable v2's `ClientCapabilities` has `auth` and `elicitation`. This agent
/// reads only `elicitation` (plan.md §16). It never reads `auth.terminal`,
/// because it has no authentication surface (plan.md §6). A capabilities
/// object the wire could not parse arrives as the empty value, so it reads
/// as "supports nothing" and does not fail the handshake.
public struct NegotiatedClientCapabilities: Hashable, Sendable {
    /// Whether the client answers form elicitations (`elicitation.form`
    /// was a present, non-null object).
    public let supportsFormElicitation: Bool

    /// Whether the client answers URL elicitations (`elicitation.url` was a
    /// present, non-null object).
    public let supportsURLElicitation: Bool

    /// Reads `capabilities` with "absent means unsupported".
    ///
    /// - Parameter capabilities: The client's `initialize` capabilities.
    public init(reading capabilities: ClientCapabilities) {
        supportsFormElicitation = capabilities.elicitation?.form != nil
        supportsURLElicitation = capabilities.elicitation?.url != nil
    }
}

extension RequestError {
    /// The reason the order rule reports in the error's `data`.
    private static let initializeFirstReason = "initialize must be the first request"

    /// The order-rule refusal (plan.md §5): a JSON-RPC invalid-request
    /// error that names the refused method and the reason in `data`.
    ///
    /// - Parameter method: The wire name of the refused session request.
    /// - Returns: The typed invalid-request error.
    static func initializeRequired(before method: String) -> RequestError {
        RequestError(
            code: .invalidRequest,
            message: RequestError.invalidRequest.message,
            data: .object([
                "method": .string(method),
                "reason": .string(initializeFirstReason),
            ]))
    }
}

extension RoutedACPAgent {
    /// The build version this agent reports in `initialize` (plan.md §5).
    public static let buildVersion = "0.1.0"

    /// The identity this agent reports in `initialize` (plan.md §5).
    ///
    /// `name` is the package and product identifier, for programmatic use.
    /// It is never the dotfolder name, which is the user's private
    /// selection. `title` is the display name. `version` is
    /// ``buildVersion``.
    public static let implementation = Implementation(
        name: "FoundationModelsACPAgent",
        version: buildVersion,
        title: "Foundation Models ACP Agent")

    /// The most recent protocol version this agent serves.
    public static let latestProtocolVersion = ProtocolVersion.v2

    /// Every protocol version this agent serves. This agent is v2-only
    /// (plan.md §1).
    public static let supportedProtocolVersions: Set<ProtocolVersion> = [latestProtocolVersion]

    /// The capabilities this agent advertises in `initialize` (plan.md §5).
    ///
    /// Each marker is an object, never a boolean: `{}` means supported, and
    /// an omitted member means not supported. `capabilities.session` carries
    /// `prompt` — the one `PromptContent` advertisement, next to the
    /// consumption code it describes (plan.md §12) — `mcp` with both
    /// `stdio` and `http` (§11.5), `delete` (§10.2), and
    /// `additionalDirectories` (§7.2). There is no `auth` member (§6), and
    /// there is no permission capability: the sandbox is the only gate
    /// (§11.7).
    public static let advertisedCapabilities = AgentCapabilities(
        session: SessionCapabilities(
            additionalDirectories: SessionAdditionalDirectoriesCapabilities(),
            delete: SessionDeleteCapabilities(),
            mcp: MCPCapabilities(http: MCPHTTPCapabilities(), stdio: MCPStdioCapabilities()),
            prompt: PromptContent.advertisedCapabilities))

    /// Negotiates the protocol version and the capabilities (plan.md §5).
    ///
    /// The response carries ``implementation``, the negotiated version, and
    /// ``advertisedCapabilities``. It omits `authMethods` (plan.md §6). The
    /// client's capabilities are read into
    /// ``negotiatedClientCapabilities``, which also marks the agent as
    /// initialized for the order rule.
    ///
    /// - Parameter params: The client's `initialize` request.
    /// - Returns: The agent's `initialize` response.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        let protocolVersion = Self.negotiateProtocolVersion(requested: params.protocolVersion)
        negotiatedClientCapabilities = NegotiatedClientCapabilities(reading: params.capabilities)
        initializationLogger.info(
            "initialized by \(params.info.name, privacy: .public) \(params.info.version, privacy: .public)")
        return InitializeResponse(
            info: Self.implementation,
            protocolVersion: protocolVersion,
            capabilities: Self.advertisedCapabilities)
    }

    /// Negotiates the protocol version as behavior, not as a number
    /// (plan.md §5).
    ///
    /// If this agent serves the version the client sent, it sends the same
    /// integer back. If not, it sends back ``latestProtocolVersion`` in a
    /// normal, successful response, and logs the difference. The client
    /// then decides to disconnect.
    ///
    /// - Parameter requested: The latest version the client supports.
    /// - Returns: The version the response carries.
    static func negotiateProtocolVersion(requested: ProtocolVersion) -> ProtocolVersion {
        guard supportedProtocolVersions.contains(requested) else {
            initializationLogger.notice(
                "client sent protocolVersion \(requested.rawValue, privacy: .public); answering \(latestProtocolVersion.rawValue, privacy: .public)"
            )
            return latestProtocolVersion
        }
        return requested
    }
}
