import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
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

    /// The text of the tool result when a headless snippet asks: the
    /// sandbox of a headless session has no `elicit`.
    private static let noUserPresentText = "no user is present"

    /// The snippet that asks one question.
    private static let askingSnippet = #"return await elicit("Which colour do you want?");"#

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

    /// A run whose snippet asks a question ends normally. The session is
    /// headless, so the sandbox installs no `elicit` (Multitool task 23):
    /// the snippet fails with a text that says that no user is present, and
    /// the prompt ends on `end_turn`. The model learns why, and nothing
    /// waits for a user.
    @Test
    func aRunWhoseToolAsksEndsNormallyBecauseNoUserIsPresent() async throws {
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
        #expect(String(describing: entry.history).contains(Self.noUserPresentText))
    }

    // MARK: - A tool that asks through its ToolContext

    /// A tool of the host that asks one question through its
    /// `ToolContext`, records the response, and returns it. It needs no
    /// Multitool sandbox.
    struct AskingTool: FoundationModels.Tool, BackgroundTool {
        /// The wire arguments; the tool reads nothing from them.
        @Generable
        struct Arguments {}

        /// The name of the tool.
        static let toolName = "ask_user"

        /// The responses that the tool got, in order.
        final class Responses: Sendable {
            /// The responses, under a lock.
            private let storage = Mutex<[ElicitationResponse]>([])

            /// Records one response.
            ///
            /// - Parameter response: The response.
            func record(_ response: ElicitationResponse) {
                storage.withLock { $0.append(response) }
            }

            /// The responses so far.
            var all: [ElicitationResponse] {
                storage.withLock { $0 }
            }
        }

        /// Where the tool records each response.
        let responses: Responses

        let name = Self.toolName

        let description = "a host tool that asks the user one question"

        var mount: ToolMount? { ToolMount(mode: .background, timeout: nil) }

        func call(arguments: Arguments) async throws -> String {
            guard let context = ToolContext.current else {
                return "no tool context"
            }
            let response = try await context.elicit(
                ElicitationRequest(
                    message: "Which colour do you want?", elicitationId: ULID(),
                    requestedSchema: ElicitationRequestedSchema(
                        properties: ["colour": .string(ElicitationStringSchema())], required: ["colour"])))
            responses.record(response)
            return "\(response.action.rawValue): \(response.reason ?? "")"
        }
    }

    /// The marker of the prompt whose pass calls the asking tool.
    private static let hostToolPromptText = "Ask through the host tool"

    /// A headless `acp-agent run` whose host tool asks through
    /// `ToolContext.elicit`: the tool gets cancel with the reason "no user
    /// is present" at once, and the run ends on `end_turn`. This covers the
    /// Extras path with no Multitool sandbox.
    @Test
    func aHostToolThatAsksInAHeadlessRunGetsCancelWithNoUserPresent() async throws {
        let workspace = makeResolvedDirectory(label: "HeadlessCLITests-host-tool-repo")
        let composed = try await CLICompositionFixture.scripted(
            script: [
                .onPrompt(
                    containing: Self.hostToolPromptText,
                    play: [.toolCall(name: AskingTool.toolName, argumentsJSON: "{}"), .endPass]),
                .endPass,
            ],
            label: "HeadlessCLITests-host-tool")
        let responses = AskingTool.Responses()
        await composed.agent.registerHostTools([AskingTool(responses: responses)])
        let capture = try AnswerCapture(label: "HeadlessCLITests-host-tool-answer")

        let result = try await RunPrompt.answer(
            of: composed, in: .new(workingDirectory: workspace), prompt: Self.hostToolPromptText,
            into: capture.writer)

        #expect(result.stopReason == .endTurn)
        #expect(responses.all == [.cancel(reason: RunPlane.noUserPresentReason)])
    }
}
