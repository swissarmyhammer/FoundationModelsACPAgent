import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsACPAgent

/// The continuation of a scripted session on a new backend (task ^dxtwmw0).
///
/// Router stops a model call at a tool result to compact. It then puts the
/// transcript of the stopped attempt into a new backend
/// (``ScriptedSessionBackend/replacingTranscript(_:)``) and continues the
/// same answer with a continuation prompt. The new backend must continue the
/// open pass after the steps that already played, and must not play the
/// pass again from its first step. Each call id must stay different.
@Suite struct ScriptedPassContinuationTests {
  /// The arguments of the ``NoteTool``.
  @Generable
  struct NoteArguments {
    /// The label that the tool gives back.
    var label: String
  }

  /// A tool that gives back the label of its arguments.
  struct NoteTool: Tool {
    let name = ScriptedPassContinuationTests.toolName
    let description = "Note a label."

    func call(arguments: NoteArguments) async throws -> String {
      arguments.label
    }
  }

  /// The name of the ``NoteTool``.
  private static let toolName = "note"

  /// The prompt that chooses the session of ``script``.
  private static let firstPrompt = "go now"

  /// The prompt of the attempt that Router sends after a compaction stop.
  private static let continuationPrompt =
    "The context was compacted. Your last tool result is above. Continue the task."

  /// The label of the first tool call of the first pass.
  private static let firstLabel = "first"

  /// The label of the second tool call of the first pass.
  private static let secondLabel = "second"

  /// The label of the tool call of the second pass.
  private static let nextPassLabel = "next pass"

  /// The text before the first tool call of the first pass.
  private static let textBefore = "before "

  /// The text between the two tool calls of the first pass.
  private static let textBetween = "between "

  /// The text after the second tool call of the first pass.
  private static let textAfter = "after"

  /// The arguments of a ``NoteTool`` call, as JSON.
  ///
  /// - Parameter label: The label of the call.
  /// - Returns: The JSON.
  private static func noteArguments(_ label: String) -> String {
    #"{"label":"\#(label)"}"#
  }

  /// A script of one session of two passes. The first pass has a text
  /// step, a tool call, a text step, a second tool call and a text step.
  /// The second pass has one tool call.
  private static let script = ScriptedStubScript(sessions: [
    .init(
      promptContains: firstPrompt,
      passes: [
        [
          .textDelta(textBefore),
          .toolCall(name: toolName, argumentsJSON: noteArguments(firstLabel)),
          .textDelta(textBetween),
          .toolCall(name: toolName, argumentsJSON: noteArguments(secondLabel)),
          .textDelta(textAfter),
        ],
        [.toolCall(name: toolName, argumentsJSON: noteArguments(nextPassLabel))],
      ])
  ])

  /// A script of one session of one pass. The second tool call is in a
  /// branch that only ``firstPrompt`` matches, and the continuation prompt
  /// does not match.
  private static let branchScript = ScriptedStubScript(sessions: [
    .init(
      promptContains: firstPrompt,
      passes: [
        [
          .toolCall(name: toolName, argumentsJSON: noteArguments(firstLabel)),
          .onPrompt(
            containing: firstPrompt,
            play: [.toolCall(name: toolName, argumentsJSON: noteArguments(secondLabel))]),
        ]
      ])
  ])

  // MARK: - The entries of a stopped attempt

  /// The id of the scripted call `ordinal`.
  ///
  /// - Parameter ordinal: The one-based ordinal of the call.
  /// - Returns: The id.
  private static func callId(_ ordinal: Int) -> String {
    ScriptedSessionBackend.scriptedCallIdPrefix + String(ordinal)
  }

  /// The leading `.instructions` entry of a session with the ``NoteTool``.
  private static var instructionsEntry: Transcript.Entry {
    .instructions(
      Transcript.Instructions(
        segments: [], toolDefinitions: [Transcript.ToolDefinition(tool: NoteTool())]))
  }

  /// A `.prompt` entry of `text`.
  ///
  /// - Parameter text: The prompt text.
  /// - Returns: The entry.
  private static func promptEntry(_ text: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
  }

