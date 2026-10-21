import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The client's capabilities as `initialize` read them, with
/// the spec's own rule applied: absent means unsupported.
///
/// Stable v2's `ClientCapabilities` has `auth` and `elicitation`. This agent
/// reads only `elicitation`, which gates the elicitation relay. It never
/// reads `auth.terminal`, because it has no authentication surface. A capabilities
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

    /// Whether the client answers an elicitation in some mode: form or URL.
    public var supportsElicitation: Bool {
        supportsFormElicitation || supportsURLElicitation
    }
}

extension RoutedACPAgent {
    /// The user presence of a session that one connection opens now
    /// (elicitation-plan tasks 6 and 7). Router gives it to the run plane of
    /// the session (`SessionConfiguration.userPresence`).
    ///
    /// - `.headless` when the connection has no outbound path: no relay can
    ///   reach a user, for example ``ConnectionId/direct``, an in-process
    ///   call with no wire.
    /// - `.headless` when the client of the connection answers no
    ///   elicitation: no `elicitation` capability, or neither `form` nor
    ///   `url`. No `initialize` yet reads as "supports nothing".
    /// - `.interactive` otherwise.
    ///
    /// In a headless session, Extras answers each question at once with
    /// cancel and the reason `RunPlane.noUserPresentReason`, so a question
    /// never waits for a user who is not there.
    ///
    /// - Parameter caller: The connection that opens the session.
    /// - Returns: The user presence.
    nonisolated func userPresence(of caller: ConnectionId) -> UserPresence {
        guard let path = connections.path(of: caller), path.capabilities.supportsElicitation else {
            return .headless
        }
        return .interactive
    }
}

extension RequestError {
    /// The reason the order rule reports in the error's `data`.
    private static let initializeFirstReason = "initialize must be the first request"

    /// The order-rule refusal: a JSON-RPC invalid-request
    /// error that names the refused method and the reason in `data`.
    /// A `session/*` request before `initialize` gets this error, because
    /// the agent must not act on capabilities that were not negotiated.
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
    /// The build version this agent reports in `initialize`.
    public static let buildVersion = "0.1.0"

    /// The identity this agent reports in `initialize`.
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

    /// Every protocol version this agent serves. This agent is v2-only: it
    /// serves the stable ACP v2 method set and no earlier version.
    public static let supportedProtocolVersions: Set<ProtocolVersion> = [latestProtocolVersion]

    /// The capabilities this agent advertises in `initialize`.
    ///
    /// Each marker is an object, never a boolean: `{}` means supported, and
    /// an omitted member means not supported. `capabilities.session` carries
    /// `prompt` — the one `PromptContent` advertisement, next to the
    /// consumption code it describes — `mcp` with both `stdio` and `http`
    /// (the two stable MCP transports), `delete` (a real delete, not a
    /// tombstone), and `additionalDirectories` (multi-root confinement).
    /// There is no `auth` member, because a local agent has no
    /// authentication. There is no permission capability: the Seatbelt
    /// sandbox is the only gate on a command.
    public static let advertisedCapabilities = AgentCapabilities(
        session: SessionCapabilities(
            additionalDirectories: SessionAdditionalDirectoriesCapabilities(),
            delete: SessionDeleteCapabilities(),
            mcp: MCPCapabilities(http: MCPHTTPCapabilities(), stdio: MCPStdioCapabilities()),
            prompt: PromptContent.advertisedCapabilities))

    /// Negotiates the protocol version and the capabilities.
    ///
    /// The response carries ``implementation``, the negotiated version,
    /// ``advertisedCapabilities``, and in `_meta.sah` the SAH extensions with
    /// the endpoints of the GraphQL tunnel. It omits `authMethods`, because the agent
    /// has no authentication. The
    /// client's capabilities are read into the row of the
    /// ``ConnectionId/direct`` caller (``clientCapabilities(of:)``), which
    /// also marks that caller as initialized for the order rule.
    ///
    /// - Parameter params: The client's `initialize` request.
    /// - Returns: The agent's `initialize` response.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        await initialize(params, from: .direct)
    }

    /// Negotiates the protocol version and the capabilities for one
    /// connection: the work of ``initialize(_:)`` and of
    /// ``RoutedACPConnection/initialize(_:)``. The client's capabilities go
    /// into the row of `caller` only: each connection has its own.
    ///
    /// The request runs in one server span (``RequestTracing``).
    ///
    /// - Parameters:
    ///   - params: The client's `initialize` request.
    ///   - caller: The connection of the request.
    /// - Returns: The agent's `initialize` response.
    func initialize(_ params: InitializeRequest, from caller: ConnectionId) async -> InitializeResponse {
        await RequestTracing.withRequestSpan(
            ACPAgentTelemetry.SpanName.initialize, method: ACPMethod.initialize, sessionId: nil, meta: params.meta
        ) { _ in
            negotiate(params, from: caller)
        }
    }

    /// Negotiates the protocol version, reads the client's capabilities and
    /// logs the client identity: the work of ``initialize(_:from:)``.
    ///
    /// - Parameters:
    ///   - params: The client's `initialize` request.
    ///   - caller: The connection of the request.
    /// - Returns: The agent's `initialize` response.
    private func negotiate(_ params: InitializeRequest, from caller: ConnectionId) -> InitializeResponse {
        let protocolVersion = Self.negotiateProtocolVersion(requested: params.protocolVersion)
        connections.recordClientCapabilities(NegotiatedClientCapabilities(reading: params.capabilities), of: caller)
        ACPAgentTelemetry.logger(.initialization).info(
            "A client initialized the agent.",
            metadata: [
                ACPAgentTelemetry.LogMetadataKey.clientName: "\(params.info.name)",
                ACPAgentTelemetry.LogMetadataKey.clientVersion: "\(params.info.version)",
            ])
        return InitializeResponse(
            info: Self.implementation,
            protocolVersion: protocolVersion,
            capabilities: Self.advertisedCapabilities,
            meta: advertisedSAHMeta())
    }

    /// The `_meta` of the `initialize` response: `_meta.sah` advertises the
    /// SAH extensions and the endpoints of the GraphQL tunnel (ACP-5,
    /// ACPA-13), the same list as `_sah/graphql/endpoints`.
    ///
    /// - Returns: The `_meta` value, or `nil` when the SAH object does not
    ///   encode; the response then advertises no extension.
    private func advertisedSAHMeta() -> FoundationModelsACP.JSONValue? {
        do {
            return try SAH.InitializeMeta(graphql: graphQLEndpointList()).inject(into: nil)
        } catch {
            assertionFailure("the SAH object of initialize did not encode: \(error)")
            ACPAgentTelemetry.logger(.initialization).error(
                "The SAH object of initialize did not encode. The response advertises no extension.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return nil
        }
    }

    /// Negotiates the protocol version as behavior, not as a number.
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
            ACPAgentTelemetry.logger(.initialization).notice(
                "The client sent a protocol version that the agent does not serve. The agent answers with its latest version.",
                metadata: [
                    ACPAgentTelemetry.LogMetadataKey.requestedProtocolVersion: "\(requested.rawValue)",
                    ACPAgentTelemetry.LogMetadataKey.answeredProtocolVersion: "\(latestProtocolVersion.rawValue)",
                ])
            return latestProtocolVersion
        }
        return requested
    }
}
