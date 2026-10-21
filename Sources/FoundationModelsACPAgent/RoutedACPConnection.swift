import FoundationModelsACP

/// One client connection of a ``RoutedACPAgent`` (ACPA-5, D120 a), as in
/// listen and fork: the agent is the listener, and each connection gets one
/// of these from ``RoutedACPAgent/bind(connection:trust:)``.
///
/// It is the `Agent` that the factory of `AgentSideConnection` gives back. It
/// keeps no state of its own: it names its connection on each call to the one
/// agent, and the agent keys its state by that id. Thus the model pool, the
/// settings store, the snapshot store, the session table and each GraphQL
/// endpoint are one instance for all connections (EXTRAS-9 rule 1).
public final class RoutedACPConnection: Agent {
    /// The id of this connection in the connection table of ``agent``.
    public let id: ConnectionId

    /// The one agent that serves each connection.
    public let agent: RoutedACPAgent

    /// Makes the connection of `agent` with the id of its row.
    ///
    /// - Parameters:
    ///   - id: The id of the row of the connection.
    ///   - agent: The agent that serves the connection.
    init(id: ConnectionId, agent: RoutedACPAgent) {
        self.id = id
        self.agent = agent
    }

    /// The client capabilities of the `initialize` of this connection, or
    /// `nil` before its first `initialize`.
    public var clientCapabilities: NegotiatedClientCapabilities? {
        agent.clientCapabilities(of: id)
    }

    /// Serves `initialize` for this connection.
    ///
    /// - Parameter params: The client's `initialize` request.
    /// - Returns: The agent's `initialize` response.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        await agent.initialize(params, from: id)
    }

    /// Serves `session/new` for this connection.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: The new session's identity and initial configuration.
    /// - Throws: What ``RoutedACPAgent/newSession(_:)`` throws.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try await agent.newSession(params, from: id)
    }

    /// Serves `session/list` for this connection.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: The listed sessions.
    /// - Throws: What ``RoutedACPAgent/listSessions(_:)`` throws.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try await agent.listSessions(params, from: id)
    }

    /// Serves `session/resume` for this connection.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: The resumed session's configuration.
    /// - Throws: What ``RoutedACPAgent/resumeSession(_:)`` throws.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await agent.resumeSession(params, from: id)
    }

    /// Serves `session/close` for this connection.
    ///
    /// - Parameter params: The close-session request.
    /// - Returns: The close-session response.
    /// - Throws: What ``RoutedACPAgent/closeSession(_:)`` throws.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try await agent.closeSession(params, from: id)
    }

    /// Serves `session/prompt` for this connection.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The response that names the user message.
    /// - Throws: What ``RoutedACPAgent/prompt(_:)`` throws.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try await agent.prompt(params, from: id)
    }

    /// Serves `session/cancel` for this connection. A cancel needs no
    /// connection: it names its session.
    ///
    /// - Parameter params: The cancellation notification.
    public func sessionCancel(_ params: CancelSessionNotification) async {
        await agent.sessionCancel(params)
    }

    /// Serves `session/delete` for this connection.
    ///
    /// - Parameter params: The delete-session request.
    /// - Returns: The delete-session response.
    /// - Throws: What ``RoutedACPAgent/deleteSession(_:)`` throws.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try await agent.deleteSession(params, from: id)
    }

    /// Serves `session/set_config_option` for this connection.
    ///
    /// - Parameter params: The set-config-option request.
    /// - Returns: The full, updated set of configuration options.
    /// - Throws: What ``RoutedACPAgent/setSessionConfigOption(_:)`` throws.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try await agent.setSessionConfigOption(params, from: id)
    }
}
