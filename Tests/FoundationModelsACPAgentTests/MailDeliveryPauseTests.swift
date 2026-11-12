import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The pause of the mail delivery of a session (task ^t03jd5h). Router holds
/// new run mail when `mailOnlyAnswerLimit` answers in a row had no caller
/// message, and it starts no answer for it. The client gets one
/// `_mail_delivery_paused` update before the `idle` of that work, the
/// retained history keeps it, and the next caller message carries the held
/// mail.
///
/// Each test pauses the mail delivery with ``MailDeliveryPauseFixture``.
@Suite(.closesHarnesses) struct MailDeliveryPauseTests {
  // MARK: - Helpers

  /// The mail that the Router session of the fixture holds in its queue.
  ///
  /// - Parameter fixture: The wired fixture.
  /// - Returns: The mail, in queue order.
  /// - Throws: When the session is missing.
  private static func queuedMail(of fixture: ScriptedPromptFixture) async throws -> [Mail] {
    let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
    return await session.pendingMessages()
  }

  // MARK: - The pause reaches the client

  /// The pause goes to the client as one `_mail_delivery_paused` update
  /// before the `idle` of the work. Its payload names the limit `0` and
  /// each held run mail of the queue. No answer runs for the held mail, so
  /// its reply does not come. The retained history keeps the update.
  @Test
  func thePauseReachesTheClientBeforeTheIdleAndStaysInTheHistory() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailDeliveryPauseTests-pause")
    let held = try await Self.queuedMail(of: paused.fixture)
    let history = try #require(
      await paused.fixture.harness.agent.sessions[paused.fixture.sessionId]?.history
    )
    .transcriptUpdates
    await paused.fixture.close()

    let updates = paused.updates.map(\.update)
    let pauses = MailDeliveryPauseFixture.pauses(in: updates)
    #expect(pauses.count == 1)
    let pause = try #require(pauses.first)
    #expect(!held.isEmpty)
    #expect(pause[MailDeliveryPauseReport.MemberName.limit] == .number(0))
    #expect(pause[MailDeliveryPauseReport.MemberName.heldCount] == .number(Double(held.count)))
    guard case .array(let heldMail) = pause[MailDeliveryPauseReport.MemberName.heldMail] else {
      Issue.record(
        "expected an array of held mail, got \(String(describing: pause[MailDeliveryPauseReport.MemberName.heldMail]))"
      )
      return
    }
    #expect(heldMail.count == held.count)
    for entry in heldMail {
      guard case .object(let members) = entry else {
        Issue.record("expected an object for each held mail, got \(entry)")
        continue
      }
      #expect(members[MailDeliveryPauseReport.MemberName.completionToken] != nil)
    }
    let pauseIndex = try #require(
      updates.firstIndex { !MailDeliveryPauseFixture.pauses(in: [$0]).isEmpty })
    let idleIndex = try #require(
      updates.firstIndex { if case .stateUpdate(.idle) = $0 { true } else { false } })
    #expect(pauseIndex < idleIndex)
    #expect(ScriptedPromptFixture.idleStopReason(in: paused.updates) == .endTurn)
    #expect(
      !ScriptedPromptFixture.agentChunkTexts(in: paused.updates)
        .contains(MailDeliveryPauseFixture.reply))
    #expect(MailDeliveryPauseFixture.pauses(in: history).count == 1)
  }

  // MARK: - The next caller message lifts the pause

  /// The next prompt carries the held mail into its answer: after it, the
  /// session holds no mail, and no second pause comes. The prompt ends on
  /// `end_turn` with its reply.
  @Test
  func theNextPromptCarriesTheHeldMail() async throws {
    let paused = try await MailDeliveryPauseFixture.pauseTheMailDelivery(
      label: "MailDeliveryPauseTests-lift")
    let heldAtPause = try await Self.queuedMail(of: paused.fixture)

    let updates = try await MailDeliveryPauseFixture.liftThePause(of: paused.fixture)
    let heldAfter = try await Self.queuedMail(of: paused.fixture)
    await paused.fixture.close()

    let afterPause = Array(updates[paused.updates.count...])
    #expect(!heldAtPause.isEmpty)
    #expect(heldAfter.isEmpty)
    #expect(MailDeliveryPauseFixture.pauses(in: updates.map(\.update)).count == 1)
    #expect(ScriptedPromptFixture.idleStopReason(in: afterPause) == .endTurn)
    #expect(
      ScriptedPromptFixture.agentChunkTexts(in: afterPause)
        .contains(MailDeliveryPauseFixture.reply))
  }
}
