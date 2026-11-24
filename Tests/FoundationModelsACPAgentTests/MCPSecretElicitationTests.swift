import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The secret question of the `mcpServers` tool (D101): the agent asks the
/// user for the secret of a new MCP server with a sensitive elicitation,
/// writes the answer to the secret store, and keeps the value out of the
/// model input, the tool result, the session updates and the recording.
@Suite(.closesHarnesses) struct MCPSecretElicitationTests {
  /// The prefix of the folders of the fixture.
  private static let label = "MCPSecretElicitationTests"

  /// The marker of the prompt whose pass adds the server.
  private static let addMarker = "Add the remote MCP server"

  /// The secret value that the user gives. It must not leak.
  private static let secret = "SECRET-TOKEN-7f3a9c"

  /// The name of the new server.
  private static let server = "remote"

  /// The steps of the pass: one call of the `mcpServers` tool that adds an
  /// http server with a secret header.
  private static func script() -> [ScriptedPassStep] {
    [
      .onPrompt(
        containing: addMarker,
        play: [
          .toolCall(
            name: ToolCatalog.mcpServersToolName,
            argumentsJSON:
              #"{"op":"add mcp server","name":"\#(server)","url":"https://example.com/mcp","secretHeaders":["Authorization"]}"#
          ),
          .endPass,
        ]),
      .endPass,
    ]
  }

  /// Waits until the session holds a pending question that is not `other`.
  ///
  /// - Parameters:
  ///   - session: The session model.
  ///   - other: The id of a question to skip, or `nil`.
  /// - Returns: The question.
  /// - Throws: A failed requirement when no question comes in time.
  private static func nextQuestion(
    in session: SessionModel, after other: PendingElicitation.ID?
  ) async throws -> PendingElicitation {
    for _ in 0..<400 {
      if let next = await ElicitationWait.pendingElicitations(in: session).first(where: {
        $0.id != other
      }) {
        return next
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw WaitEndedOnFailure(condition: "a new question reaches the client", event: "time out")
  }

  /// The user approves the server and gives the secret: the store has the
  /// value, the settings hold the reference, and no text that the model,
  /// the client or the recording gets has the value.
  @Test func theSecretGoesToTheStoreAndNowhereElse() async throws {
    let secrets = InMemoryWritableSecretStore()
    let recorder = PromptRecorder()
    let fixture = try await ScriptedPromptFixture.make(
      script: Self.script(), label: Self.label, recorder: recorder, secretStore: secrets)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.addMarker))
    let session = fixture.session

    let approval = try await Self.nextQuestion(in: session, after: nil)
    await MainActor.run { session.acceptElicitation(approval.id, content: .object([:])) }
    let question = try await Self.nextQuestion(in: session, after: approval.id)
    await MainActor.run {
      session.acceptElicitation(
        question.id,
        content: .object([AgentMCPServerSecrets.valueField: .string(Self.secret)]))
    }
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    let stored = try await fixture.harness.agent.settingsStore.value(
      at: SettingsMCPServerStorage.keyPath, cwd: nil)
    let prompts = await recorder.prompts
    let recorded = try Self.text(under: fixture.cwd)
    await fixture.close()

    guard case .object(let meta)? = question.request.meta else {
      Issue.record("the secret question has no _meta")
      return
    }
    #expect(meta[ElicitationAskerMeta.sensitiveKey] == .bool(true))
    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == Self.secret)
    #expect("\(String(describing: stored))".contains("keychain:mcp.remote.header.Authorization"))
    let updateText = String(decoding: try JSONEncoder().encode(updates), as: UTF8.self)
    #expect(!updateText.contains(Self.secret))
    #expect(!prompts.contains { $0.contains(Self.secret) })
    #expect(!recorded.isEmpty)
    #expect(!recorded.contains(Self.secret))
  }

  /// The text of each regular file below a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The texts, joined.
  /// - Throws: The error of a read.
  private static func text(under folder: URL) throws -> String {
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    var text = ""
    while let url = files?.nextObject() as? URL {
      if let data = try? Data(contentsOf: url) {
        text += String(decoding: data, as: UTF8.self)
      }
    }
    return text
  }
}
