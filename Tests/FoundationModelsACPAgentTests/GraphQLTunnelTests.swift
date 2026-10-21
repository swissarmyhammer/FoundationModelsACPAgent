import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The GraphQL tunnel of the agent (ACPA-13, ACP-5): each `_sah/graphql/*`
/// call of a connection reaches the endpoint that it names, and the resolver
/// gets a `GraphQLViewer` built from the row of that connection in the
/// connection table: its id, its trust, the sessions that it owns, the
/// sessions that any connection owns, and the sessions that it started.
///
/// Each test binds its connections to one agent over the in-memory wire. A
/// host tool gives two probe endpoints, one with the session-folder scope
/// and one with the server scope, so each session of the agent has them as
/// top-level endpoints, and each probe records the viewer of each call.
@Suite(.closesHarnesses) struct GraphQLTunnelTests {
    /// The name of the probe endpoint with the session-folder scope.
    fileprivate static let folderProbeName = "folderProbe"

    /// The name of the probe endpoint with the server scope.
    fileprivate static let serverProbeName = "serverProbe"

    /// The name of an endpoint that the agent does not have.
    private static let unknownEndpointName = "noSuchEndpoint"

    /// The document that each probe call sends.
    private static let probeQuery = "{ probe }"

    /// The `cursor` query, which the `settings` and the `snapshots`
    /// endpoints both have (EXTRAS-9 rule 9).
    private static let cursorQuery = "{ cursor }"

    /// Two connections on one agent, a `userDevice` and an `external` one,
    /// each make a session and a `_sah/graphql/execute` call on it. The
    /// resolver gets a viewer with the id and the trust of the calling
    /// connection, the session that it owns and started, and both sessions
    /// as owned by a client.
    @Test
    func eachTunnelCallGetsTheViewerOfItsOwnConnection() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-viewers")

        let deviceResult = try await Self.execute(
            on: fixture.device, endpoint: Self.folderProbeName, sessionId: fixture.deviceSession)
        let externalResult = try await Self.execute(
            on: fixture.external, endpoint: Self.folderProbeName, sessionId: fixture.externalSession)

