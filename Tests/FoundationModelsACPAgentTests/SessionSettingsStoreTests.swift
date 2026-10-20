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

    /// Makes a stub agent over throwaway folders, and runs `initialize`.
    ///
    /// - Parameter label: The prefix that names the test.
    /// - Returns: The initialized agent.
    /// - Throws: What the construction or the handshake throws.
    private static func makeInitializedAgent(label: String) async throws -> RoutedACPAgent {
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: makeResolvedDirectory(label: "\(label)-user"))
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        return agent
    }

    /// The `session/new` request for `cwd`.
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: The request.
    private static func makeNewSessionRequest(cwd: URL) -> NewSessionRequest {
        NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path))
    }

    /// A second `session/new` for the same working directory reads the
    /// session level in memory. A later outside write of text that does not
    /// parse does not reach it: the store keeps the tree that it read, and a
    /// fresh load of the file would fail.
    @Test func aSessionStartReadsTheSettingsInMemory() async throws {
        let agent = try await Self.makeInitializedAgent(label: "SessionSettingsStoreTests-memory")
        let cwd = makeResolvedDirectory(label: "SessionSettingsStoreTests-memory-repo")
        _ = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))
        let sessionRoot = try #require(
            agent.settingsFolders.stack(for: .configuration, workingDirectory: cwd).layers
                .first { $0.source == .project }
        ).root

        try ConfigFileFixture.write(Self.malformedYAML, in: sessionRoot)
        let response = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        #expect(await agent.sessions[response.sessionId] != nil)
    }
}
