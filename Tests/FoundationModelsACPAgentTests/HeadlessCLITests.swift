import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent run` has no UI that can answer a question, so its sessions
/// are headless (elicitation-plan task 6). Its handshake gives no
/// elicitation capability, and a tool that asks gets cancel at once, so the
/// run ends and does not wait.
struct HeadlessCLITests {
    /// The prompt of the asking run. It is the marker of the pass that asks.
    private static let promptText = "Ask the colour"

    /// The text that the asking snippet returns before the action of its
    /// answer.
    private static let answerPrefix = "the answer was "

    /// The snippet that asks one question and returns the action of the
    /// answer in a text that the test can find.
    private static let askingSnippet =
        #"const answer = await elicit("Which colour do you want?"); return "\#(answerPrefix)" + answer.action;"#

    /// The fixed point of task 6: after the handshake of the CLI, the agent
    /// reads no elicitation capability, so each session that it opens is
    /// headless. The check comes before any prompt, so on the old code it
    /// fails and does not wait.
    @Test
    func theHandshakeOfTheCLIGivesNoElicitationCapability() async throws {
        let composed = try await CLICompositionFixture.scripted(
            script: [.endPass], label: "HeadlessCLITests-handshake")
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        _ = await composed.serve(over: agentEnd)
        let model = await ConnectionModel()
        let connection = await model.connect(over: clientEnd)

        try await RunPrompt.handshake(over: connection)
        let capabilities = await composed.agent.negotiatedClientCapabilities
        let presence = await composed.agent.userPresence
        await connection.close()
        clientEnd.close()
        agentEnd.close()
        await composed.waitForConnectionTeardown()

        #expect(capabilities?.supportsElicitation == false)
        #expect(presence == .headless)
    }

    /// A run whose tool asks a question ends normally: the question gets
    /// cancel at once, the tool returns that cancel, and the prompt ends on
    /// `end_turn`.
    @Test
    func aRunWhoseToolAsksEndsNormallyWithTheCancelResult() async throws {
        let workspace = makeResolvedDirectory(label: "HeadlessCLITests-ask-repo")
        let composed = try await CLICompositionFixture.scripted(
            script: try ScriptedPromptFixture.makeToolPromptScript(
                code: Self.askingSnippet, onPromptContaining: Self.promptText),
            label: "HeadlessCLITests-ask")
        let capture = try AnswerCapture(label: "HeadlessCLITests-ask-answer")

        let result = try await RunPrompt.answer(
            of: composed, in: .new(workingDirectory: workspace), prompt: Self.promptText,
            into: capture.writer)
        let entry = try #require(await composed.agent.sessions.values.first)

        #expect(result.stopReason == .endTurn)
        #expect(String(describing: entry.history).contains("\(Self.answerPrefix)cancel"))
    }
}