  /// The `.toolCalls` and `.toolOutput` entries of one ``NoteTool`` call
  /// that played.
  ///
  /// - Parameters:
  ///   - ordinal: The one-based ordinal of the call.
  ///   - label: The label of the call.
  /// - Returns: The two entries.
  private static func playedCall(_ ordinal: Int, label: String) throws -> [Transcript.Entry] {
    let id = callId(ordinal)
    let arguments = try GeneratedContent(json: noteArguments(label))
    return [
      .toolCalls(
        Transcript.ToolCalls([Transcript.ToolCall(id: id, toolName: toolName, arguments: arguments)])
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: id, toolName: toolName,
          segments: [.text(Transcript.TextSegment(content: label))])),
    ]
  }

  /// A `.response` entry of a pass that ended with `text`.
  ///
  /// - Parameter text: The answer of the pass.
  /// - Returns: The entry.
  private static func responseEntry(_ text: String) -> Transcript.Entry {
    .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))]))
  }

  /// The transcript of the first pass that Router stopped after its first
  /// tool call, as Router rebuilds it.
  private static func stoppedAfterFirstCall() throws -> [Transcript.Entry] {
    try [instructionsEntry, promptEntry(firstPrompt)] + playedCall(1, label: firstLabel)
  }

  /// The transcript of the first pass that ended after its two tool calls.
  private static func endedFirstPass() throws -> [Transcript.Entry] {
    try [instructionsEntry, promptEntry(firstPrompt)]
      + playedCall(1, label: firstLabel)
      + playedCall(2, label: secondLabel)
      + [responseEntry(textBefore + textBetween + textAfter)]
  }

  // MARK: - The continuation

  /// The new backend over `seeded` and the playbook of `script`, after it
  /// answered the continuation prompt.
  ///
  /// - Parameters:
  ///   - seeded: The transcript the new backend starts from.
  ///   - script: The script of the session.
  /// - Returns: The answer, and the tool calls that the answer played.
  private static func continuation(
    from seeded: [Transcript.Entry], script: ScriptedStubScript = script
  ) async throws -> (answer: String, calls: [Transcript.ToolCall]) {
    let stopped = ScriptedSessionBackend(
      playbook: .sessions(script), tools: [NoteTool()], seededEntries: [instructionsEntry])
    let continued = stopped.replacingTranscript(Transcript(entries: seeded))
    let answer = try await continued.respond(to: continuationPrompt, maxTokens: nil)
    let calls = continued.transcriptEntries().dropFirst(seeded.count).flatMap {
      entry -> [Transcript.ToolCall] in
      guard case .toolCalls(let calls) = entry else { return [] }
      return Array(calls)
    }
    return (answer, calls)
  }

  /// The labels of `calls`.
  ///
  /// - Parameter calls: The tool calls.
  /// - Returns: The label of each call, in order.
  private static func labels(of calls: [Transcript.ToolCall]) throws -> [String] {
    try calls.map { try $0.arguments.value(String.self, forProperty: "label") }
  }

  @Test func aStopAfterTheFirstCallPlaysTheSecondCallNext() async throws {
    let continued = try await Self.continuation(from: Self.stoppedAfterFirstCall())
    #expect(try Self.labels(of: continued.calls) == [Self.secondLabel])
  }

  @Test func aStopAfterTheFirstCallGivesTheNextCallTheSecondId() async throws {
    let continued = try await Self.continuation(from: Self.stoppedAfterFirstCall())
    #expect(continued.calls.map(\.id) == [Self.callId(2)])
  }

  @Test func aStopAfterTheFirstCallDoesNotPlayTheTextBeforeItAgain() async throws {
    let continued = try await Self.continuation(from: Self.stoppedAfterFirstCall())
    #expect(continued.answer == Self.textBetween + Self.textAfter)
  }

  @Test func aSecondStopContinuesAfterTheCallOfTheFirstContinuation() async throws {
    let seeded =
      try Self.stoppedAfterFirstCall() + [Self.promptEntry(Self.continuationPrompt)]
      + Self.playedCall(2, label: Self.secondLabel)
    let continued = try await Self.continuation(from: seeded)
    #expect(continued.answer == Self.textAfter)
  }

  @Test func aBranchAfterTheStopPlaysWhenThePromptOfThePassMatchesIt() async throws {
    let continued = try await Self.continuation(
      from: Self.stoppedAfterFirstCall(), script: Self.branchScript)
    #expect(try Self.labels(of: continued.calls) == [Self.secondLabel])
  }

  @Test func aContinuationAfterAPassThatEndedPlaysTheNextPass() async throws {
    let continued = try await Self.continuation(from: Self.endedFirstPass())
    #expect(try Self.labels(of: continued.calls) == [Self.nextPassLabel])
  }

  @Test func aContinuationAfterAPassThatEndedGivesTheNextCallTheNextId() async throws {
    let continued = try await Self.continuation(from: Self.endedFirstPass())
    #expect(continued.calls.map(\.id) == [Self.callId(3)])
  }
}
