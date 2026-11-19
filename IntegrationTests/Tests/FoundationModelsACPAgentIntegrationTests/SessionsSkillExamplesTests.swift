import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing
import ULID

// MARK: - The examples of the sessions skill agree with the real stack
//
// The built-in `sessions` skill of Multitool (D200) shows the model the text that the stack
// writes: the receipt words of a send, the header of a message from another session, and the
// headers of a message from the user with a source session (D199 (f)). Each test runs the real
// in-process stack with the Router session directory, makes the stack write one of these texts,
// and compares it with the example of the skill.
//
// When a test fails, the skill text is wrong, not the stack: change the skill text in
// FoundationModelsMultitool. The failure message names the example.
//
// The line `Sent to claude-code-2 (v2w4abc): delivered` of the skill is not a line of this stack.
// The composer of TestudoApp writes it. The stack gives the same receipt word in the answer of
// `send message`, and the receipt test compares that word.

/// The longest time, in minutes, that one test of ``SessionsSkillExamplesTests`` can run.
private let sessionsSkillExamplesTimeLimitMinutes = 2

/// The examples of the `sessions` skill against the text that the real stack writes.
@Suite(.closesHarnesses, .timeLimit(.minutes(sessionsSkillExamplesTimeLimitMinutes)))
struct SessionsSkillExamplesTests {
  /// The prefix of the folders of each test.
  private static let label = "SessionsSkillExamplesTests"

  /// The count of characters of the instructions that a failure message shows.
  private static let instructionsExcerptLength = 400

  /// The label of the agent fact line.
  private static let agentLabel = "agent"

  /// The label of the agent-name fact line.
  private static let agentNameLabel = "agent name"

  /// The label of the title fact line.
  private static let titleLabel = "title"

  /// The label of the folder fact line.
  private static let folderLabel = "folder"

  /// The examples of the skill, read from the body that the preload renders.
  ///
  /// - Returns: The examples.
  /// - Throws: What the render of the skill throws.
  private static func examples() async throws -> SessionsSkillExamples {
    SessionsSkillExamples(body: try await SessionsSkillScenario.sessionsSkillBody())
  }

