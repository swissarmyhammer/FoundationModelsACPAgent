import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The marketplace list is user configuration, as the MCP servers are
/// (D193). The `skills` tool of a root session changes it. A child agent
/// run shares that tool, but it cannot change the list: the agent refuses
/// the write with a corrective, and the read operations still work.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildRunMarketplaceTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildRunMarketplaceTests"

  /// The agent that the root session starts.
  private static let childAgent = "configurer"

  /// The marker of the prompt of the root session that starts the child.
  private static let rootMarker = "ROOT-STARTS-A-CONFIGURING-CHILD"

  /// The marker of the prompt of the root session that adds a marketplace.
  private static let rootAddMarker = "ROOT-ADDS-A-MARKETPLACE"

  /// The marker of the prompt of the child.
  private static let childMarker = "CHILD-CHANGES-THE-MARKETPLACES"

  /// The URL of the marketplace that a call adds.
  private static let url = "https://example.com/child-marketplace.git"

  /// The name of the `skills` tool.
  private static let skillsTool = SkillOutputProtection.skillsToolName

  /// The call that adds the marketplace.
  private static let addCall = ScriptedPassStep.toolCall(
    name: skillsTool,
    argumentsJSON: #"{"op":"add marketplace","url":"\#(url)","allSkills":true}"#)

  /// The call that lists the marketplaces.
  private static let listCall = ScriptedPassStep.toolCall(
    name: skillsTool, argumentsJSON: #"{"op":"list marketplace"}"#)

  /// The JSON text of the outputs of the tool calls of one session.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - sessionId: The session.
  /// - Returns: The texts, joined.
  private static func toolOutputText(
    in updates: [UpdateSessionNotification], of sessionId: SessionId
  ) throws -> String {
    try updates.filter { $0.sessionId == sessionId }.compactMap { notification -> String? in
      guard case .toolCallUpdate(let update) = notification.update else { return nil }
      var text = ""
      if case .value(let output) = update.rawOutput {
        text += String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
      }
      if case .value(let content) = update.content {
        text += String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
      }
      return text
    }.joined()
  }

  /// The number of tool calls of the sessions other than `root` that
  /// ended.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - root: The root session.
  /// - Returns: The number of ended calls.
  private static func endedCalls(in updates: [UpdateSessionNotification], otherThan root: SessionId)
    -> Int
  {
    Set(
      updates.filter { $0.sessionId != root }.compactMap { notification -> ToolCallId? in
        guard case .toolCallUpdate(let update) = notification.update,
          case .value(let status) = update.status, status == .completed || status == .failed
        else { return nil }
        return update.toolCallId
      }
    ).count
  }

  /// A child run that adds a marketplace gets a corrective, the list does
  /// not change, and its `list marketplace` call still answers.
  @Test func aChildRunCannotChangeTheMarketplaces() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-repo")
    try AgentsToolTests.writeAgent(named: Self.childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: Self.childMarker, play: [Self.addCall, Self.listCall, .endPass]),
      .onPrompt(
        containing: Self.rootMarker,
        play: [
          AgentsToolTests.startAgentCall(agent: Self.childAgent, prompt: Self.childMarker), .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: Self.label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: Self.rootMarker))
    }
    let updates = try await fixture.collector.wait(for: "the two calls of the child end") {
      Self.endedCalls(in: $0, otherThan: root) >= 2
    }
    let entries = try await fixture.harness.agent.marketplaceRegistry.marketplaces()
    let child = try #require(updates.first { $0.sessionId != root }?.sessionId)
    let output = try Self.toolOutputText(in: updates, of: child)
    prompt.cancel()
    await fixture.close()

    #expect(!entries.map(\.source.url).contains(Self.url))
    #expect(output.contains(SettingsMarketplaceSourceStorage.childRunRefusal))
  }

  /// A root session adds a marketplace with its `skills` tool.
  @Test func aRootSessionChangesTheMarketplaces() async throws {
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: Self.rootAddMarker, play: [Self.addCall, .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: "\(Self.label)-root")
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.rootAddMarker))
    _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    let entries = try await fixture.harness.agent.marketplaceRegistry.marketplaces()
    await fixture.close()

    #expect(entries.map(\.source.url).contains(Self.url))
  }
}
