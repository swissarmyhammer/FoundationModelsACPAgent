import FoundationModelsACP
import FoundationModelsExtras

/// The subscriptions of the GraphQL tunnel (ACPA-13, ACP-5): the
/// `graphql-transport-ws` shape over `_sah/graphql/subscribe`. The server
/// sends each event of the stream of the endpoint in `_sah/graphql/next`,
/// and ends the subscription with one `_sah/graphql/complete` or one
/// `_sah/graphql/error`. A subscription that the client stops with
/// `_sah/graphql/unsubscribe`, or whose connection closes, ends with no
/// message.
extension RoutedACPAgent {
    /// The `data.reason` of the refusal of a subscription id that is in use.
    private static let subscriptionIdInUseReason = "the subscription id is in use on this connection"

    /// Serves `_sah/graphql/subscribe`: starts the task of the subscription,
    /// and answers at once. The task routes the call, runs the stream of the
    /// endpoint, and sends its notifications.
    ///
    /// - Parameters:
    ///   - request: The params of the call.
    ///   - caller: The connection of the call.
    /// - Returns: The response that tells that the subscription started.
    /// - Throws: An invalid-params error when an open subscription of the
    ///   connection already has the id of the call.
    nonisolated func startGraphQLSubscription(
        _ request: SAH.GraphQL.SubscribeRequest, from caller: ConnectionId
    ) throws -> SAH.GraphQL.SubscribeResponse {
        let id = request.subscriptionId
        let subscriptions = graphQLSubscriptions
        let started = subscriptions.start(id, of: caller) { generation in
            await self.runGraphQLSubscription(request, from: caller) {
                subscriptions.finish(id, of: caller, generation: generation)
            }
        }
        guard started else {
            throw RequestError(
                code: .invalidParams, message: RequestError.invalidParams.message,
                data: .object([
                    "subscriptionId": .string(request.subscriptionId.rawValue),
                    "reason": .string(Self.subscriptionIdInUseReason),
                ]))
        }
        return SAH.GraphQL.SubscribeResponse()
    }

    /// Runs one subscription: routes it, sends each event of its stream in
    /// `_sah/graphql/next`, then ends it with `complete` or `error`.
    ///
    /// `release` frees the subscription id before the last message, so the
    /// client can use the id again as soon as it reads the end. A cancelled
    /// subscription sends no end.
    ///
    /// - Parameters:
    ///   - request: The params of the call.
    ///   - caller: The connection of the call.
    ///   - release: Frees the subscription id.
    func runGraphQLSubscription(
        _ request: SAH.GraphQL.SubscribeRequest, from caller: ConnectionId, release: @Sendable () -> Void
    ) async {
        let subscriptionId = request.subscriptionId
        let ending: GraphQLTunnelEnding
        do {
            try await forwardEvents(of: request, from: caller)
            ending = .complete(SAH.GraphQL.CompleteNotification(subscriptionId: subscriptionId))
        } catch {
            let errors = GraphQLTunnelJSON.result(failingWith: error).errors ?? []
            ending = .error(SAH.GraphQL.ErrorNotification(subscriptionId: subscriptionId, payload: errors))
        }
        release()
        guard !Task.isCancelled else {
            return
        }
        do {
            try await ending.send(through: connections.path(of: caller)?.connection)
        } catch {
            ACPAgentTelemetry.logger(.graphQLTunnel).debug(
                "The end of a subscription did not reach its client.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
        }
    }

    /// Routes one subscription and sends each event of the stream of its
    /// endpoint in `_sah/graphql/next`, until the stream ends or the task is
    /// cancelled.
    ///
    /// - Parameters:
    ///   - request: The params of the call.
    ///   - caller: The connection of the call.
    /// - Throws: A routing error; an error of the endpoint or of its stream;
    ///   an error of the wire.
    private func forwardEvents(of request: SAH.GraphQL.SubscribeRequest, from caller: ConnectionId) async throws {
        let viewer = connections.viewer(of: caller)
        let endpoint = try tunnelEndpoint(named: request.endpoint, sessionId: request.sessionId, viewer: viewer)
        let stream = try await endpoint.subscribe(
            query: request.query, variables: GraphQLTunnelJSON.variables(from: request.variables),
            operationName: request.operationName, viewer: viewer)
        for try await text in stream {
            let next = SAH.GraphQL.NextNotification(
                subscriptionId: request.subscriptionId, payload: try GraphQLTunnelJSON.result(fromResponse: text))
            try await GraphQLTunnelEnding.sendNext(next, through: connections.path(of: caller)?.connection)
        }
    }
}

/// The last message of a subscription: `complete` or `error`.
enum GraphQLTunnelEnding: Sendable {
    /// The subscription ended with no error.
    case complete(SAH.GraphQL.CompleteNotification)

    /// The subscription ended with errors.
    case error(SAH.GraphQL.ErrorNotification)

    /// Sends this end to the client.
    ///
    /// - Parameter connection: The connection of the subscription, or `nil`
    ///   when it closed.
    /// - Throws: `ConnectionError.closed` when the connection closed; an
    ///   error of the wire.
    func send(through connection: AgentSideConnection?) async throws {
        let open = try Self.require(connection)
        switch self {
        case .complete(let notification):
            try await open.sendExtensionNotification(SAH.GraphQL.Method.complete, notification)
        case .error(let notification):
            try await open.sendExtensionNotification(SAH.GraphQL.Method.error, notification)
        }
    }

    /// Sends one event of a subscription to the client.
    ///
    /// - Parameters:
    ///   - next: The event.
    ///   - connection: The connection of the subscription, or `nil` when it
    ///     closed.
    /// - Throws: `ConnectionError.closed` when the connection closed; an
    ///   error of the wire.
    static func sendNext(_ next: SAH.GraphQL.NextNotification, through connection: AgentSideConnection?) async throws {
        try await require(connection).sendExtensionNotification(SAH.GraphQL.Method.next, next)
    }

    /// The connection of a subscription, when it is still open.
    ///
    /// - Parameter connection: The connection, or `nil` when it closed.
    /// - Returns: The connection.
    /// - Throws: `ConnectionError.closed` when it closed.
    private static func require(_ connection: AgentSideConnection?) throws -> AgentSideConnection {
        guard let connection else {
            throw ConnectionError.closed
        }
        return connection
    }
}
