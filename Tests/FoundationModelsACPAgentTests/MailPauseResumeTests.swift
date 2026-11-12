import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

import struct FoundationModelsRouter.MailDeliveryPause

/// A `session/resume` gives the current pause of the mail delivery (task ^tq96bjy).
///
/// The pause is current state, as the `state_update` is. The replay holds no
/// `_mail_delivery_paused` update. A hot resume of a session that is paused now sends one
/// `_mail_delivery_paused` update after the replay, with the counts of the pause in force. A
/// session whose pause a prompt lifted sends none. A cold restore sends none: Router does not
/// restore the pause. It gives each queued mail with no terminal record the terminal event
/// `lost`, and the restored session holds no mail.
@Suite(.closesHarnesses) struct MailPauseResumeTests {
  // MARK: - Helpers

  /// Resumes the session of `fixture` on its own connection, and returns the updates that the
  /// resume sent before its response.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the session.
  ///   - replayFrom: The replay cursor of the request, or `nil` for none.
  /// - Returns: The updates that came after the request began, in order.
  /// - Throws: Whatever the request throws.
  private static func resume(
    _ fixture: ScriptedPromptFixture, replayFrom: ReplayFrom? = .start(ReplayFromStart())
  ) async throws -> [SessionUpdate] {
    let countBefore = await fixture.collector.updates.count
    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId,
        replayFrom: replayFrom))
    return Array(await fixture.collector.updates.dropFirst(countBefore)).map(\.update)
  }

  /// Closes the session of `fixture` with `session/close`, and resumes it on the same
  /// connection. The closed session is not live, so the resume restores it from its record.
  ///
  /// - Parameter fixture: The fixture of the session.
  /// - Returns: The updates that the restore sent before its response.
  /// - Throws: Whatever the requests throw.
  private static func closeAndRestore(_ fixture: ScriptedPromptFixture) async throws
    -> [SessionUpdate]
  {
    _ = try await fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: fixture.sessionId))
    return try await resume(fixture)
  }

  /// The pauses that come after the current `state_update` of a resume.
  ///
  /// - Parameter updates: The updates of a resume.
  /// - Returns: The payload of each pause after the first `state_update`, in order.
  private static func pausesAfterTheState(
    in updates: [SessionUpdate]
  ) -> [[String: FoundationModelsACP.JSONValue]] {
    MailDeliveryPauseFixture.pauses(in: Array(updates.drop { !$0.isStateUpdate }))
  }

  // MARK: - The replay

  /// The replay of a retained history that holds a pause sends no pause.
  @Test
  func theReplayOfARetainedHistoryHoldsNoMailDeliveryPause() {
    let pause = MailDeliveryPauseReport.update(for: MailDeliveryPause(limit: 0, heldMail: []))
    let history = SessionMergeEngine(replaying: [pause])

    #expect(MailDeliveryPauseFixture.pauses(in: history.replayUpdates(from: .start)).isEmpty)
  }

  // MARK: - The hot resume

  /// A hot resume of a paused session sends one pause, and it comes after the replay and the
  /// current state.
  @Test
  func aHotResumeOfAPausedSessionSendsOnePauseAfterTheReplay() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-hot-paused")
    let updates = try await Self.resume(paused.fixture)
    await paused.fixture.close()

    #expect(
      MailDeliveryPauseFixture.pauses(in: updates).count == 1
        && Self.pausesAfterTheState(in: updates).count == 1)
  }

  /// The pause that a hot resume sends carries the counts of the pause in force.
  @Test
  func theResumedPauseCarriesTheCountsOfThePauseInForce() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-hot-counts")
    let updates = try await Self.resume(paused.fixture)
    await paused.fixture.close()

    #expect(
      Self.pausesAfterTheState(in: updates)
        == MailDeliveryPauseFixture.pauses(in: paused.updates.map(\.update)))
  }

  /// A hot resume with no replay also sends the pause in force, because it is current state.
  @Test
  func aHotResumeWithNoReplaySendsThePause() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-hot-no-replay")
    let updates = try await Self.resume(paused.fixture, replayFrom: nil)
    await paused.fixture.close()

    #expect(MailDeliveryPauseFixture.pauses(in: updates).count == 1)
  }

  /// A hot resume of a session whose pause a prompt lifted sends no pause.
  @Test
  func aHotResumeAfterTheLiftSendsNoPause() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-hot-lifted")
    _ = try await MailDeliveryPauseFixture.liftThePause(of: paused.fixture)
    let updates = try await Self.resume(paused.fixture)
    await paused.fixture.close()

    #expect(MailDeliveryPauseFixture.pauses(in: updates).isEmpty)
  }

  // MARK: - The cold restore

  /// A cold restore of a paused session sends no pause: the restored Router session holds no
  /// mail.
  @Test
  func aColdRestoreOfAPausedSessionSendsNoPause() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-cold-paused")
    let updates = try await Self.closeAndRestore(paused.fixture)
    await paused.fixture.close()

    #expect(MailDeliveryPauseFixture.pauses(in: updates).isEmpty)
  }

  /// A cold restore of a session whose pause a prompt lifted sends no pause.
  @Test
  func aColdRestoreAfterTheLiftSendsNoPause() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailPauseResumeTests-cold-lifted")
    _ = try await MailDeliveryPauseFixture.liftThePause(of: paused.fixture)
    let updates = try await Self.closeAndRestore(paused.fixture)
    await paused.fixture.close()

    #expect(MailDeliveryPauseFixture.pauses(in: updates).isEmpty)
  }
}