  /// Records an issue when no prompt holds the filled example.
  ///
  /// - Parameters:
  ///   - prompts: The prompts of the target that hold the text of the message.
  ///   - expected: The example, filled with the real facts.
  ///   - example: The example, for the failure message.
  ///   - sourceLocation: The place of the call, for the issue.
  private static func expect(
    _ prompts: [String], toHold expected: String, example: SessionsSkillExamples.Example,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      prompts.contains { $0.contains(expected) },
      """
      The sessions skill example \(example.name) does not agree with the text that the stack \
      wrote. Change the skill text in FoundationModelsMultitool.
      The example with the real facts:
      \(expected)
      The prompts of the target with the text of the message:
      \(prompts.joined(separator: "\n----\n"))
      """,
      sourceLocation: sourceLocation)
  }

  @Test("the instructions of the default session hold the body of the sessions skill")
  func theDefaultSessionInstructionsHoldTheSkillBody() async throws {
    let scenario = try await SessionsSkillScenario.make(label: "\(Self.label)-instructions")
    let body = try await SessionsSkillScenario.sessionsSkillBody()

    let instructions = try await scenario.instructions(of: scenario.first)
    await scenario.close()

    #expect(
      instructions.contains(body),
      "The instructions of the default session do not hold the body of the sessions skill: \(instructions.prefix(Self.instructionsExcerptLength))"
    )
  }

  @Test("each receipt word of the skill is a receipt outcome of the stack")
  func eachReceiptWordOfTheSkillIsAnOutcomeOfTheStack() async throws {
    let examples = try await Self.examples()

    let unknown = try examples.receiptWords().filter { SessionSendReceipt.Outcome(rawValue: $0) == nil }

    #expect(
      unknown.isEmpty,
      "The receipt words \(unknown) of the sessions skill are not receipt outcomes of the stack.")
  }

  @Test("the receipt of a send with the sessions tool to an idle session agrees with the skill")
  func theReceiptOfASendAgreesWithTheSkill() async throws {
    let examples = try await Self.examples()
    let receiptWords = try examples.receiptWords()
    let scenario = try await SessionsSkillScenario.make(label: "\(Self.label)-receipt")

    let receipts = try await scenario.sendWithTheSessionsTool(try examples.sessionMessageText())
    await scenario.close()

    let receipt = try #require(receipts.first, "The answer of send message has no receipt line.")
    let word = SessionsSkillScenario.receiptWord(of: receipt)
    #expect(
      receipts.count == 1,
      "The sessions skill says that the answer gives one line for each target: \(receipts)")
    #expect(
      receiptWords.contains(word),
      "The receipt word `\(word)` of `\(receipt)` is not in the receipt words of the sessions skill: \(receiptWords)"
    )
    #expect(
      word == SessionSendReceipt.Outcome.delivered.rawValue,
      "The sessions skill says `delivered` for an idle session. The stack wrote `\(receipt)`.")
  }

  @Test("the header of a message from a session agrees with the example of the skill")
  func theHeaderOfAMessageFromASessionAgreesWithTheSkill() async throws {
    let examples = try await Self.examples()
    let text = try examples.sessionMessageText()
    let scenario = try await SessionsSkillScenario.make(label: "\(Self.label)-session")

    _ = try await scenario.sendWithTheSessionsTool(text)
    let prompts = try await scenario.prompts(holding: text)
    let sender = try #require(
      try await scenario.directory.summary(of: SessionsSkillScenario.ulid(of: scenario.first)))
    await scenario.close()

    let facts = [
      Self.agentLabel: sender.agentID, Self.agentNameLabel: sender.agentName,
      Self.titleLabel: sender.title, Self.folderLabel: sender.workingDirectory.path,
    ].compactMapValues { $0 }
    let expected = try examples.filledSessionMessage(
      senderID: scenario.first.rawValue, facts: facts)
    Self.expect(prompts, toHold: expected, example: try examples.sessionMessage())
  }

  @Test("the header of a message from the user in a known session agrees with the skill")
  func theHeaderOfAUserMessageFromAKnownSessionAgreesWithTheSkill() async throws {
    let examples = try await Self.examples()
    let example = try examples.userMessageFromKnownSource()
    let text = try SessionsSkillExamples.userMessageText(of: example)
    let scenario = try await SessionsSkillScenario.make(label: "\(Self.label)-user")

    let source = try SessionsSkillScenario.ulid(of: scenario.first)
    try await scenario.sendAsTheUser(text, from: source)
    let prompts = try await scenario.prompts(holding: text)
    let summary = try #require(try await scenario.directory.summary(of: source))
    await scenario.close()

    let title = try #require(summary.title, "The source session has no title.")
    let expected = try examples.filledUserMessageFromKnownSource(
      title: title, folder: summary.workingDirectory.path)
    Self.expect(prompts, toHold: expected, example: example)
  }

  @Test("the header of a message from the user in an unknown session agrees with the skill")
  func theHeaderOfAUserMessageFromAnUnknownSessionAgreesWithTheSkill() async throws {
    let examples = try await Self.examples()
    let example = try examples.userMessageFromUnknownSource()
    let text = try SessionsSkillExamples.userMessageText(of: example)
    let scenario = try await SessionsSkillScenario.make(label: "\(Self.label)-unknown")

    let source = ULID()
    try await scenario.sendAsTheUser(text, from: source)
    let prompts = try await scenario.prompts(holding: text)
    await scenario.close()

    let expected = try examples.filledUserMessageFromUnknownSource(sourceID: source.ulidString)
    Self.expect(prompts, toHold: expected, example: example)
  }
}
