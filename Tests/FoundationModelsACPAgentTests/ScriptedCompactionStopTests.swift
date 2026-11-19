import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A scripted pass that the real Router stops at a tool result to compact
/// (task ^ptasrrj).
///
/// The stub loader of the `acp-agent-stub` binary puts the tool layers of
/// Router on the scripted tools. A small compaction trigger thus makes the
/// first tool result stop the model call, and the answer continues on a new
/// backend. The old backend must then play no more steps, so the second
/// tool call of the pass plays one time, with its own output.
@Suite struct ScriptedCompactionStopTests {
  /// A tool that counts its calls and gives back the label of its
  /// arguments.
  struct LabelTool: Tool {
    let name = ScriptedCompactionStopTests.toolName
    let description = "Give back a label."

    /// The number of calls with the label ``ScriptedCompactionStopTests/secondLabel``.
    let secondCalls: CallCounter

    func call(arguments: LabelArguments) async throws -> String {
      if arguments.label == ScriptedCompactionStopTests.secondLabel {
        secondCalls.record()
      }
      return arguments.label
    }
  }

  /// The name of the ``LabelTool``.
  private static let toolName = "label"

  /// The prompt that chooses the session of the script.
  private static let prompt = "go now"

  /// The label of the first tool call of the pass.
  private static let firstLabel = "first"

  /// The label of the second tool call of the pass.
  private static let secondLabel = "second"

  /// The text at the end of the pass.
  private static let finalText = "done"

  /// A compaction trigger that the first tool result crosses: the stub
  /// counts one token for each character, and the instructions alone are
  /// more than this part of the context.
  private static let smallTrigger = 0.01

  /// The compaction target below ``smallTrigger``.
  private static let smallTarget = 0.005

  /// The step of one ``LabelTool`` call.
  ///
  /// - Parameter label: The label of the call.
  /// - Returns: The step.
  private static func labelCall(_ label: String) -> ScriptedPassStep {
    .toolCall(name: toolName, argumentsJSON: #"{"label":"\#(label)"}"#)
  }

  /// The script: one session of one pass of two tool calls and a text.
  private static let script = ScriptedStubScript(sessions: [
    .init(
      promptContains: prompt,
      passes: [[labelCall(firstLabel), labelCall(secondLabel), .textDelta(finalText)]])
  ])

  /// The text of each `.toolOutput` entry of `transcript`, by the id of
  /// its call.
  ///
  /// - Parameter transcript: The transcript of the session.
  /// - Returns: The output text of each call id.
  private static func outputs(in transcript: Transcript) -> [String: String] {
    var texts: [String: String] = [:]
    for entry in transcript {
      guard case .toolOutput(let output) = entry else { continue }
      texts[output.id] = output.segments.map(segmentText).joined()
    }
    return texts
  }

  /// The text of one segment.
  ///
  /// - Parameter segment: The segment.
  /// - Returns: The text, or the JSON of a structured segment.
  private static func segmentText(_ segment: Transcript.Segment) -> String {
    switch segment {
    case .text(let text): text.content
    case .structure(let structure): structure.content.jsonString
    @unknown default: ""
    }
  }

  /// Plays the script in a budgeted session over the stub loader, with a
  /// compaction trigger that the first tool result crosses.
  ///
  /// - Parameter secondCalls: The counter of the second tool call.
  /// - Returns: The transcript of the session after the answer.
  /// - Throws: What the profile, the session or the answer throws.
  private static func playWithACompactionStop(secondCalls: CallCounter) async throws -> Transcript
  {
    let directory = makeResolvedDirectory(label: "ScriptedCompactionStopTests")
    let loader = StubModelLoader { _ in
      HookLayeredLLMContainer(wrapping: ScriptedLLMContainer(playbook: .sessions(script)))
    }
    let profile = try await makeStubProfile(
      cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true), loader: loader)
    var compaction = CompactionConfiguration()
    compaction.trigger = smallTrigger
    compaction.target = smallTarget
    let session = profile.standard.makeBudgetedSession(
      instructions: String(repeating: "Do the task. ", count: 100),
      workingDirectory: directory,
      recordingRoot: directory.appendingPathComponent("recordings", isDirectory: true),
      tools: [LabelTool(secondCalls: secondCalls)],
      compaction: compaction,
      repetition: RepetitionConfiguration(),
      inlineSettleGrace: CatalogContext.defaultInlineSettleGrace,
      transcriptReader: nil)
    _ = try await session.respond(to: prompt)
    return await session.transcript
  }

  @Test func theSecondCallOfAPassThatACompactionStoppedPlaysOneTime() async throws {
    let secondCalls = CallCounter()
    _ = try await Self.playWithACompactionStop(secondCalls: secondCalls)
    #expect(secondCalls.count == 1)
  }

  @Test func theSecondCallOfAPassThatACompactionStoppedGetsItsOwnOutput() async throws {
    let transcript = try await Self.playWithACompactionStop(secondCalls: CallCounter())
    let secondId = ScriptedSessionBackend.scriptedCallIdPrefix + "2"
    #expect(Self.outputs(in: transcript)[secondId]?.contains(Self.secondLabel) == true)
  }
}
