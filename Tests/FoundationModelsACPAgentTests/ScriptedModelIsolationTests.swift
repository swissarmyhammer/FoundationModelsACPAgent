import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The model isolation of two agents in one process (plan.md §20.1).
///
/// Router keeps its resident models in a pool, and the pool holds one
/// container for each model identity. `ModelPool.shared` is process-wide,
/// so two agents that name the same stub model would share one container:
/// the first script loaded would answer every later agent, and each later
/// agent would report a turn it did not script. Each agent therefore makes
/// its own pool, and this suite proves it.
@Suite struct ScriptedModelIsolationTests {
    /// The directory label of this suite, so a leftover directory says
    /// where it came from.
    private static let label = "ScriptedModelIsolationTests"

    /// The answer the first agent scripts.
    private static let firstAnswer = "the first agent answers"

    /// The answer the second agent scripts.
    private static let secondAnswer = "the second agent answers"

    /// The prompt text both turns send.
    private static let promptText = "Say what you were scripted to say"

    /// Two agents made in one process each play their own script. The
    /// second agent must not answer with the first agent's container.
    @Test(.timeLimit(.minutes(1)))
    func twoAgentsInOneProcessEachPlayTheirOwnScript() async throws {
        let first = try await ScriptedTurnFixture.make(
            script: [.textDelta(Self.firstAnswer), .endTurn], label: "\(Self.label)-first")
        let second = try await ScriptedTurnFixture.make(
            script: [.textDelta(Self.secondAnswer), .endTurn], label: "\(Self.label)-second")

        let firstUpdates = try await Self.promptAndWaitForIdle(of: first)
        let secondUpdates = try await Self.promptAndWaitForIdle(of: second)
        await first.close()
        await second.close()

        #expect(ScriptedTurnFixture.agentText(in: firstUpdates) == Self.firstAnswer)
        #expect(ScriptedTurnFixture.agentText(in: secondUpdates) == Self.secondAnswer)
    }

    /// Prompts the fixture's session and waits for the turn to end.
    ///
    /// - Parameter fixture: The wired fixture to prompt.
    /// - Returns: The collected notifications of the turn.
    /// - Throws: Whatever the prompt call or the wait throws.
    private static func promptAndWaitForIdle(
        of fixture: ScriptedTurnFixture
    ) async throws -> [UpdateSessionNotification] {
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: fixture.sessionId, text: promptText))
        return try await ScriptedTurnFixture.waitForIdle(fixture.collector)
    }
}
