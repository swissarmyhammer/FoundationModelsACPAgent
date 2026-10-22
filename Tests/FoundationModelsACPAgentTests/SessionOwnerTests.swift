import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The owner of a session (ACPA-5c, D120 c, D11): the connection that made
/// it, or the `userDevice` connection that took it with `session/resume`.
/// The requests that need the user, and each `session/update`, go to the
/// owner only, and an `external` connection cannot take a session that has
/// an owner.
@Suite(.closesHarnesses) struct SessionOwnerTests {
    /// The text of each prompt. The scripted model runs the eliciting tool
    /// only on a prompt that contains it.
    private static let promptText = "Run the eliciting tool pass"

    /// The `data.code` of the refusal of a take by an `external` connection.
    private static let sessionHasOwnerCode = "SESSION_HAS_OWNER"

    /// The answer that the held work writes after its connection closed.
    private static let lateAnswer = "The work went on after the close."

    /// Connection A makes a session, and its question goes to A only. An
    /// `external` connection B cannot take the session. A `userDevice`
    /// connection C takes it with `session/resume`: then its question and
    /// its updates go to C, and A gets none.
    @Test
    func theRequestsOfASessionGoToItsOwnerAndOnlyAUserDeviceTakesIt() async throws {
        let owner = try await ScriptedPromptFixture.makeLoopback(
            code: ScriptedPromptFixture.loopbackFormSnippet, label: "SessionOwnerTests-requests",
            onPromptContaining: Self.promptText)
        let external = await AgentClientHarness.makeRecording(
            agent: owner.harness.agent, connectionInfo: .makeHTTP(bearerToken: TestBearerToken.other))
        let taker = await AgentClientHarness.makeRecording(agent: owner.harness.agent)
        let ownerCreates = try #require(owner.harness.elicitations)
        let externalCreates = try #require(external.elicitations)
        let takerCreates = try #require(taker.elicitations)

        try await Self.answerOneQuestion(on: owner)
        #expect(await externalCreates.creates.isEmpty)
        #expect(await takerCreates.creates.isEmpty)

        let resume = ResumeSessionRequest(
            cwd: AbsolutePath(rawValue: owner.cwd.path), sessionId: owner.sessionId,
            mcpServers: [try ScriptedPromptFixture.makeLoopbackServer()])
        _ = try await external.connection.initialize(AgentClientHarness.makeInitializeRequest())
        try await Self.expectOwnerRefusal { _ = try await external.connection.resumeSession(resume) }

        _ = try await taker.connection.initialize(AgentClientHarness.makeInitializeRequest())
        _ = try await taker.connection.resumeSession(resume)
        let table = owner.harness.agent.connections
        #expect(table.owner(of: owner.sessionId) == taker.routedConnection.id)
        #expect(table.starter(of: owner.sessionId) == owner.harness.routedConnection.id)
        _ = try await taker.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: owner.sessionId, text: Self.promptText))
        _ = try await ScriptedPromptFixture.waitForIdle(try #require(taker.collector))

        #expect(await takerCreates.creates.count == 1)
        #expect(await ownerCreates.creates.count == 1)
        #expect(await externalCreates.creates.isEmpty)
        #expect(ScriptedPromptFixture.idleCount(in: await owner.collector.updates) == 1)
        await owner.close()
    }

    /// Connection A makes a session and starts work, and its wire closes
    /// while the work runs (ACPA-5d, D120 d, D68). The session is not closed:
    /// it has no owner, and its work goes on to its end. A `userDevice`
    /// connection B then takes it with `session/resume` and gets its updates,
    /// the answer that the work wrote after A closed among them.
    @Test
    func aClosedConnectionFreesItsSessionAndTheWorkGoesOn() async throws {
        let hold = ScriptedHold()
        let fixture = try await ScriptedPromptFixture.make(
            script: [.holdUntilReleased(hold), .textDelta(Self.lateAnswer), .endPass],
            label: "SessionOwnerTests-free")
        let agent = fixture.harness.agent
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
        _ = try await fixture.collector.wait(for: "the running of the prompt") { updates in
            updates.contains { if case .stateUpdate(.running) = $0.update { true } else { false } }
        }

        await ConnectionCloseTests.dropClientEnd(of: fixture.harness)
        hold.release()
        await agent.waitForTeardown(of: fixture.harness.routedConnection.id)
        await agent.awaitPromptsFinished(of: fixture.sessionId)

        #expect(await agent.sessions[fixture.sessionId]?.isClosed == false)
        #expect(agent.connections.owner(of: fixture.sessionId) == nil)

        let taker = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await taker.connection.initialize(AgentClientHarness.makeInitializeRequest())
        _ = try await taker.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId,
                replayFrom: .start(ReplayFromStart())))
        let takerCollector = try #require(taker.collector)
        _ = try await takerCollector.wait(for: "the replay of the late answer") { updates in
            (try? encodedWireText(of: updates))?.contains(Self.lateAnswer) == true
        }
        #expect(agent.connections.owner(of: fixture.sessionId) == taker.routedConnection.id)
    }

    /// Prompts the session of `fixture` on its own connection, declines the
    /// one question of the prompt, and waits for the `idle` of the prompt.
    ///
    /// - Parameter fixture: The fixture whose connection owns the session.
    /// - Throws: Whatever the wire or a wait throws.
    private static func answerOneQuestion(on fixture: ScriptedPromptFixture) async throws {
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
        await MainActor.run {
            fixture.session.declineElicitation(pending.id)
        }
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    }

    /// Runs `take` and expects the refusal of a take by an `external`
    /// connection: an invalid-request error with ``sessionHasOwnerCode`` in
    /// its `data`.
    ///
    /// - Parameter take: The `session/resume` call that must be refused.
    /// - Throws: What `take` throws when it is not the refusal.
    private static func expectOwnerRefusal(_ take: () async throws -> Void) async throws {
        do {
            try await take()
            Issue.record("expected the refusal of an external take")
        } catch let error as RequestError {
            #expect(error.code == .invalidRequest)
            let fields = try #require(jsonObject(of: error.data), "expected object data, got \(String(describing: error.data))")
            #expect(fields["code"] == .string(sessionHasOwnerCode))
        }
    }
}
