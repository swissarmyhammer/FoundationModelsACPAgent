import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// A prompt whose deferred work never runs (Testudo ^7w2b5nn).
///
/// The agent accepts a `session/prompt` and adds its owner to the open prompts of the session. The
/// model run of the prompt runs after the response. When the connection closes while the handler
/// runs, the connection writes no response and discards the deferred run
/// (`afterRespondingToCurrentRequest(_:onDiscard:)`). The discard must end the prompt. If not, the
/// owner stays open, and a later close of the session waits for ever in
/// ``PromptStateOwner/waitForPromptEnd()``.
@Suite struct DiscardedPromptTests {
  /// The name of the command that holds the handler.
  private static let commandName = "hold"

  /// The text that the command renders.
  private static let renderedText = "held"

  @Test("a prompt that the connection discards ends, and the close of its session ends")
  func aDiscardedPromptEnds() async throws {
    let entered = WatchedValue(false)
    // The render runs in the handler of `session/prompt`, after the owner of the prompt is
    // open. It holds the handler until the close of the connection cancels the handler task.
    // Then the handler returns normally, and the connection discards the deferred run.
    let command = SlashCommand(
      name: Self.commandName,
      description: "holds the handler until the connection closes",
      body: .rendered { _ in
        entered.update { $0 = true }
        try? await waitForCancellation()
        return Self.renderedText
      })
    let fixture = try await ScriptedPromptFixture.make(
      script: [], label: "DiscardedPromptTests",
      commandProviders: [StubCommandProvider(commandSet: [command])])
    let agent = fixture.harness.agent
    let request = AgentClientHarness.makePromptRequest(
      sessionId: fixture.sessionId, text: "/\(Self.commandName)")
    let connection = fixture.harness.connection
    let send = Task { try? await connection.prompt(request) }

    _ = try await entered.wait(for: "the handler holds the prompt") { $0 }
    let owner = try #require(await agent.sessions[fixture.sessionId]?.openPrompts.first)
    await ConnectionCloseTests.dropClientEnd(of: fixture.harness)
    await agent.waitForTeardown(of: fixture.harness.routedConnection.id)
    await agent.awaitPromptsFinished(of: fixture.sessionId)
    _ = await send.value

    #expect(await agent.sessions[fixture.sessionId]?.openPrompts.isEmpty == true)
    #expect(await owner.stopReason == PromptExecution.stopReason(for: .cancelled))
    await agent.closeOpenSessions()
    #expect(await agent.sessions[fixture.sessionId]?.isClosed == true)
  }

  @Test("a wait for the end of a prompt ends when its task is cancelled")
  func aCancelledWaitForThePromptEndEnds() async {
    let owner = PromptStateOwner(send: { _ in })
    let wait = Task { await owner.waitForPromptEnd() }
    wait.cancel()
    await wait.value

    #expect(await owner.stopReason == nil)
  }
}
