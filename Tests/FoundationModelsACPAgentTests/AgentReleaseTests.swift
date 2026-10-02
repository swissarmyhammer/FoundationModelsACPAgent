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
@Suite struct AgentReleaseTests {
    /// How long a test waits for the release. The release is a deallocation
    /// after the last task of the closed connection ends, so it is short.
    private static let releaseDeadline: Duration = .seconds(5)

    /// The pause between two looks at the references.
    private static let pollInterval: Duration = .milliseconds(20)

    /// The text of the prompt.
    private static let promptText = "Say hello."

    /// The answer the scripted model gives.
    private static let answerText = "Hello."

    @Test("A closed connection releases the agent it served")
    func aClosedConnectionReleasesTheAgentItServed() async throws {
        weak var served: RoutedACPAgent?
        do {
            let harness = try await AgentClientHarness.makeRecording()
            served = harness.agent
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            await harness.close()
        }
        #expect(
            await Self.isReleased { served },
            "the agent outlived its closed connection, so its models stay resident")
    }

    @Test("A closed connection releases the agent and the Router session of a closed session")
    func aClosedConnectionReleasesTheAgentAndTheRouterSessionOfAClosedSession() async throws {
        weak var served: RoutedACPAgent?
        weak var routerSession: (any RoutedSession)?
        do {
            let harness = try await AgentClientHarness.makeRecording()
            served = harness.agent
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            let workspace = makeResolvedDirectory(label: "AgentReleaseTests-workspace")
            let session = try await harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
            routerSession = await harness.agent.sessions[session.sessionId]?.session
            _ = try await harness.connection.closeSession(
                CloseSessionRequest(sessionId: session.sessionId))
            await harness.close()
        }
        #expect(
            await Self.isReleased { served },
            "a closed session kept the agent alive, so its models stay resident")
        #expect(
            await Self.isReleased { routerSession },
            "the Router session outlived its agent, so its models stay resident")
    }

    @Test("A closed connection releases the agent and the Router session after a prompt")
    func aClosedConnectionReleasesTheAgentAndTheRouterSessionAfterAPrompt() async throws {
        weak var served: RoutedACPAgent?
        weak var routerSession: (any RoutedSession)?
        do {
            let fixture = try await ScriptedPromptFixture.make(
                script: [.textDelta(Self.answerText), .endPass], label: "AgentReleaseTests-prompt")
            served = fixture.harness.agent
            routerSession = await fixture.harness.agent.sessions[fixture.sessionId]?.session
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
            _ = try await fixture.harness.connection.closeSession(
                CloseSessionRequest(sessionId: fixture.sessionId))
            await fixture.close()
        }
        #expect(
            await Self.isReleased { served },
            "a prompt kept the agent alive, so its models stay resident")
        #expect(
            await Self.isReleased { routerSession },
            "the Router session outlived its agent, so its models stay resident")
    }

    /// Waits until `reference` gives `nil`, or until ``releaseDeadline``.
    ///
    /// - Parameter reference: Reads one weak reference.
    /// - Returns: `true` when the object was released before the deadline.
    private static func isReleased(_ reference: () -> AnyObject?) async -> Bool {
        let end = ContinuousClock.now + releaseDeadline
        while reference() != nil, ContinuousClock.now < end {
            try? await Task.sleep(for: pollInterval)
        }
        return reference() == nil
    }
}
