import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The user presence of a session (elicitation-plan task 7). The agent
/// decides it when it opens the session, from the client capabilities of
/// `initialize` and from the bound connection, and gives it to Router. In a
/// headless session, a question ends at once with cancel, so it never waits
/// for a user who is not there.
struct UserPresenceTests {
    /// The presence of the Router session of the fixture's one session.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The presence of its run plane.
    /// - Throws: When the session is missing.
    private static func presence(of fixture: ScriptedPromptFixture) async throws -> UserPresence? {
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        return runPlanePresence(of: session)
    }

    /// A client that answers elicitations gets an interactive session: a
    /// question of a tool goes to the client.
    @Test
    func aClientThatAnswersElicitationsGetsAnInteractiveSession() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "UserPresenceTests-interactive")
        let presence = try await Self.presence(of: fixture)
        await fixture.close()

        #expect(presence == .interactive)
    }

    /// A client with no elicitation capability gets a headless session.
    @Test
    func aClientWithNoElicitationCapabilityGetsAHeadlessSession() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "UserPresenceTests-no-capability", capabilities: ClientCapabilities())
        let presence = try await Self.presence(of: fixture)
        await fixture.close()

        #expect(presence == .headless)
    }

    /// An agent with no bound ACP client connection opens headless sessions:
    /// no relay is wired, so no user can answer (elicitation-plan task 7).
    /// The client capabilities of its `initialize` do not change that.
    @Test
    func anAgentWithNoBoundConnectionOpensAHeadlessSession() async throws {
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "UserPresenceTests-unbound-cache"),
            loader: makeScriptedModelLoader(script: [.endPass]))
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        let response = try await agent.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: makeResolvedDirectory(label: "UserPresenceTests-unbound").path)))
        let session = try #require(await agent.sessions[response.sessionId]?.session)
        let presence = runPlanePresence(of: session)
        _ = try await agent.closeSession(CloseSessionRequest(sessionId: response.sessionId))

        #expect(presence == .headless)
    }
}
