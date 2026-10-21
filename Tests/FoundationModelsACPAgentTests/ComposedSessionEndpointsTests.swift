import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The GraphQL endpoints of a session that the agent composes (EXTRAS-9): a
/// host reads the endpoints only from the top-level tools of the session
/// (`GraphQLEndpointTool`), and the `runCode` tool gives the endpoints of its
/// registry. Among them are the one `settings` endpoint of the agent and the
/// `snapshots` endpoint over the snapshot store of the agent.
///
/// Each test composes a session through
/// `RoutedACPAgent.composeSession(from:workingDirectory:additionalRoots:clientMCPServers:userPresence:)`,
/// the path of `session/new`, over temporary folders only.
@Suite struct ComposedSessionEndpointsTests {
    /// The version of the schema of the `settings` and the `snapshots`
    /// endpoints. Neither endpoint type gives its version as a static
    /// constant.
    private static let schemaVersion = "1"

    /// The endpoints of the top-level tools of one session that the agent
    /// composes, in tool order.
    ///
    /// - Parameter label: The label of the temporary folders of the agent
    ///   and of the session.
    /// - Returns: The endpoints of each top-level tool that gives endpoints.
    /// - Throws: Whatever the agent start, the settings load or the session
    ///   composition throws.
    private static func topLevelEndpoints(label: String) async throws -> [any GraphQLEndpoint] {
        let agent = try await AgentClientHarness.makeInitializedAgent(label: label)
        let workingDirectory = makeResolvedDirectory(label: "\(label)-repo")
        let loaded = try await LoadedSessionContext.load(workingDirectory: workingDirectory, from: agent.settingsStore)
        let composition = try await agent.composeSession(
            from: loaded, workingDirectory: workingDirectory, additionalRoots: [], clientMCPServers: [],
            userPresence: .headless)
        let endpoints = composition.surface.tools
            .compactMap { tool in tool as? any GraphQLEndpointTool }
            .flatMap(\.graphQLEndpoints)
        await composition.surface.shutdown()
        return endpoints
    }

    /// The top-level tools of a composed session give the `settings`
    /// endpoint, with its version and the server scope.
    @Test func aComposedSessionGivesTheSettingsEndpoint() async throws {
        let endpoints = try await Self.topLevelEndpoints(label: "ComposedSessionEndpointsTests-settings")

        let settings = try #require(endpoints.first { endpoint in endpoint.name == SettingsGraph.endpointName })
        #expect(settings.version == Self.schemaVersion)
        #expect(settings.scope == .server)
    }

    /// The top-level tools of a composed session give the `snapshots`
    /// endpoint, with its version and the server scope.
    @Test func aComposedSessionGivesTheSnapshotsEndpoint() async throws {
        let endpoints = try await Self.topLevelEndpoints(label: "ComposedSessionEndpointsTests-snapshots")

        let snapshots = try #require(endpoints.first { endpoint in endpoint.name == SnapshotsGraph.endpointName })
        #expect(snapshots.version == Self.schemaVersion)
        #expect(snapshots.scope == .server)
    }
}
