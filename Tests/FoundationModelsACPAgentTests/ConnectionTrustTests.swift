import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The trust of a connection comes from its credential, never from the
/// client (ACPA-5b, D120 b): the bind reads the bearer token that the
/// transport gives (`ACPConnectionInfo`, ACP-1). A token of a device of the
/// user is `userDevice`, any other token or no token is `external`, and a
/// connection with no connection header (stdio, `InMemoryTransport`: the
/// in-process UI and the local CLI) is `userDevice`. The id of the row is the
/// `Acp-Connection-Id` of the transport when it gives one.
@Suite(.closesHarnesses) struct ConnectionTrustTests {
    /// A connection whose bearer token is a token of a device of the user is
    /// `userDevice`.
    @Test
    func aConnectionWithAUserDeviceTokenIsUserDevice() async throws {
        let agent = try await Self.makeAgentOfTheUser()

        let harness = await AgentClientHarness.makeRecording(
            agent: agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.userDevice))

        #expect(Self.trust(of: harness) == .userDevice)
    }

    /// A connection whose bearer token is not a token of a device of the
    /// user is `external`.
    @Test
    func aConnectionWithAnotherTokenIsExternal() async throws {
        let agent = try await Self.makeAgentOfTheUser()

        let harness = await AgentClientHarness.makeRecording(
            agent: agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.other))

        #expect(Self.trust(of: harness) == .external)
    }

    /// A connection whose transport gives an `Acp-Connection-Id` and no
    /// bearer token is a remote client with no credential, thus `external`:
    /// only a connection with no connection header at all is in process.
    @Test
    func anHTTPConnectionWithNoTokenIsExternal() async throws {
        let agent = try await Self.makeAgentOfTheUser()
        let info = ACPConnectionInfo(id: ACPConnectionId(rawValue: UUID().uuidString), bearerToken: nil)

        let harness = await AgentClientHarness.makeRecording(agent: agent, connectionInfo: info)

        #expect(Self.trust(of: harness) == .external)
    }

    /// An `initialize` that claims the trust and the token of a device of
    /// the user, in its `_meta` and in its implementation name, does not
    /// change the trust of an `external` connection.
    @Test
    func anInitializeThatClaimsAUserDeviceDoesNotChangeTheTrust() async throws {
        let agent = try await Self.makeAgentOfTheUser()
        let harness = await AgentClientHarness.makeRecording(
            agent: agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.other))

        _ = try await harness.connection.initialize(Self.makeClaimingInitializeRequest())

        #expect(harness.routedConnection.clientCapabilities != nil)
        #expect(Self.trust(of: harness) == .external)
    }

    /// A connection with no credential, over the in-process wire, is
    /// `userDevice`, and the agent gives its row a new id.
    @Test
    func anInMemoryConnectionIsUserDevice() async throws {
        let agent = try await Self.makeAgentOfTheUser()

        let harness = await AgentClientHarness.makeRecording(agent: agent)

        #expect(Self.trust(of: harness) == .userDevice)
        #expect(harness.routedConnection.id != .direct)
    }

    /// The id of the row of a connection whose transport gives an
    /// `Acp-Connection-Id` is that id.
    @Test
    func theRowIdIsTheConnectionIdOfTheTransport() async throws {
        let agent = try await Self.makeAgentOfTheUser()
        let info = ACPConnectionInfo.makeHTTP(bearerToken: TestBearerToken.other)

        let harness = await AgentClientHarness.makeRecording(agent: agent, connectionInfo: info)

        #expect(harness.routedConnection.id.rawValue == info.id.rawValue)
    }

    /// The host gives the tokens of the devices of the user to the public
    /// composition (`ComposedAgent.compose`), and the bind of each
    /// connection of the composed agent reads them.
    @Test
    func theTokensThatTheHostGivesTheCompositionGiveTheTrust() async throws {
        let composed = try await composeStubAgent(
            name: AgentClientHarness.dotfolderName, label: "ConnectionTrustTests-composed",
            userDeviceTokens: Set([TestBearerToken.userDevice]))

        let device = await AgentClientHarness.makeRecording(
            agent: composed.agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.userDevice))
        let other = await AgentClientHarness.makeRecording(
            agent: composed.agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.other))

        #expect(Self.trust(of: device) == .userDevice)
        #expect(Self.trust(of: other) == .external)
    }

    /// A stub agent whose host lists ``TestBearerToken/userDevice`` as the
    /// one token of a device of the user.
    ///
    /// - Returns: The agent.
    /// - Throws: What the construction of the agent throws.
    private static func makeAgentOfTheUser() async throws -> RoutedACPAgent {
        try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "ConnectionTrustTests-cache"),
            userDeviceTokens: Set([TestBearerToken.userDevice]))
    }

    /// The trust that the connection table holds for the connection of
    /// `harness`.
    ///
    /// - Parameter harness: The harness whose connection to read.
    /// - Returns: The trust of its row.
    private static func trust(of harness: AgentClientHarness) -> ConnectionTrust {
        harness.agent.connections.viewer(of: harness.routedConnection.id).trust
    }

    /// An `initialize` request whose `_meta` claims the trust and the token
    /// of a device of the user, and whose implementation names a device of
    /// the user.
    ///
    /// - Returns: The request.
    private static func makeClaimingInitializeRequest() -> InitializeRequest {
        let plain = AgentClientHarness.makeInitializeRequest()
        let claim: JSONValue = .object([
            "trust": .string("userDevice"),
            "bearerToken": .string(TestBearerToken.userDevice),
        ])
        return InitializeRequest(
            info: Implementation(name: "userDevice", version: plain.info.version),
            protocolVersion: plain.protocolVersion,
            capabilities: plain.capabilities,
            meta: claim)
    }
}
