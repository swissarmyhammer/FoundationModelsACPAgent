import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - Tier 3: the client library interop contract (cli-plan.md §9)
//
// The suite that drives this agent with the FoundationModelsACPClient
// library, in this process, over `InMemoryTransport.pair()`. A client is the
// library (cli-plan.md §6): the client package ships no binary, so no client
// process is spawned. The agent end is the public `ComposedAgent` of the
// agent library, which is the same composition `acp-agent` serves.
//
// The agent runs over the stub model, so the answer is deterministic, and
// the same prompt run through the built `acp-agent run` is the yardstick the
// library answer is held to.
//
// Two checks of the old suite, which ran the `acp-client` binary, have no
// meaning here, and the suite does not keep them:
// - "No wire frame leaks onto stdout." The library gives typed session
//   updates to its caller and writes no stdout, so there is no stream to
//   read. `StdioContractTests` holds the stdout of the agent side.
// - "No `acp-agent acp` process outlives the run." The in-process drive
//   spawns no agent process. Its equivalent is that
//   `ComposedAgent.waitForConnectionTeardown()` returns after the wire
//   closes. A teardown that does not end holds the test, and a sample of
//   the test process shows where it waits.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The interop contract of the FoundationModelsACPClient library against
/// the composed agent, over an in-memory transport.
///
/// Serialized so at most one prompt runs at a time.
@Suite(.serialized)
struct ClientInteropTests {
    // MARK: - Constants

    /// The subcommand of `acp-agent` that runs one prompt.
    private static let runSubcommand = "run"

    /// The prompt text. The stub model echoes it, so the answer is
    /// deterministic and is not empty.
    private static let promptText = "the two roles meet on an in-memory wire"

    /// The exit code of an `acp-agent run` prompt that reached its end.
    private static let endTurnExitCode: Int32 = 0

    // MARK: - The drivers

    /// What one library prompt gave back.
    private struct LibraryAnswer {
        /// The text of each agent message chunk, joined in arrival order.
        let text: String

        /// The stop reason of the first idle update, or `nil` when the
        /// update stream ended before the prompt went idle.
        let stopReason: StopReason?
    }

    /// Runs one prompt with the client library against the composed agent,
    /// over `InMemoryTransport.pair()`, and then closes the wire and waits
    /// for the teardown of the agent.
    ///
    /// - Parameter label: The directory label.
    /// - Returns: The answer text and the stop reason.
    /// - Throws: Whatever the composition, the handshake, the session call
    ///   or the prompt throws.
    private static func runClientLibrary(label: String) async throws -> LibraryAnswer {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let composed = try await composeStubAgent(
            name: TierThreeFixture.agentDotfolderName, label: label, workspace: workspace)
        #expect(composed.modelSource == .stub)
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await composed.serve(over: agentEnd)
        let model = await ConnectionModel()
        let connection = await model.connect(over: clientEnd)
        // Swift has no asynchronous `defer`, and the wire must come down on
        // the failing path as well, so the outcome is held here and given
        // back after the teardown.
        let outcome: Result<LibraryAnswer, any Error>
        do {
            outcome = .success(try await prompt(over: connection, in: workspace))
        } catch {
            outcome = .failure(error)
        }
        await connection.close()
        await agentConnection.close()
        clientEnd.close()
        agentEnd.close()
        await composed.waitForConnectionTeardown()
        return try outcome.get()
    }

    /// Sends `initialize`, `session/new` and one prompt over `connection`,
    /// and reads the answer off the update stream of the session.
    ///
    /// - Parameters:
    ///   - connection: The client end of the wire.
    ///   - workspace: The working directory of the session.
    /// - Returns: The answer text and the stop reason.
    /// - Throws: Whatever the handshake, the session call or the prompt
    ///   throws.
    private static func prompt(
        over connection: ClientSideConnection, in workspace: URL
    ) async throws -> LibraryAnswer {
        _ = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
        let session = try await connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        // Subscribe before the prompt, so the stream holds each update of
        // the prompt in order.
        let updates = connection.subscribe(to: session.sessionId).updates
        let collector = Task { await collectAnswer(from: updates) }
        do {
            _ = try await connection.prompt(
                AgentClientHarness.makePromptRequest(
                    sessionId: session.sessionId, text: promptText))
        } catch {
            collector.cancel()
            _ = await collector.value
            throw error
        }
        return await collector.value
    }

    /// Consumes the update stream of a session: joins the text of each agent
    /// message chunk, and stops at the first idle state update.
    ///
    /// - Parameter stream: The update stream, subscribed before the prompt.
    /// - Returns: The joined text and the stop reason of the idle update.
    private static func collectAnswer(
        from stream: AsyncStream<SessionStreamEvent>
    ) async -> LibraryAnswer {
        var text = ""
        for await case .update(let update) in stream {
            switch update {
            case .agentMessageChunk(let chunk):
                guard case .text(let content) = chunk.content else { break }
                text += content.text
            case .stateUpdate(.idle(let idle)):
                return LibraryAnswer(text: text, stopReason: idle.stopReason)
            default:
                break
            }
        }
        return LibraryAnswer(text: text, stopReason: nil)
    }

    /// Runs the built `acp-agent` for the same prompt, which is the yardstick
    /// the library answer is held to.
    ///
    /// - Parameter label: The directory label.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgentCLI(label: String) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.runAgent(
            arguments: [runSubcommand, promptText], label: label,
            environment: TierThreeFixture.stubModelEnvironment)
    }

    // MARK: - The contract

    /// The client library drives the composed agent over an in-memory
    /// transport to `end_turn`, and gets the answer that `acp-agent run`
    /// gives for the same prompt.
    ///
    /// The answer is compared after the surrounding whitespace is trimmed
    /// off both sides, because the agent CLI completes an answer that does
    /// not end with a newline (cli-plan.md §5.6). The text between is the
    /// claim. The teardown of the agent is awaited inside the run, so a
    /// teardown that does not end holds the test.
    @Test
    func theClientLibraryGetsTheAgentAnswerOverAnInMemoryTransport() async throws {
        let yardstick = try await Self.runAgentCLI(label: "ClientInterop-yardstick")
        #expect(yardstick.exitCode == Self.endTurnExitCode, "stderr: \(yardstick.standardError)")

        let answer = try await Self.runClientLibrary(label: "ClientInterop")

        #expect(answer.stopReason == .endTurn)
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!text.isEmpty, "the answer text is missing from the update stream")
        #expect(
            text == yardstick.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "the client library answered something else than the agent did: \(text)")
    }
}
