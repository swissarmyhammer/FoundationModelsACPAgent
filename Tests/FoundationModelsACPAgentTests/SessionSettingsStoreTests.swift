import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The session start paths read the settings from the ``SettingsStore`` of
/// the agent (ACPA-17, D100(f)), and not from a fresh load of the files.
///
/// Each test uses temporary folders only, and the in-memory secret store of
/// ``makeStubAgent(name:cacheDirectory:recordingsDirectory:userDirectory:loader:tracer:inlineSettleGrace:environment:secretStore:prepareRouter:)``.
@Suite struct SessionSettingsStoreTests {
    /// A `config.yaml` text that does not parse.
    private static let malformedYAML = "compaction: [not closed\n"

    /// A second `session/new` for the same working directory reads the
    /// session level in memory. A later outside write of text that does not
    /// parse does not reach it: the store keeps the tree that it read, and a
    /// fresh load of the file would fail.
    @Test func aSessionStartReadsTheSettingsInMemory() async throws {
        let agent = try await AgentClientHarness.makeInitializedAgent(label: "SessionSettingsStoreTests-memory")
        let cwd = makeResolvedDirectory(label: "SessionSettingsStoreTests-memory-repo")
        _ = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))
        let sessionRoot = try #require(
            agent.settingsFolders.stack(for: .configuration, workingDirectory: cwd).layers
                .first { $0.source == .project }
        ).root

        try ConfigFileFixture.write(Self.malformedYAML, in: sessionRoot)
        let response = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))

        #expect(await agent.sessions[response.sessionId] != nil)
    }

    /// The close of the connection stops the watch of the settings store of
    /// the agent: each open `changes()` stream of the store ends.
    @Test(.timeLimit(.minutes(1))) func aConnectionCloseStopsTheSettingsWatch() async throws {
        let agent = try await AgentClientHarness.makeInitializedAgent(label: "SessionSettingsStoreTests-close")
        var changes = await agent.settingsStore.changes().makeAsyncIterator()

        await agent.closeOpenSessions(after: .closedLocally)

        #expect(await changes.next() == nil)
    }

    /// The agent has one `settings` endpoint over its one store
    /// (EXTRAS-9 rule 9): the ``SettingsTool`` of each session composition
    /// runs on that same endpoint instance, and builds no schema of its own.
    @Test func eachSessionSettingsToolUsesTheOneEndpointOfTheAgent() async throws {
        let agent = try await AgentClientHarness.makeInitializedAgent(label: "SessionSettingsStoreTests-endpoint")
        let directories = ["first", "second"].map { name in
            makeResolvedDirectory(label: "SessionSettingsStoreTests-endpoint-\(name)")
        }

        var endpoints: [SettingsGraph] = []
        for directory in directories {
            let loaded = try await LoadedSessionContext.load(workingDirectory: directory, from: agent.settingsStore)
            let context = await agent.catalogContext(
                from: loaded, workingDirectory: directory, additionalRoots: [], clientMCPServers: [])
            let tool = try #require(ToolCatalog.settingsTool(in: context))
            endpoints.append(try #require(tool.graphQLEndpoints.first as? SettingsGraph))
        }

        #expect(endpoints.count == directories.count)
        #expect(endpoints.allSatisfy { endpoint in endpoint === agent.settingsEndpoint })
    }
}
