import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The `elicit` step of the scripted stub model: the pass asks the user one
/// form question, waits for the answer, and goes on with the answer text as
/// the output of the call. A decline or a cancel ends the pass with a clear
/// text. The question is a real question of the session: it goes over the
/// wire with the same path that a tool uses.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ScriptedElicitStepTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ScriptedElicitStepTests"

  /// The marker of the prompt whose pass asks.
  private static let askMarker = "Ask the colour"

  /// The message of the question.
  private static let question = "Which colour do you want?"

  /// The name of the one field of the question.
  private static let answerField = "answer"

  /// The answer that the user gives.
  private static let answer = "blue"

  /// The text that the pass plays after the question.
  private static let afterText = "TEXT-AFTER-THE-QUESTION"

  /// How the client ends the question.
  private enum Resolution {
    /// The user types `answer` and accepts.
    case accept(String)

    /// The user declines.
    case decline

    /// The user cancels.
    case cancel
  }

  /// What one run of the asking pass gave.
  private struct Run {
    /// The fixture. The caller closes it.
    let fixture: ScriptedPromptFixture

    /// The question, as the client read it.
    let pending: PendingElicitation

    /// The notifications of the session, to the idle of the prompt.
    let updates: [UpdateSessionNotification]
  }

  /// The steps of the asking pass, with the text after the question.
  private static func askingScript() -> [ScriptedPassStep] {
    [
      .onPrompt(
        containing: askMarker,
        play: [.elicit(message: question), .textDelta(afterText), .endPass]),
      .endPass,
    ]
  }

  /// Runs the asking pass: the prompt goes out, the client reads the
  /// question, resolves it, and the wait ends at the idle of the prompt.
  ///
  /// - Parameter resolution: How the client ends the question.
  /// - Returns: The run.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func run(resolving resolution: Resolution) async throws -> Run {
    let fixture = try await ScriptedPromptFixture.make(script: askingScript(), label: label)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: askMarker))
    let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
    let session = fixture.session
    await MainActor.run {
      switch resolution {
      case .accept(let text):
        session.acceptElicitation(pending.id, content: .object([answerField: .string(text)]))
      case .decline:
        session.declineElicitation(pending.id)
      case .cancel:
        session.cancelElicitation(pending.id)
      }
    }
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    return Run(fixture: fixture, pending: pending, updates: updates)
  }

  /// The JSON text of the answer of every tool call update: the
  /// `rawOutput` and the `content`, and never the `rawInput`.
  private static func toolOutputText(in updates: [UpdateSessionNotification]) throws -> String {
    try updates.compactMap { notification -> String? in
      guard case .toolCallUpdate(let update) = notification.update else { return nil }
      return try [encodedText(of: update.rawOutput), encodedText(of: update.content)].joined()
    }.joined()
  }

  /// The JSON text of the value of a patch field, or empty when it has none.
  private static func encodedText<Value: Encodable>(of field: PatchField<Value>) throws -> String {
    guard case .value(let value) = field else { return "" }
    return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  // MARK: - The question

  /// The question is a form with one required field named `answer`.
  @Test func theQuestionIsAFormWithOneRequiredAnswerField() async throws {
    let run = try await Self.run(resolving: .accept(Self.answer))

    guard case .form(let form) = run.pending.request.mode else {
      Issue.record("expected a form request, got \(run.pending.request.mode)")
      await run.fixture.close()
      return
    }
    guard case .object(let properties) = form.requestedSchema.properties else {
      Issue.record("expected object properties, got \(form.requestedSchema.properties)")
      await run.fixture.close()
      return
    }
    #expect(form.requestedSchema.required == [Self.answerField])
    #expect(Array(properties.keys) == [Self.answerField])
    await run.fixture.close()
  }

  /// The question carries the message of the step.
  @Test func theQuestionCarriesTheMessageOfTheStep() async throws {
    let run = try await Self.run(resolving: .accept(Self.answer))

    #expect(run.pending.request.message == Self.question)
    await run.fixture.close()
  }

  // MARK: - The answer

  /// The answer text is the output of the call that asked.
  @Test func theAnswerTextIsTheOutputOfTheCall() async throws {
    let run = try await Self.run(resolving: .accept(Self.answer))

    #expect(try Self.toolOutputText(in: run.updates).contains(Self.answer))
    await run.fixture.close()
  }

  /// The pass goes on with its next step after an answer.
  @Test func thePassGoesOnAfterAnAnswer() async throws {
    let run = try await Self.run(resolving: .accept(Self.answer))

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == Self.afterText)
    await run.fixture.close()
  }

  // MARK: - No answer

  /// A decline ends the pass with the text of the decline, and the steps
  /// after the question do not play.
  @Test func aDeclineEndsThePassWithAClearText() async throws {
    let run = try await Self.run(resolving: .decline)

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == ScriptedElicitation.declinedText)
    await run.fixture.close()
  }

  /// A cancel ends the pass with the text of the cancel, and the steps
  /// after the question do not play.
  @Test func aCancelEndsThePassWithAClearText() async throws {
    let run = try await Self.run(resolving: .cancel)

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == ScriptedElicitation.cancelledText)
    await run.fixture.close()
  }

  /// A session whose client answers no question has no `elicit` in its
  /// sandbox. The step then ends the pass with a clear text, and no
  /// question goes to the client.
  @Test func aSessionWithNoUserEndsThePassWithAClearText() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: Self.askingScript(), label: Self.label, capabilities: ClientCapabilities())
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.askMarker))
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)

    #expect(ScriptedPromptFixture.agentText(in: updates) == ScriptedElicitation.unavailableText)
    await fixture.close()
  }

  // MARK: - A child session

  /// The number of `elicitation/create` requests that a question of a
  /// child makes: one under the child session. The copy under the session
  /// of its parent is not sent (``ChildElicitationTests``).
  private static let createsOfAChildQuestion = 1

  /// The agent that the root session starts.
  private static let childAgent = "asker"

  /// The marker of the prompt of the root session in the child suite.
  private static let rootMarker = "ROOT-ASKS-THROUGH-A-CHILD"

  /// The marker of the prompt of the child.
  private static let childMarker = "CHILD-ASKS-THE-USER"

  /// The question of a child pass, which comes under the id of the child
  /// session: the same step, the same path, and no case for a child.
  @Test func aChildThatAsksMakesTheQuestionUnderItsOwnSession() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-repo")
    try AgentsToolTests.writeAgent(named: Self.childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: Self.childMarker,
        play: [.elicit(message: Self.question), .endPass]),
      .onPrompt(
        containing: Self.rootMarker,
        play: [
          AgentsToolTests.startAgentCall(agent: Self.childAgent, prompt: Self.childMarker),
          .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: Self.label, workingDirectory: cwd)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.rootMarker))
    let recorder = try #require(fixture.harness.elicitations)
    let creates = try await recorder.waitForCreates(count: Self.createsOfAChildQuestion)
    let updates = try await fixture.collector.wait(for: "the announcement of the child") {
      updates in
      updates.contains { notification in
        if case .subagentUpdate = notification.update { return true }
        return false
      }
    }
    let child = updates.compactMap { notification -> SessionId? in
      if case .subagentUpdate(let update) = notification.update { return update.sessionId }
      return nil
    }.first
    let askingSessions = creates.compactMap { request -> SessionId? in
      guard case .form(let form) = request.mode, case .session(let scope) = form.scope else {
        return nil
      }
      return scope.sessionId
    }

    #expect(askingSessions.contains { $0 == child })
    let session = fixture.session
    try await ObservedValue.wait(for: "the child holds the question") {
      session.children.first?.pendingElicitations.isEmpty == false
    }
    let childModel = try #require(await session.children.first)
    let pending = try await ElicitationWait.firstPendingElicitation(in: childModel)
    await MainActor.run { childModel.cancelElicitation(pending.id) }
    await fixture.close()
  }
}
