import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

@testable import FoundationModelsACPAgent

/// A session whose mail delivery Router paused (task ^t03jd5h), and the
/// readers of the `_mail_delivery_paused` updates.
///
/// The fixture sets the limit to `0`, so the first run mail is held at once.
/// The prompt starts a shell read of a named pipe, which goes to the
/// background at once. The fixture writes the pipe only after the prompt
/// ended, so the run mail comes when no answer runs.
enum MailDeliveryPauseFixture {
  // MARK: - Constants

  /// The marker of the prompt that starts the background run.
  static let startRunMarker = "Start the background run"

  /// The text of the second prompt, which carries the held mail.
  static let secondPromptText = "Carry the held result"

  /// The name of the named pipe that the background run reads.
  static let releasePipeName = "release.fifo"

  /// The text that the fixture writes into the named pipe.
  static let releaseText = "the run can settle"

  /// The text of the answer of each pass after the first.
  static let reply = "the answer"

  /// The number of `idle` updates after the prompt that lifts the pause:
  /// the `idle` of the pause, and the `idle` of that prompt.
  static let idleCountAfterTheLift = 2

  /// The snippet of the prompt: one shell read of the named pipe. The
  /// shell gives its pending answer at once, so the read runs in the
  /// background.
  static let pipeReadingSnippet =
    #"return await tools.shell.execute({ command: "cat \#(releasePipeName)" });"#

  // MARK: - The pause

  /// Opens one session with the limit `0` in a directory that holds the
  /// named pipe, sends the prompt that starts the background run, waits
  /// until the prompt ended, and then releases the run.
  ///
  /// - Parameter label: The directory label of the test.
  /// - Returns: The fixture, and the updates at the first `idle`.
  /// - Throws: Whatever the construction, the wire or the waits throw.
  static func pauseTheMailDelivery(
    label: String
  ) async throws -> (fixture: ScriptedPromptFixture, updates: [UpdateSessionNotification]) {
    let directory = try NamedPipe.makeDirectory(holding: releasePipeName, label: label)
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: startRunMarker,
          play: try ScriptedPromptFixture.makeToolPromptScript(code: pipeReadingSnippet)),
        .textDelta(reply),
        .endPass,
      ],
      label: label,
      workingDirectory: directory,
      mailOnlyAnswerLimit: 0)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: startRunMarker))
    // The fixed point: the prompt ended, so the run mail comes when no
    // answer runs, and it cannot join the answer of the prompt.
    await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
    try await NamedPipe.write(
      releaseText, toPipeAt: directory.appendingPathComponent(releasePipeName))
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    return (fixture, updates)
  }

  /// Sends the next prompt, which carries the held mail and so lifts the
  /// pause, and waits for the `idle` of that prompt.
  ///
  /// - Parameter fixture: The fixture of a paused session.
  /// - Returns: Each update of the session up to the `idle` of the prompt.
  /// - Throws: Whatever the wire or the wait throws.
  static func liftThePause(
    of fixture: ScriptedPromptFixture
  ) async throws -> [UpdateSessionNotification] {
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: secondPromptText))
    return try await ScriptedPromptFixture.waitForIdle(
      fixture.collector, count: idleCountAfterTheLift)
  }

  // MARK: - Readers

  /// The payload of each `_mail_delivery_paused` update, in order.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The payloads.
  static func pauses(in updates: [SessionUpdate]) -> [[String: FoundationModelsACP.JSONValue]] {
    updates.compactMap { update in
      guard case .unknown(let kind, .object(let members)) = update,
        kind == MailDeliveryPauseReport.updateKind
      else {
        return nil
      }
      return members
    }
  }
}
