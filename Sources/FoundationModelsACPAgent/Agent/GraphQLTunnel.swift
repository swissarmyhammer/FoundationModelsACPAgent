import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool

/// The host of the GraphQL tunnel (ACPA-13, ACP-5, D55): the
/// `_sah/graphql/*` extension methods of each connection.
///
/// A call names its endpoint, and the agent routes it by name:
///
/// - The endpoints of the agent itself (``agentGraphQLEndpoints``), with the
///   server scope: `settings` and `snapshots`. A call reaches them with or
///   without a session.
/// - The endpoints of the top-level tools of a session
///   (`GraphQLEndpointTool`, EXTRAS-7). A call with a session reaches the
///   endpoints of that session. A call with no session reaches an endpoint
///   with the server scope of any live session; an endpoint with the
///   session-folder scope needs the session, because the session selects the
///   folder.
///
/// Each call gets the `GraphQLViewer` of its connection
/// (``ConnectionTable/viewer(of:)``). The host also checks the folder of a
/// session-folder call (EXTRAS-9 rule 4): an `external` viewer sees only the
/// folders of the sessions that it owns or started. A call that the agent
/// cannot route gets a GraphQL result with one coded error
/// (``GraphQLTunnelError``), as each endpoint error.
extension RoutedACPAgent {
    /// The GraphQL endpoints that the agent holds one time for all its
    /// sessions and connections (EXTRAS-9 rule 1), with the server scope.
    nonisolated var agentGraphQLEndpoints: [any GraphQLEndpoint] {
        [settingsEndpoint, snapshotsEndpoint]
    }

    /// The handlers of the `_sah/graphql/*` methods for one connection. Each
    /// handler names `caller` on its call to the agent, so each call gets the
    /// viewer of its own connection.
    ///
    /// - Parameter caller: The connection that the handlers serve.
    /// - Returns: The handlers.
    nonisolated func graphQLTunnelHandlers(for caller: ConnectionId) -> ExtensionHandlers {
        var handlers = ExtensionHandlers()
        handlers.registerMethod(SAH.GraphQL.Method.execute, params: SAH.GraphQL.ExecuteRequest.self) { request in
            await self.executeGraphQL(request, from: caller)
        }
        handlers.registerMethod(SAH.GraphQL.Method.subscribe, params: SAH.GraphQL.SubscribeRequest.self) { request in
            try self.startGraphQLSubscription(request, from: caller)
        }
        handlers.registerNotification(
            SAH.GraphQL.Method.unsubscribe, params: SAH.GraphQL.UnsubscribeNotification.self
        ) { notification in
            self.graphQLSubscriptions.cancel(.init(connection: caller, subscription: notification.subscriptionId))
        }
        handlers.registerMethod(SAH.GraphQL.Method.endpoints, params: SAH.GraphQL.EndpointsRequest.self) { _ in
            SAH.GraphQL.EndpointsResponse(endpoints: await self.graphQLEndpointList())
        }
        return handlers
    }

    /// Serves `_sah/graphql/execute`: runs one query or mutation on the
    /// endpoint that the call names, with the viewer of the calling
    /// connection.
    ///
    /// - Parameters:
    ///   - request: The params of the call.
    ///   - caller: The connection of the call.
    /// - Returns: The result of the endpoint, or a result with the coded
    ///   error of a call that cannot run.
    func executeGraphQL(
        _ request: SAH.GraphQL.ExecuteRequest, from caller: ConnectionId
    ) async -> SAH.GraphQL.ExecutionResult {
        let viewer = connections.viewer(of: caller)
        do {
            let endpoint = try tunnelEndpoint(named: request.endpoint, sessionId: request.sessionId, viewer: viewer)
            let text = try await endpoint.execute(
                query: request.query, variables: GraphQLTunnelJSON.variables(from: request.variables),
                operationName: request.operationName, viewer: viewer)
            return try GraphQLTunnelJSON.result(fromResponse: text)
        } catch {
            return GraphQLTunnelJSON.result(failingWith: error)
        }
    }

    /// The endpoints that the tunnel reaches, each name one time: the
    /// endpoints of the agent, then the endpoints of the live sessions. It
    /// is the result of `_sah/graphql/endpoints` and the list in
    /// `_meta.sah.graphql` of `initialize`.
    ///
    /// - Returns: The endpoint entries, in that order.
    func graphQLEndpointList() -> [SAH.GraphQL.Endpoint] {
        var seen: Set<String> = []
        return (agentGraphQLEndpoints + liveSessionGraphQLEndpoints())
            .filter { seen.insert($0.name).inserted }
            .map { endpoint in
                SAH.GraphQL.Endpoint(
                    name: endpoint.name, version: endpoint.version,
                    scope: SAH.GraphQL.Scope(rawValue: endpoint.scope.rawValue), schema: endpoint.schema)
            }
    }

