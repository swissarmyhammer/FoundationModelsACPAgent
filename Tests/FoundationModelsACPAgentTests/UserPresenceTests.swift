import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
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

    // MARK: - session/resume

    /// Records a session with a client of `recordedWith`, then resumes it in
    /// a new agent with a client of `resumedWith`, over the same working
    /// directory.
    ///
    /// - Parameters:
    ///   - recordedWith: The capabilities of the client that records.
    ///   - resumedWith: The capabilities of the client that resumes.
    ///   - label: The directory label of the proof.
    /// - Returns: The presence of the recorded session and of the resumed one.
    /// - Throws: Whatever the fixtures, the prompt or the resume throws.
    private static func recordAndResume(
        recordedWith: ClientCapabilities, resumedWith: ClientCapabilities, label: String
    ) async throws -> (recorded: UserPresence?, resumed: UserPresence?) {
        let first = try await ScriptedPromptFixture.make(
            script: [.textDelta("recorded"), .endPass], label: label, capabilities: recordedWith)
        _ = try await first.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: first.sessionId, text: "record this session"))
        _ = try await ScriptedPromptFixture.waitForIdle(first.collector)
        await ScriptedPromptFixture.waitForPromptsFinished(first.harness.agent, first.sessionId)
        let recorded = try await presence(of: first)
        _ = try await first.harness.connection.closeSession(CloseSessionRequest(sessionId: first.sessionId))
        await first.close()

        let second = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "\(label)-second", capabilities: resumedWith,
            workingDirectory: first.cwd)
        _ = try await second.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: first.cwd.path), sessionId: first.sessionId,
                replayFrom: .start(ReplayFromStart())))
        let session = try #require(await second.harness.agent.sessions[first.sessionId]?.session)
        let resumed = runPlanePresence(of: session)
        await second.close()
        return (recorded, resumed)
    }

    /// A session recorded by an interactive client and resumed by a client
    /// with no elicitation capability is headless: the resume gives the
    /// presence of the client of now, not the recorded one.
    @Test
    func aSessionRecordedInteractiveAndResumedWithNoElicitationIsHeadless() async throws {
        let presences = try await Self.recordAndResume(
            recordedWith: ACPClient.advertisedCapabilities, resumedWith: ClientCapabilities(),
            label: "UserPresenceTests-resume-headless")

        #expect(presences.recorded == .interactive)
        #expect(presences.resumed == .headless)
    }

    /// The reverse: a session recorded by a client with no elicitation
    /// capability and resumed by an interactive client is interactive.
    @Test
    func aSessionRecordedHeadlessAndResumedByAnInteractiveClientIsInteractive() async throws {
        let presences = try await Self.recordAndResume(
            recordedWith: ClientCapabilities(), resumedWith: ACPClient.advertisedCapabilities,
            label: "UserPresenceTests-resume-interactive")

        #expect(presences.recorded == .headless)
        #expect(presences.resumed == .interactive)
    }
}
