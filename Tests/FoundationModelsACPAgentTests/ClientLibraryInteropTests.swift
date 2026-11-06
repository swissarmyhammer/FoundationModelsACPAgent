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

  /// Runs one prompt with the client library against the composed agent, over
  /// `InMemoryTransport.pair()`, and then closes the wire and waits for the teardown of the agent
  /// (``ComposedClientWire/withSession(of:in:_:)``).
  ///
  /// - Returns: The answer text and the stop reason.
  /// - Throws: Whatever the composition, the handshake, the session call or the prompt throws.
  private static func runClientLibrary() async throws -> PromptUpdateRead {
    let workspace = makeResolvedDirectory(label: "\(label)-repo")
    let composed = try await composeStubAgent(
      name: AgentComposition.dotfolderName, label: label, workspace: workspace)
    #expect(composed.modelSource == .stub)
    return try await ComposedClientWire.withSession(of: composed, in: workspace) {
      connection, sessionId in
      try await prompt(over: connection, in: sessionId)
    }
  }

  /// Sends one prompt in the open session, and reads the answer off the update stream of the
  /// session.
  ///
  /// - Parameters:
  ///   - connection: The client end of the wire.
  ///   - sessionId: The open session.
  /// - Returns: The answer text and the stop reason.
  /// - Throws: Whatever the prompt throws.
  private static func prompt(
    over connection: ClientSideConnection, in sessionId: SessionId
  ) async throws -> PromptUpdateRead {
    // Subscribe before the prompt, so the stream holds each update of the prompt in order.
    let updates = connection.subscribe(to: sessionId).updates
    let collector = Task { await PromptUpdateRead.collect(from: updates) }
    do {
      _ = try await connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText))
    } catch {
      collector.cancel()
      _ = await collector.value
      throw error
    }
    return await collector.value
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