        let bothSessions: Set<String> = [fixture.deviceSession.rawValue, fixture.externalSession.rawValue]
        let deviceViewer = GraphQLViewer(
            clientId: fixture.device.routedConnection.id.rawValue, trust: .userDevice,
            ownedSessions: [fixture.deviceSession.rawValue], clientOwnedSessions: bothSessions,
            startedSessions: [fixture.deviceSession.rawValue])
        let externalViewer = GraphQLViewer(
            clientId: fixture.external.routedConnection.id.rawValue, trust: .external,
            ownedSessions: [fixture.externalSession.rawValue], clientOwnedSessions: bothSessions,
            startedSessions: [fixture.externalSession.rawValue])
        #expect(fixture.log.viewers.value == [deviceViewer, externalViewer])
        #expect(deviceResult == ProbeEndpoint.answer)
        #expect(externalResult == ProbeEndpoint.answer)
    }

    /// A call that names an endpoint that the agent does not have gives a
    /// result with one error coded `UNKNOWN_ENDPOINT`, and no data.
    @Test
    func aCallToAnUnknownEndpointGivesTheUnknownEndpointCode() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-unknown")

        let result = try await Self.execute(
            on: fixture.device, endpoint: Self.unknownEndpointName, sessionId: fixture.deviceSession)

        #expect(Self.errorCodes(of: result) == ["UNKNOWN_ENDPOINT"])
        #expect(result.data == nil)
        #expect(fixture.log.viewers.value.isEmpty)
    }

    /// An `external` connection that names the session of another
    /// connection, in a folder that it cannot see, on a session-folder
    /// endpoint, gets `NOT_FOUND` (EXTRAS-9 rule 4). The resolver never
    /// runs.
    @Test
    func anExternalCallOnTheFolderOfAnotherConnectionGivesNotFound() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-folder")

        let result = try await Self.execute(
            on: fixture.external, endpoint: Self.folderProbeName, sessionId: fixture.deviceSession)

        #expect(Self.errorCodes(of: result) == ["NOT_FOUND"])
        #expect(fixture.log.viewers.value.isEmpty)
    }

    /// A `userDevice` connection sees each folder: its call on the session of
    /// another connection reaches the resolver (EXTRAS-9 rule 4).
    @Test
    func aUserDeviceCallOnTheFolderOfAnotherConnectionReachesTheResolver() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-device-folder")

        let result = try await Self.execute(
            on: fixture.device, endpoint: Self.folderProbeName, sessionId: fixture.externalSession)

        #expect(result == ProbeEndpoint.answer)
        #expect(fixture.log.viewers.value.map { $0?.clientId } == [fixture.device.routedConnection.id.rawValue])
    }

    /// A call on a session-folder endpoint with no session gives
    /// `SESSION_REQUIRED`: the session selects the folder.
    @Test
    func aFolderCallWithNoSessionGivesTheSessionRequiredCode() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-no-session")

        let result = try await Self.execute(on: fixture.device, endpoint: Self.folderProbeName, sessionId: nil)

        #expect(Self.errorCodes(of: result) == ["SESSION_REQUIRED"])
        #expect(fixture.log.viewers.value.isEmpty)
    }

    /// A server endpoint needs no session: the server probe of the session
    /// tools, the `settings` endpoint and the `snapshots` endpoint of the
    /// agent each answer a call with no session.
    @Test
    func theServerEndpointsAnswerACallWithNoSession() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-server")

        let probe = try await Self.execute(on: fixture.external, endpoint: Self.serverProbeName, sessionId: nil)
        let settings = try await Self.execute(
            on: fixture.device, endpoint: SettingsGraph.endpointName, sessionId: nil, query: Self.cursorQuery)
        let snapshots = try await Self.execute(
            on: fixture.device, endpoint: SnapshotsGraph.endpointName, sessionId: nil, query: Self.cursorQuery)

        #expect(probe == ProbeEndpoint.answer)
        #expect(fixture.log.viewers.value.map { $0?.trust } == [.external])
        for result in [settings, snapshots] {
            #expect(result.errors == nil)
            #expect(Self.cursor(of: result) != nil)
        }
    }

    /// `_sah/graphql/endpoints` lists the endpoints of the agent and of the
    /// top-level tools of its sessions, each name one time.
    @Test
    func theEndpointListNamesTheAgentAndTheSessionEndpoints() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-list")

        let response = try await fixture.device.connection.callExtensionMethod(
            SAH.GraphQL.Method.endpoints, SAH.GraphQL.EndpointsRequest(),
            returning: SAH.GraphQL.EndpointsResponse.self)

        let names = response.endpoints.map(\.name)
        #expect(Set(names).count == names.count)
        let expected: Set<String> = [
            SettingsGraph.endpointName, SnapshotsGraph.endpointName, Self.folderProbeName, Self.serverProbeName,
        ]
        #expect(expected.isSubset(of: Set(names)))
        let folderProbe = try #require(response.endpoints.first { $0.name == Self.folderProbeName })
        #expect(folderProbe.scope == .sessionFolder)
        #expect(folderProbe.schema == ProbeEndpoint.probeSchema)
    }

    /// The `initialize` response advertises the tunnel in `_meta.sah`, with
    /// the endpoints of the agent.
    @Test
    func initializeAdvertisesTheEndpointsOfTheTunnel() async throws {
        let agent = try await AgentClientHarness.makeAgent()
        let harness = await AgentClientHarness.makeRecording(agent: agent)

        let response = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())

        let advertised = try #require(SAH.InitializeMeta.extract(from: response.meta))
        #expect(advertised.version == SAH.version)
        let names = Set(advertised.graphql.map(\.name))
        #expect(names.isSuperset(of: [SettingsGraph.endpointName, SnapshotsGraph.endpointName]))
    }

    /// `_sah/graphql/subscribe` sends each event of the stream of the
    /// endpoint in `_sah/graphql/next`, and `_sah/graphql/complete` at its
    /// end. The resolver gets the viewer of the calling connection.
    @Test
    func aSubscriptionSendsEachEventAndThenComplete() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-subscribe")
        let subscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "subscription-1")
        let recorder = try #require(fixture.external.graphQLNotifications)

        _ = try await Self.subscribe(
            on: fixture.external, id: subscriptionId, sessionId: fixture.externalSession)
        let notifications = try await recorder.wait(for: "the end of the subscription") { recorded in
            recorded.contains(where: \.endsSubscription)
        }

        #expect(
            notifications == [
                .next(SAH.GraphQL.NextNotification(subscriptionId: subscriptionId, payload: ProbeEndpoint.event)),
                .complete(SAH.GraphQL.CompleteNotification(subscriptionId: subscriptionId)),
            ])
        #expect(fixture.log.viewers.value.map { $0?.clientId } == [fixture.external.routedConnection.id.rawValue])
    }

    /// A subscription on an unknown endpoint ends with one
    /// `_sah/graphql/error` coded `UNKNOWN_ENDPOINT`.
    @Test
    func aSubscriptionOnAnUnknownEndpointEndsWithTheUnknownEndpointCode() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-subscribe-unknown")
        let subscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "subscription-unknown")
        let recorder = try #require(fixture.device.graphQLNotifications)

        _ = try await Self.subscribe(
            on: fixture.device, id: subscriptionId, sessionId: fixture.deviceSession, endpoint: Self.unknownEndpointName)
        let notifications = try await recorder.wait(for: "the end of the subscription") { recorded in
            recorded.contains(where: \.endsSubscription)
        }

        let errors = notifications.compactMap { notification in
            if case .error(let error) = notification { error } else { nil }
        }
        #expect(notifications.count == 1)
        let error = try #require(errors.first)
        #expect(error.subscriptionId == subscriptionId)
        #expect(Self.errorCodes(of: SAH.GraphQL.ExecutionResult(errors: error.payload)) == ["UNKNOWN_ENDPOINT"])
    }

    /// `_sah/graphql/unsubscribe` stops a subscription that is still open:
    /// the stream of the endpoint ends.
    @Test
    func anUnsubscribeEndsTheStreamOfTheEndpoint() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-unsubscribe", holdsStreams: true)
        let subscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "subscription-held")
        let recorder = try #require(fixture.device.graphQLNotifications)

        _ = try await Self.subscribe(on: fixture.device, id: subscriptionId, sessionId: fixture.deviceSession)
        _ = try await recorder.wait(for: "the first event") { !$0.isEmpty }
        try await fixture.device.connection.sendExtensionNotification(
            SAH.GraphQL.Method.unsubscribe, SAH.GraphQL.UnsubscribeNotification(subscriptionId: subscriptionId))

        _ = try await fixture.log.endedStreams.wait(for: "the end of the held stream") { $0 == 1 }
    }

    /// The close of a connection ends each subscription that it holds.
    @Test
    func theCloseOfAConnectionEndsItsSubscriptions() async throws {
        let fixture = try await TunnelFixture.make(label: "GraphQLTunnelTests-close", holdsStreams: true)
        let subscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "subscription-closed")
        let recorder = try #require(fixture.external.graphQLNotifications)

        _ = try await Self.subscribe(on: fixture.external, id: subscriptionId, sessionId: fixture.externalSession)
        _ = try await recorder.wait(for: "the first event") { !$0.isEmpty }
        await fixture.external.close()

        _ = try await fixture.log.endedStreams.wait(for: "the end of the held stream") { $0 == 1 }
    }

    // MARK: - Helpers

    /// Sends one `_sah/graphql/execute` call on the wire of `harness`.
    ///
    /// - Parameters:
    ///   - harness: The harness whose client sends the call.
    ///   - endpoint: The name of the endpoint.
    ///   - sessionId: The session of the call, or `nil`.
    ///   - query: The GraphQL document.
    /// - Returns: The result of the call.
    /// - Throws: Whatever the wire throws.
    private static func execute(
        on harness: AgentClientHarness, endpoint: String, sessionId: SessionId?, query: String = probeQuery
    ) async throws -> SAH.GraphQL.ExecutionResult {
        try await harness.connection.callExtensionMethod(
            SAH.GraphQL.Method.execute,
            SAH.GraphQL.ExecuteRequest(endpoint: endpoint, sessionId: sessionId, query: query),
            returning: SAH.GraphQL.ExecutionResult.self)
    }

    /// Sends one `_sah/graphql/subscribe` call on the wire of `harness`.
    ///
    /// - Parameters:
    ///   - harness: The harness whose client sends the call.
    ///   - id: The id of the new subscription.
    ///   - sessionId: The session of the call.
    ///   - endpoint: The name of the endpoint.
    /// - Returns: The response of the call.
    /// - Throws: Whatever the wire throws.
    private static func subscribe(
        on harness: AgentClientHarness, id: SAH.GraphQL.SubscriptionId, sessionId: SessionId,
        endpoint: String = folderProbeName
    ) async throws -> SAH.GraphQL.SubscribeResponse {
        try await harness.connection.callExtensionMethod(
            SAH.GraphQL.Method.subscribe,
            SAH.GraphQL.SubscribeRequest(
                subscriptionId: id, endpoint: endpoint, sessionId: sessionId, query: probeQuery),
            returning: SAH.GraphQL.SubscribeResponse.self)
    }

    /// The `extensions.code` of each error of a result, in order.
    ///
    /// - Parameter result: The result.
    /// - Returns: The codes; an error with no code gives no entry.
    private static func errorCodes(of result: SAH.GraphQL.ExecutionResult) -> [String] {
        (result.errors ?? []).compactMap { error in
            guard case .object(let extensions)? = jsonObject(of: error)?["extensions"],
                case .string(let code)? = extensions["code"]
            else {
                return nil
            }
            return code
        }
    }

    /// The `cursor` field of the data of a result.
    ///
    /// - Parameter result: The result of a `{ cursor }` query.
    /// - Returns: The cursor, or `nil` when the data has no cursor text.
    private static func cursor(of result: SAH.GraphQL.ExecutionResult) -> String? {
        guard case .string(let cursor)? = jsonObject(of: result.data)?["cursor"] else {
            return nil
        }
        return cursor
    }
}

