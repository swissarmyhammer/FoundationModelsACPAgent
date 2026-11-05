import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - A child that does not answer fails the test at once, and says why
//
// On 2026-11-05 a CI run held the runner for 5 h 14 min, and the time limit of
// the suite never fired. Swift Testing cannot end a test that waits in an await
// that ignores cancel, and a blocking read of a pipe holds a thread of the
// cooperative pool. So the support code acts on the CHILD: at its limit it
// kills the child, the pipes of the child end, each wait of the test ends, and
// the failure holds the stderr of the child. These cases prove that, with
// children that do nothing for ten minutes if no one ends them.

/// The limit of a spawned child, and the end of a run that is cancelled.
struct ChildDeadlineTests {
  // MARK: - Constants

  /// The absolute path of `sh(1)`.
  private static let shellPath = "/bin/sh"

  /// A short limit. The children below outlive it by far.
  private static let shortLimit = Duration.seconds(2)

  /// A limit that no case reaches: the case ends the run by a cancel.
  private static let unreachedLimit = Duration.seconds(300)

  /// The text that the silent child writes to its stderr before it waits.
  private static let lastWords = "the-last-words-of-the-child"

  /// A script that writes ``lastWords`` to stderr, and then waits for ten
  /// minutes.
  private static var silentChildScript: String {
    "printf '\(lastWords)' >&2; exec sleep 600"
  }

  /// The marker of the prompt of the scripted stub model.
  private static let promptMarker = "HOLD-THE-PROMPT"

  /// The prefix of the labels of the folders of each case.
  private static let label = "ChildDeadlineTests"

  /// The script of a prompt that plays one text and then holds at a gate
  /// that no one opens.
  private static func holdingScript(gate: URL) -> String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(promptMarker)"},
       "passes":[[{"text":"first"},{"gate":"\(gate.path)"}]]}
    ]}
    """
  }

  /// The script of a prompt that plays one text and ends, with no question.
  private static let plainScript = """
    {"sessions":[
      {"match":{"promptContains":"\(promptMarker)"},"passes":[[{"text":"plain"}]]}
    ]}
    """

  /// Drives one prompt over the scripted stub model, with the limit of the
  /// cases, and a hook that waits for a question.
  ///
  /// - Parameter script: The JSON text of the script.
  /// - Throws: What the drive throws.
  private static func driveWaitingForAQuestion(script: String, label: String) async throws {
    let file = try TierThreeFixture.writeStubScript(script, label: label)
    _ = try await SpawnedAgentPromptDrive.run(
      label: label,
      environment: try TierThreeFixture.stubScriptEnvironment(file: file),
      promptText: promptMarker,
      limit: shortLimit,
      answeringQuestionWith: { session in
        try await PendingQuestionWait.first(in: session).request
      },
      ending: { agent in try await agent.closeStandardInputAndWait() })
  }

  // MARK: - A run of a captured child

  /// A child that outlives the limit is killed, and the failure holds what it
  /// wrote to stderr and the signal that ended it.
  @Test func aChildThatOutlivesTheLimitIsKilledAndTheFailureHoldsItsStandardError() async throws {
    let failure = await #expect(throws: ChildDeadlineExceeded.self) {
      try await CapturedProcessRun.run(
        toolAt: Self.shellPath, arguments: ["-c", Self.silentChildScript],
        errorOutput: .captured, limit: Self.shortLimit)
    }

    #expect(failure?.standardError == Self.lastWords)
    #expect(failure?.terminationStatus == SIGKILL)
    #expect(failure?.limit == Self.shortLimit)
  }

  /// A run that the test cancels ends at once with the cancel error, and does
  /// not wait for the pipes of a child that sleeps.
  @Test func aCancelledRunEndsAtOnceWithTheCancelError() async throws {
    let run = Task {
      try await CapturedProcessRun.run(
        toolAt: Self.shellPath, arguments: ["-c", Self.silentChildScript],
        errorOutput: .captured, limit: Self.unreachedLimit)
    }
    run.cancel()

    await #expect(throws: ConditionWaitCancelled.self) {
      _ = try await run.value
    }
  }

  // MARK: - A spawned agent

  /// A prompt that never ends fails at the limit with the deadline failure,
  /// and not with the closed connection that the kill causes.
  @Test func aPromptThatNeverEndsFailsAtTheLimitWithTheDeadlineFailure() async throws {
    let label = "\(Self.label)-hold"
    let gate = NestedAgentFixture.gateFile(label: label)

    let failure = await #expect(throws: ChildDeadlineExceeded.self) {
      try await Self.driveWaitingForAQuestion(
        script: Self.holdingScript(gate: gate), label: label)
    }

    #expect(failure?.limit == Self.shortLimit)
  }

  /// A hook that waits for a question fails at once when the turn ends with
  /// no question, and does not wait for the limit. The failure holds the
  /// stderr of the agent.
  @Test func aTurnThatEndsWithNoQuestionFailsTheHookAtOnce() async throws {
    let failure = await #expect(throws: SpawnedAgentFailure.self) {
      try await Self.driveWaitingForAQuestion(
        script: Self.plainScript, label: "\(Self.label)-plain")
    }

    #expect(failure?.underlying is PromptEndedWithoutQuestion)
  }
}
