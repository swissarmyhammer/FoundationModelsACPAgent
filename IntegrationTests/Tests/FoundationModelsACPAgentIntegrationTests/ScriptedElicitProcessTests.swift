import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - Tier 3: the `elicit` step of the scripted stub model across a process boundary
//
// The root session of a spawned `acp-agent-stub acp` asks the user a question with
// the `elicit` step of the script. The test is the client: it reads the
// question over the wire, answers it, and reads the end of the prompt. Only a
// spawned binary proves that the question of the stub path is a real question
// of the session on the real wire.

/// The `elicit` step of a spawned `acp-agent-stub acp` over `ACP_AGENT_STUB_SCRIPT`.
@Suite(.timeLimit(.minutes(2)))
struct ScriptedElicitProcessTests {
  // MARK: - Constants

  /// The prompt of the client, and the marker of the root session.
  private static let rootPrompt = "ROOT-ASKS-THE-USER"

  /// The message of the question.
  private static let question = "Which colour do you want?"

  /// The name of the one field of the question.
  private static let answerField = "answer"

  /// The answer of the user.
  private static let answer = "blue"

  /// The text that the root session plays after the question.
  private static let afterText = "ROOT-TEXT-AFTER-THE-QUESTION"

  /// The exit code of a run that stopped with an error (cli-plan.md §5.8).
  private static let errorExitCode: Int32 = 1

  /// How the client ends the question.
  private enum Resolution {
    /// The user types `answer` and accepts.
    case accept(String)

    /// The user declines.
    case decline
  }

  /// What the client read of one prompt.
  private struct Outcome {
    /// The question as the agent sent it.
    let request: CreateElicitationRequest

    /// The text of the agent message chunks, in order.
    let text: String

    /// The answering fields of each tool call update, as JSON text.
    let toolOutput: String

    /// The stop reason of the prompt.
    let stopReason: StopReason?
  }

  // MARK: - Fixtures

  /// The script: the root asks, and then plays its text.
  private static var script: String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(rootPrompt)"},
       "passes":[[{"elicit":"\(question)"},{"text":"\(afterText)"}]]}
    ]}
    """
  }

  /// Spawns `acp-agent-stub acp` over `script`, asks the one prompt,
  /// resolves the question, and reads the end of the prompt.
  ///
  /// - Parameters:
  ///   - resolution: How the client ends the question.
  ///   - label: The directory label.
  /// - Returns: What the client read.
  /// - Throws: The spawn, request or wait error.
  private static func run(resolving resolution: Resolution, label: String) async throws -> Outcome {
    let file = try TierThreeFixture.writeStubScript(script, label: label)
    let drive = try await SpawnedAgentPromptDrive.run(
      label: label,
      environment: try TierThreeFixture.makeOfflineDefaultsEnvironment()
        .merging([TierThreeFixture.stubScriptVariable: file.path]) { _, script in script },
      promptText: rootPrompt,
      answeringQuestionWith: { session in
        let pending = await PendingQuestionWait.first(in: session)
        await MainActor.run {
          switch resolution {
          case .accept(let text):
            session.acceptElicitation(
              pending.id, content: .object([answerField: .string(text)]))
          case .decline:
            session.declineElicitation(pending.id)
          }
        }
        return pending.request
      },
      ending: { agent in try await agent.closeStandardInputAndWait() })
    return Outcome(
      request: try #require(drive.question), text: drive.read.text,
      toolOutput: drive.read.toolOutput, stopReason: drive.stopReason)
  }

  // MARK: - The contract

  /// The root asks a form question with one required `answer` field and the
  /// message of the step.
  @Test
  func theQuestionIsAFormWithTheMessageAndOneRequiredAnswerField() async throws {
    let outcome = try await Self.run(
      resolving: .accept(Self.answer), label: "ScriptedElicitProcessTests-form")

    guard case .form(let form) = outcome.request.mode else {
      Issue.record("expected a form request, got \(outcome.request.mode)")
      return
    }
    #expect(outcome.request.message == Self.question)
    #expect(form.requestedSchema.required == [Self.answerField])
  }

  /// The answer of the client is the output of the call, and the root goes
  /// on with its next step.
  @Test
  func theAnswerIsTheToolOutputAndTheRootGoesOn() async throws {
    let outcome = try await Self.run(
      resolving: .accept(Self.answer), label: "ScriptedElicitProcessTests-answer")

    #expect(outcome.toolOutput.contains(Self.answer), "tool output: \(outcome.toolOutput)")
    // The answer is also mail to the session, and the mail starts one more
    // pass. The script has no pass for it, so that pass echoes the mail.
    #expect(outcome.text.hasPrefix(Self.afterText), "text: \(outcome.text)")
    #expect(outcome.stopReason == .endTurn)
  }

  /// A decline of the client ends the pass with a clear text, and the step
  /// after the question does not play.
  @Test
  func aDeclineEndsThePassWithAClearText() async throws {
    let outcome = try await Self.run(
      resolving: .decline, label: "ScriptedElicitProcessTests-decline")

    #expect(outcome.text.contains("declined"), "text: \(outcome.text)")
    #expect(!outcome.text.contains(Self.afterText))
    #expect(outcome.stopReason == .endTurn)
  }

  /// An `elicit` step whose value is not a string stops the stub path with
  /// an error that names the step, and the run does not echo.
  @Test
  func anElicitStepThatIsNotAStringStopsTheRunWithAnError() async throws {
    let workspace = makeResolvedDirectory(label: "ScriptedElicitProcessTests-bad-repo")
    let file = try TierThreeFixture.writeStubScript(
      #"{"sessions":[{"match":{"promptContains":"x"},"passes":[[{"elicit":5}]]}]}"#,
      label: "ScriptedElicitProcessTests-bad")
    let run = try await BuiltExecutableRun.run(
      executableNamed: TierThreeFixture.stubAgentExecutableName,
      arguments: ["run", "--verbose", Self.rootPrompt],
      workspace: workspace,
      configHome: makeResolvedDirectory(label: "ScriptedElicitProcessTests-bad-config"),
      environment: try TierThreeFixture.makeOfflineDefaultsEnvironment()
        .merging([TierThreeFixture.stubScriptVariable: file.path]) { _, script in script })

    #expect(run.exitCode == Self.errorExitCode, "stderr: \(run.standardError)")
    #expect(run.standardError.contains("elicit"), "stderr: \(run.standardError)")
    #expect(!run.standardOutput.contains(Self.rootPrompt), "stdout: \(run.standardOutput)")
  }
}