/// One agent with two bound connections, each with one session in its own
/// folder: a `userDevice` connection and an `external` one. A host tool
/// gives each session the two probe endpoints.
private struct TunnelFixture {
    /// The `userDevice` connection.
    let device: AgentClientHarness

    /// The `external` connection.
    let external: AgentClientHarness

    /// The session that ``device`` started.
    let deviceSession: SessionId

    /// The session that ``external`` started.
    let externalSession: SessionId

    /// The record of the probe endpoints.
    let log: ProbeLog

    /// Makes the agent, registers the probe tool, binds the two
    /// connections, and opens one session on each.
    ///
    /// - Parameters:
    ///   - label: The prefix of the names of the session folders.
    ///   - holdsStreams: Whether the subscription stream of each probe stays
    ///     open after its first event.
    /// - Returns: The fixture.
    /// - Throws: Whatever the agent start or the wire throws.
    static func make(label: String, holdsStreams: Bool = false) async throws -> TunnelFixture {
        let agent = try await AgentClientHarness.makeAgent()
        let log = ProbeLog()
        await agent.registerHostTools([ProbeTool(log: log, holdsStreams: holdsStreams)])
        let device = await AgentClientHarness.makeRecording(agent: agent)
        let external = await AgentClientHarness.makeRecording(agent: agent, trust: .external)
        let deviceSession = try await openSession(on: device, label: "\(label)-device")
        let externalSession = try await openSession(on: external, label: "\(label)-external")
        return TunnelFixture(
            device: device, external: external, deviceSession: deviceSession, externalSession: externalSession,
            log: log)
    }

