import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// Fork from Here after two turns (D205, bug ^campexj): each answer has its own agent message,
/// and a cut on a message of turn 1 or turn 2 forks turn 1, with the echo model and with a
/// scripted model, through the real session directory of the Router.
@Suite(.closesHarnesses) struct SessionForkEchoTests {
  /// The prompt of turn 1.
  private static let firstPrompt = "Plan step one"

  /// The prompt of turn 2.
  private static let secondPrompt = "Plan step two"

  /// The number of idle updates after two completed turns.
  private static let twoTurns = 2

  /// The directory label of the suite.
  private static let label = "SessionForkEchoTests"

  /// The script of the scripted model: one answer for each prompt.
  private static let script: [ScriptedPassStep] = [
    .onPrompt(containing: firstPrompt, play: [.textDelta("First"), .endPass]),
    .onPrompt(containing: secondPrompt, play: [.textDelta("Second"), .endPass]),
    .endPass,
  ]

  /// The model of a test.
  enum Model: CaseIterable, Sendable {
    /// The echo model: each answer is its prompt.
    case echo

    /// The scripted model of ``SessionForkEchoTests/script``.
    case scripted
  }

  /// A fixture over a model, after two turns.
  ///
  /// - Parameters:
  ///   - model: The model.
  ///   - name: The name of the test, for the directories.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction or a prompt throws.
  private static func twoTurns(on model: Model, _ name: String) async throws
    -> ScriptedPromptFixture
  {
    let label = "\(Self.label)-\(name)-\(model)"
    let fixture =
      switch model {
      case .echo:
        try await ScriptedPromptFixture.make(loader: StubModelLoader(), label: label)
      case .scripted:
        try await ScriptedPromptFixture.make(script: script, label: label)
      }
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: firstPrompt)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: secondPrompt, count: twoTurns)
    return fixture
  }

  /// The retained history of a session of the agent of `fixture`.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - fixture: The fixture.
  /// - Returns: The history.
  /// - Throws: A failed requirement when the table does not hold the session.
  private static func history(of sessionId: SessionId, in fixture: ScriptedPromptFixture)
    async throws -> SessionMergeEngine
  {
    try #require(await fixture.harness.agent.sessions[sessionId]?.history)
  }

  /// The id of each agent message of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The ids.
  private static func agentMessageIds(of history: SessionMergeEngine) -> [MessageId] {
    history.entries.compactMap { entry in
      guard case .agentMessage(let message) = entry.kind else { return nil }
      return message.messageId
    }
  }

  /// The id of each user message of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The ids.
  private static func userMessageIds(of history: SessionMergeEngine) -> [MessageId] {
    history.entries.compactMap { entry in
      guard case .userMessage(let message) = entry.kind else { return nil }
      return message.messageId
    }
  }

  /// The text of each user message of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The texts.
  private static func userTexts(of history: SessionMergeEngine) -> [String] {
    history.entries.compactMap { entry in
      guard case .userMessage(let message) = entry.kind else { return nil }
      return message.content.compactMap { block in
        guard case .text(let text) = block else { return nil }
        return text.text
      }.joined()
    }
  }

  /// Forks the session of `fixture` at a cut, and gives the user texts of the fork.
  ///
  /// - Parameters:
  ///   - fixture: The fixture.
  ///   - messageId: The message at the cut.
  ///   - side: The side of the message where the cut is.
  /// - Returns: The text of each user message of the fork.
  /// - Throws: The error of the request.
  private static func forkUserTexts(
    of fixture: ScriptedPromptFixture, cutting messageId: MessageId, on side: SAH.ForkCut.Side
  ) async throws -> [String] {
    let meta = try SAH.ForkCut(messageId: messageId, side: side).inject(into: nil)
    let fork = try await fixture.harness.connection.forkSession(
      ForkSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId, meta: meta))
    return userTexts(of: try await history(of: fork.sessionId, in: fixture))
  }

  /// Two turns give two agent messages, each with its own id.
  @Test(.timeLimit(.minutes(1)), arguments: Model.allCases)
  func twoTurnsGiveTwoAgentMessages(on model: Model) async throws {
    let fixture = try await Self.twoTurns(on: model, "ids")

    let ids = Self.agentMessageIds(of: try await Self.history(of: fixture.sessionId, in: fixture))

    #expect(ids.count == Self.twoTurns && Set(ids).count == Self.twoTurns)
  }

  /// A cut before the user message of turn 2 forks turn 1 only.
  @Test(.timeLimit(.minutes(1)), arguments: Model.allCases)
  func aCutBeforeTurnTwoForksTurnOne(on model: Model) async throws {
    let fixture = try await Self.twoTurns(on: model, "before")
    let source = try await Self.history(of: fixture.sessionId, in: fixture)
    let secondUserMessage = try #require(Self.userMessageIds(of: source).last)

    let texts = try await Self.forkUserTexts(
      of: fixture, cutting: secondUserMessage, on: .before)

    #expect(texts == [Self.firstPrompt])
  }

  /// A cut after the agent message of turn 1 forks turn 1 only.
  @Test(.timeLimit(.minutes(1)), arguments: Model.allCases)
  func aCutAfterTheAnswerOfTurnOneForksTurnOne(on model: Model) async throws {
    let fixture = try await Self.twoTurns(on: model, "after")
    let source = try await Self.history(of: fixture.sessionId, in: fixture)
    let firstAgentMessage = try #require(Self.agentMessageIds(of: source).first)

    let texts = try await Self.forkUserTexts(
      of: fixture, cutting: firstAgentMessage, on: .after)

    #expect(texts == [Self.firstPrompt])
  }
}
