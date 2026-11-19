import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The stop of a scripted pass whose task is cancelled between two steps
/// (task ^ptasrrj).
///
/// Router stops a model call at a tool result: the tool layer cancels the
/// task of the model call while the tool body runs, and the answer then
/// continues on a new backend. The old backend must not play the next step.
/// If it does, the next tool call plays two times: one time on the old
/// backend, and one time on the new backend.
@Suite struct ScriptedPassCancellationTests {
  /// A tool that cancels the task that calls it, as the tool layer of
  /// Router does at a compaction stop.
  struct CancellingTool: Tool {
    let name = ScriptedPassCancellationTests.cancellingToolName
    let description = "Cancel the task of the call."

    func call(arguments: LabelArguments) async throws -> String {
      withUnsafeCurrentTask { $0?.cancel() }
      return arguments.label
    }
  }

  /// A tool that counts its calls.
  struct CountingTool: Tool {
    let name = ScriptedPassCancellationTests.countingToolName
    let description = "Count the calls."

    /// The number of calls, shared with the test.
    let calls: CallCounter

    func call(arguments: LabelArguments) async throws -> String {
      calls.record()
      return arguments.label
    }
  }

  /// The name of the ``CancellingTool``.
  private static let cancellingToolName = "cancel"

  /// The name of the ``CountingTool``.
  private static let countingToolName = "count"

  /// The arguments of each tool call, as JSON.
  private static let arguments = #"{"label":"x"}"#

  /// The steps of the pass: the call that cancels, then the call that counts.
  private static let steps: [ScriptedPassStep] = [
    .toolCall(name: cancellingToolName, argumentsJSON: arguments),
    .toolCall(name: countingToolName, argumentsJSON: arguments),
  ]

  @Test func aPassCancelledInTheBodyOfItsFirstCallDoesNotInvokeItsSecondCall() async throws {
    let calls = CallCounter()
    let backend = ScriptedSessionBackend(
      playbook: .everyPass(Self.steps),
      tools: [CancellingTool(), CountingTool(calls: calls)])
    let pass = Task { try await backend.respond(to: "go", maxTokens: nil) }
    _ = await pass.result
    #expect(calls.count == 0)
  }

  @Test func aPassCancelledInTheBodyOfACallAppendsNoOutputOfThatCall() async throws {
    let backend = ScriptedSessionBackend(
      playbook: .everyPass([Self.steps[0]]), tools: [CancellingTool()])
    let pass = Task { try await backend.respond(to: "go", maxTokens: nil) }
    _ = await pass.result
    let outputs = backend.transcriptEntries().filter { entry in
      if case .toolOutput = entry { return true }
      return false
    }
    #expect(outputs.isEmpty)
  }
}