    /// Initializes the client of `harness` and opens one session over its
    /// wire, in a new folder.
    ///
    /// - Parameters:
    ///   - harness: The harness whose client opens the session.
    ///   - label: The prefix of the name of the new folder.
    /// - Returns: The id of the new session.
    /// - Throws: Whatever the wire throws.
    private static func openSession(on harness: AgentClientHarness, label: String) async throws -> SessionId {
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let response = try await harness.connection.newSession(
            AgentClientHarness.makeNewSessionRequest(cwd: makeResolvedDirectory(label: label)))
        return response.sessionId
    }
}

/// The record of the probe endpoints: the viewer of each call, in order, and
/// the count of subscription streams that ended.
private final class ProbeLog: Sendable {
    /// The viewer of each call, in order.
    let viewers = WatchedValue<[GraphQLViewer?]>([])

    /// The count of subscription streams that ended.
    let endedStreams = WatchedValue<Int>(0)
}

/// A GraphQL endpoint that records the viewer of each call and answers with
/// fixed JSON.
private struct ProbeEndpoint: GraphQLEndpoint {
    /// The SDL of the probe schema.
    static let probeSchema = "type Query { probe: String }"

    /// The JSON text of the answer of each execute.
    static let answerText = #"{"data":{"probe":"ok"}}"#