    /// The endpoint that a call names, for the viewer of the call.
    ///
    /// - Parameters:
    ///   - name: The name of the endpoint.
    ///   - sessionId: The session of the call, or `nil`.
    ///   - viewer: The viewer of the call.
    /// - Returns: The endpoint.
    /// - Throws: ``GraphQLTunnelError/unknownEndpoint(name:known:)`` for a name
    ///   that the agent and the session do not have;
    ///   ``GraphQLTunnelError/sessionRequired(endpoint:)`` for a session-folder
    ///   endpoint with no session; `NOT_FOUND` for a session that the agent
    ///   does not have, that is closed, or whose folder the viewer cannot see.
    func tunnelEndpoint(
        named name: String, sessionId: SessionId?, viewer: GraphQLViewer
    ) throws -> any GraphQLEndpoint {
        if let endpoint = agentGraphQLEndpoints.first(where: { $0.name == name }) {
            return endpoint
        }
        guard let sessionId else {
            return try serverEndpointOfTheSessions(named: name)
        }
        guard let session = sessions[sessionId], !session.isClosed else {
            throw GraphQLTunnelError.sessionNotFound(sessionId)
        }
        guard let endpoint = session.surface.graphQLEndpoints.first(where: { $0.name == name }) else {
            throw unknownEndpoint(named: name)
        }
        switch endpoint.scope {
        case .sessionFolder:
            try requireVisibleFolder(of: session, named: sessionId, for: viewer)
        case .server:
            break
        }
        return endpoint
    }

    /// The endpoint with the server scope of a live session that a call
    /// with no session names.
    ///
    /// - Parameter name: The name of the endpoint.
    /// - Returns: The endpoint.
    /// - Throws: ``GraphQLTunnelError/unknownEndpoint(name:known:)`` when no
    ///   live session has the name;
    ///   ``GraphQLTunnelError/sessionRequired(endpoint:)`` when the endpoint
    ///   has the session-folder scope.
    private func serverEndpointOfTheSessions(named name: String) throws -> any GraphQLEndpoint {
        guard let endpoint = liveSessionGraphQLEndpoints().first(where: { $0.name == name }) else {
            throw unknownEndpoint(named: name)
        }
        switch endpoint.scope {
        case .sessionFolder:
            throw GraphQLTunnelError.sessionRequired(endpoint: name)
        case .server:
            return endpoint
        }
    }

    /// The `UNKNOWN_ENDPOINT` of a name, with the names that the tunnel
    /// reaches now.
    ///
    /// - Parameter name: The name that the call sent.
    /// - Returns: The error.
    private func unknownEndpoint(named name: String) -> GraphQLTunnelError {
        .unknownEndpoint(name: name, known: graphQLEndpointList().map(\.name))
    }

    /// The endpoints of the top-level tools of each live session, in the
    /// order of the session ids, so each list has the same order.
    ///
    /// - Returns: The endpoints; a name can be in more than one session.
    private func liveSessionGraphQLEndpoints() -> [any GraphQLEndpoint] {
        sessions
            .filter { !$0.value.isClosed }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { $0.value.surface.graphQLEndpoints }
    }

    /// Checks the folder of a session-folder call (EXTRAS-9 rule 4). A
    /// `userDevice` viewer sees each folder. An `external` viewer sees the
    /// folder of each session that it owns or started, so the folder of the
    /// session of the call must be one of them.
    ///
    /// - Parameters:
    ///   - session: The session of the call.
    ///   - sessionId: The id of the session of the call.
    ///   - viewer: The viewer of the call.
    /// - Throws: `NOT_FOUND` for the session when the viewer cannot see its
    ///   folder: the same answer as for a session that does not exist.
    private func requireVisibleFolder(
        of session: ActiveSession, named sessionId: SessionId, for viewer: GraphQLViewer
    ) throws {
        switch viewer.trust {
        case .userDevice:
            return
        case .external:
            let visibleFolders = Set(
                sessions
                    .filter { viewer.owns($0.key.rawValue) || viewer.startedSessions.contains($0.key.rawValue) }
                    .map { $0.value.workingDirectory.standardizedFileURL })
            guard visibleFolders.contains(session.workingDirectory.standardizedFileURL) else {
                throw GraphQLTunnelError.sessionNotFound(sessionId)
            }
        }
    }
}

extension SessionSurface {
    /// The GraphQL endpoints of the top-level tools of the session, in tool
    /// order: each tool that is a `GraphQLEndpointTool` gives its endpoints
    /// (EXTRAS-7, D76).
    var graphQLEndpoints: [any GraphQLEndpoint] {
        tools.flatMap { tool in (tool as? any GraphQLEndpointTool)?.graphQLEndpoints ?? [] }
    }
}
