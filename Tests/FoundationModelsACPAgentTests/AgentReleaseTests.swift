import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The release of an agent, and of the Router sessions it made, after its
/// connection closed.
///
/// The agent keeps the hold of each model of its resident profile, and each
/// Router session keeps the profile too. When a reference cycle keeps the
/// agent or a session after the connection closed, the models stay in the
/// model pool of the process. On the CI machine on 2026-10-02 that left
/// 176359 bytes of the budget, and the next live-model suite of the process
/// could not resolve its profile (task `^173qn8n`). Two cycles did that: the
/// agent and its connection kept each other, and the command registry of a
/// session and its builtin command context kept each other, with the session
/// inside.
///
/// The agent and the Router session are actors, which have no deinit event
/// that a test can see. The tests wait for proxies whose release follows the
/// release of each one (`Support/ReleaseWatch.swift`), with no clock.
///
/// This suite has no `.closesHarnesses` trait: the registry of the trait
/// keeps each harness until its close, and the tests wait for the release
/// of the agent.
@Suite struct AgentReleaseTests {
    /// The text of the prompt.
    private static let promptText = "Say hello."

    /// The answer the scripted model gives.
    private static let answerText = "Hello."

    /// The directory label of this suite.
    private static let label = "AgentReleaseTests"

    /// Makes a scripted agent that holds a release sentinel
    /// (``AgentReleaseSentinel``), and whose scripted backends count on
    /// `lifetimes`. The caller keeps no reference to the sentinel.
    ///
    /// - Parameters:
    ///   - lifetimes: The count of the scripted backends.
    ///   - suffix: The end of the directory label.
    /// - Returns: The agent, and the value that the release of the sentinel
    ///   sets.
    /// - Throws: Whatever the construction throws.
    private static func makeWatchedAgent(
        lifetimes: BackendLifetimes, suffix: String
    ) async throws -> (agent: RoutedACPAgent, released: WatchedValue<Bool>) {
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-\(suffix)-cache"),
            userDirectory: makeResolvedDirectory(label: "\(label)-\(suffix)-user"),
            loader: makeScriptedModelLoader(
                script: [.textDelta(answerText), .endPass], lifetimes: lifetimes))
        let (sentinel, released) = AgentReleaseSentinel.make()
        await agent.registerCommandProviders([sentinel])
        return (agent, released)
    }

    /// Whether the collected updates hold a compaction update. The release
    /// of the scripted backends is the event of the release of the Router
    /// sessions only when no compaction replaced a backend
    /// (``RouterSessionReleaseWatch``).
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: `true` when a compaction update came.
    private static func holdsCompaction(_ updates: [UpdateSessionNotification]) -> Bool {
        updates.contains { notification in
            if case .compactionUpdate = notification.update { return true }
            return false
        }
    }

    @Test("A closed connection releases the agent it served")
    func aClosedConnectionReleasesTheAgentItServed() async throws {
        let lifetimes = BackendLifetimes()
        let released: WatchedValue<Bool>
        do {
            let watched = try await Self.makeWatchedAgent(lifetimes: lifetimes, suffix: "served")
            released = watched.released
            let harness = await AgentClientHarness.makeRecording(agent: watched.agent)
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            await harness.close()
        }
        // The release of the sentinel follows the release of the agent.
        _ = try await released.wait(for: "the agent is released") { $0 }
    }

    @Test("A closed connection releases the agent and the Router session of a closed session")
    func aClosedConnectionReleasesTheAgentAndTheRouterSessionOfAClosedSession() async throws {
        let lifetimes = BackendLifetimes()
        let released: WatchedValue<Bool>
        let updates: [UpdateSessionNotification]
        do {
            let watched = try await Self.makeWatchedAgent(lifetimes: lifetimes, suffix: "closed")
            released = watched.released
            let harness = await AgentClientHarness.makeRecording(agent: watched.agent)
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            let workspace = makeResolvedDirectory(label: "\(Self.label)-workspace")
            let session = try await harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
            _ = try await harness.connection.closeSession(
                CloseSessionRequest(sessionId: session.sessionId))
            updates = await (try #require(harness.collector)).updates
            await harness.close()
        }
        _ = try await released.wait(for: "the agent is released") { $0 }
        #expect(!Self.holdsCompaction(updates))
        #expect(lifetimes.madeCount > 0)
        try await RouterSessionReleaseWatch.waitForRelease(of: lifetimes)
    }

    @Test("A closed connection releases the agent and the Router session after a prompt")
    func aClosedConnectionReleasesTheAgentAndTheRouterSessionAfterAPrompt() async throws {
        let lifetimes = BackendLifetimes()
        let released: WatchedValue<Bool>
        let updates: [UpdateSessionNotification]
        do {
            let (sentinel, sentinelReleased) = AgentReleaseSentinel.make()
            released = sentinelReleased
            let fixture = try await ScriptedPromptFixture.make(
                loader: makeScriptedModelLoader(
                    script: [.textDelta(Self.answerText), .endPass], lifetimes: lifetimes),
                label: "\(Self.label)-prompt",
                commandProviders: [sentinel])
            try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.promptText)
            _ = try await fixture.harness.connection.closeSession(
                CloseSessionRequest(sessionId: fixture.sessionId))
            updates = await fixture.collector.updates
            await fixture.close()
        }
        _ = try await released.wait(for: "the agent is released") { $0 }
        #expect(!Self.holdsCompaction(updates))
        #expect(lifetimes.madeCount > 0)
        try await RouterSessionReleaseWatch.waitForRelease(of: lifetimes)
    }
}