    /// The JSON text of the one event of each subscription.
    static let eventText = #"{"data":{"probe":"event"}}"#

    /// The answer of each execute, as the tunnel gives it.
    static let answer = SAH.GraphQL.ExecutionResult(data: .object(["probe": .string("ok")]))

    /// The one event of each subscription, as the tunnel gives it.
    static let event = SAH.GraphQL.ExecutionResult(data: .object(["probe": .string("event")]))

    /// The name of the endpoint.
    let name: String

    /// The version of the schema.
    let version = "1"

    /// The scope of the endpoint.
    let scope: GraphQLEndpointScope

    /// The SDL of the schema.
    let schema = probeSchema

    /// Where the endpoint records each call.
    let log: ProbeLog

    /// Whether the subscription stream stays open after its one event.
    let holdsStreams: Bool

    /// Records the viewer, and answers with ``answerText``.
    func execute(
        query _: String, variables _: [String: Map], operationName _: String?, viewer: GraphQLViewer?
    ) async throws -> String {
        log.viewers.update { $0.append(viewer) }
        return Self.answerText
    }

    /// Records the viewer, and gives a stream of one ``eventText``. The
    /// stream ends after the event unless ``holdsStreams``; its end counts
    /// in ``ProbeLog/endedStreams``.
    func subscribe(
        query _: String, variables _: [String: Map], operationName _: String?, viewer: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error> {
        log.viewers.update { $0.append(viewer) }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let log = log
        continuation.onTermination = { _ in log.endedStreams.update { $0 += 1 } }
        continuation.yield(Self.eventText)
        if !holdsStreams {
            continuation.finish()
        }
        return stream
    }
}

/// A host tool that gives the two probe endpoints, as a top-level tool of
/// each session.
private struct ProbeTool: GraphQLEndpointTool {
    /// The wire arguments; the tool reads nothing from them.
    @Generable
    struct Arguments {}

    let name = "graphql_probe"

    let description = "a host tool that gives the GraphQL probe endpoints"

    /// The session-folder probe and the server probe.
    let graphQLEndpoints: [any GraphQLEndpoint]

    /// Makes the tool over one log.
    ///
    /// - Parameters:
    ///   - log: Where the probes record each call.
    ///   - holdsStreams: Whether each subscription stream stays open.
    init(log: ProbeLog, holdsStreams: Bool) {
        graphQLEndpoints = [
            ProbeEndpoint(
                name: GraphQLTunnelTests.folderProbeName, scope: .sessionFolder, log: log, holdsStreams: holdsStreams),
            ProbeEndpoint(
                name: GraphQLTunnelTests.serverProbeName, scope: .server, log: log, holdsStreams: holdsStreams),
        ]
    }

    /// The model never calls the probe tool.
    func call(arguments _: Arguments) async throws -> String {
        ""
    }
}
