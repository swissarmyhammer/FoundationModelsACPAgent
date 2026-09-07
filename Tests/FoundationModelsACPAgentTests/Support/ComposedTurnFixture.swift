import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// One turn against an agent the shared `AgentComposition` built
/// (cli-plan.md §5.10): compose over an environment and a working
/// directory, drive one prompt through the in-process harness, and give
/// back the text the turn streamed.
///
/// The composition suite and the `acp` suite both drive a turn this way,
/// and the `acp` suite drives one over each wire of §4, so the
/// composition and the drive stand in one place and cannot drift.
enum ComposedTurnFixture {
    /// Composes the agent over `environment`, runs one turn of `prompt`
    /// in `workspace`, and returns the agent text the turn streamed.
    ///
    /// `environment` must select the stub model: the fixture asserts the
    /// composition took that path, so no weights load and no network is
    /// touched.
    ///
    /// - Parameters:
    ///   - environment: The environment the composition reads.
    ///   - workspace: The session working directory.
    ///   - prompt: The text of the one turn.
    ///   - wire: The transport pair the turn runs over. The in-process
    ///     pair by default.
    /// - Returns: The streamed agent text, chunks joined in arrival order.
    /// - Throws: Whatever the composition, the handshake or the turn
    ///   throws.
    static func answerText(
        environment: [String: String],
        workspace: URL,
        prompt: String,
        wire: HarnessWire = .makeInMemory()
    ) async throws -> String {
        let composed = try await AgentComposition.compose(
            workingDirectory: workspace, environment: environment)
        #expect(composed.modelSource == .stub)
        let harness = await AgentClientHarness.makeRecording(agent: composed.agent, wire: wire)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let session = try await harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        let collector = try #require(harness.collector)
        _ = try await harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: prompt))
        let updates = try await ScriptedTurnFixture.waitForIdle(collector)
        await harness.close()
        return agentMessageText(in: updates)
    }
}
