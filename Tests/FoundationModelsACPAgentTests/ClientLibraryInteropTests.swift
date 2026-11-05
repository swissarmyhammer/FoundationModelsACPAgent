import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The interop contract of the FoundationModelsACPClient library against the composed agent
/// (cli-plan.md §9). The client is the library, in this process, over `InMemoryTransport.pair()`:
/// the client package ships no binary, so no client process exists. The agent end is the public
/// `ComposedAgent` of the agent library, which is the same composition that `acp-agent` serves.
///
/// The agent runs over the stub model, so the answer is deterministic. The yardstick of the answer
/// is the `run` subcommand, driven in process over the same stub model.
@Suite(.stubModel, .timeLimit(.minutes(2))) struct ClientLibraryInteropTests {
  // MARK: - Constants

  /// The prompt text. The stub model echoes it, so the answer is deterministic and is not empty.
  private static let promptText = "the two roles meet on an in-memory wire"

  /// The prefix of the folders of each test.
  private static let label = "ClientLibraryInteropTests"

  // MARK: - The drivers

  /// What one library prompt gave back.
  private struct LibraryAnswer {
    /// The text of each agent message chunk, joined in arrival order.
    var text = ""

    /// The stop reason of the first idle update, or `nil` when the update stream ended before the
    /// prompt went idle.
    var stopReason: StopReason?
  }

  /// Runs one prompt with the client library against the composed agent, over
  /// `InMemoryTransport.pair()`, and then closes the wire and waits for the teardown of the agent.
  ///
  /// A teardown that does not end holds the test, and the time limit of the suite ends it.
  ///
  /// - Returns: The answer text and the stop reason.
  /// - Throws: Whatever the composition, the handshake, the session call or the prompt throws.
  private static func runClientLibrary() async throws -> LibraryAnswer {
    let workspace = makeResolvedDirectory(label: "\(label)-repo")
    let composed = try await composeStubAgent(
      name: AgentComposition.dotfolderName, label: label, workspace: workspace)
    #expect(composed.modelSource == .stub)
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await composed.serve(over: agentEnd)
    let model = await ConnectionModel()
    let connection = await model.connect(over: clientEnd)
    // Swift has no asynchronous `defer`, and the wire must come down on the failing path as well,
    // so the outcome is held here and given back after the teardown.
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
    await composed.closeOpenSessions()
    return try outcome.get()
  }

  /// Sends `initialize`, `session/new` and one prompt over `connection`, and reads the answer off
  /// the update stream of the session.
  ///
  /// - Parameters:
  ///   - connection: The client end of the wire.
  ///   - workspace: The working directory of the session.
  /// - Returns: The answer text and the stop reason.
  /// - Throws: Whatever the handshake, the session call or the prompt throws.
  private static func prompt(
    over connection: ClientSideConnection, in workspace: URL
  ) async throws -> LibraryAnswer {
    _ = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
    let session = try await connection.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
    // Subscribe before the prompt, so the stream holds each update of the prompt in order.
    let updates = connection.subscribe(to: session.sessionId).updates
    let collector = Task { await collectAnswer(from: updates) }
    do {
      _ = try await connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: promptText))
    } catch {
      collector.cancel()
      _ = await collector.value
      throw error
    }
    return await collector.value
  }

  /// Consumes the update stream of a session: joins the text of each agent message chunk, and stops
  /// at the first idle state update.
  ///
  /// - Parameter stream: The update stream, subscribed before the prompt.
  /// - Returns: The joined text and the stop reason of the idle update.
  private static func collectAnswer(
    from stream: AsyncStream<SessionStreamEvent>
  ) async -> LibraryAnswer {
    var answer = LibraryAnswer()
    for await case .update(let update) in stream {
      if case .stateUpdate(.idle(let idle)) = update {
        answer.stopReason = idle.stopReason
        return answer
      }
      answer.text += update.agentMessageText
    }
    return answer
  }

  /// Runs the `run` subcommand for the same prompt, in process over the stub model, which is the
  /// yardstick that the library answer is held to.
  ///
  /// - Returns: The text that `acp-agent run` writes to its output.
  /// - Throws: Whatever the parse, the composition or the prompt throws.
  private static func runSubcommandAnswer() async throws -> String {
    let fixture = ConfigCommandFixture(label: "\(label)-yardstick")
    let capture = try AnswerCapture(label: "\(label)-yardstick-answer")
    let run = try #require(
      try AcpAgentCommand.parseAsRoot(["run", "--cwd", fixture.workspace.path, promptText])
        as? AcpAgentCommand.Run)
    _ = try await run.perform(environment: fixture.makeStubEnvironment(), into: capture.writer)
    return try capture.text()
  }

  // MARK: - The contract

  /// The client library drives the composed agent over an in-memory transport to `end_turn`, and
  /// gets the answer that `acp-agent run` gives for the same prompt.
  ///
  /// The answer is compared after the surrounding whitespace is trimmed off both sides, because the
  /// agent CLI completes an answer that does not end with a newline (cli-plan.md §5.6). The text
  /// between is the claim.
  @Test
  func theClientLibraryGetsTheAgentAnswerOverAnInMemoryTransport() async throws {
    let yardstick = try await Self.runSubcommandAnswer()

    let answer = try await Self.runClientLibrary()

    #expect(answer.stopReason == .endTurn)
    let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(text.contains(Self.promptText), "the stub model did not echo the prompt: \(text)")
    #expect(text == yardstick.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
