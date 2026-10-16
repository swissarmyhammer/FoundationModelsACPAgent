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
/// Each test sets the limit to `0`, so the first run mail is held at once.
/// The prompt starts a shell read of a named pipe, which goes to the
/// background at once. The test writes the pipe only after the prompt
/// ended, so the run mail comes when no answer runs.
@Suite struct MailDeliveryPauseTests {
    // MARK: - Constants

    /// The marker of the prompt that starts the background run.
    private static let startRunMarker = "Start the background run"

    /// The text of the second prompt, which carries the held mail.
    private static let secondPromptText = "Carry the held result"

    /// The name of the named pipe that the background run reads.
    private static let releasePipeName = "release.fifo"

    /// The text that the test writes into the named pipe.
    private static let releaseText = "the run can settle"

    /// The text of the answer of each pass after the first.
    private static let reply = "the answer"

    /// The snippet of the prompt: one shell read of the named pipe. The
    /// shell gives its pending answer at once, so the read runs in the
    /// background.
    private static let pipeReadingSnippet =
        #"return await tools.shell.execute({ command: "cat \#(releasePipeName)" });"#

    // MARK: - Helpers

    /// Opens one session with the limit `0` in a directory that holds the
    /// named pipe, sends the prompt that starts the background run, waits
    /// until the prompt ended, and then releases the run.
    ///
    /// - Parameter label: The directory label of the test.
    /// - Returns: The fixture, and the updates at the first `idle`.
    /// - Throws: Whatever the construction, the wire or the waits throw.
    private static func pauseTheMailDelivery(
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
        try await NamedPipe.write(releaseText, toPipeAt: directory.appendingPathComponent(releasePipeName))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        return (fixture, updates)
    }

    /// The payload of each `_mail_delivery_paused` update, in order.
    ///
    /// - Parameter updates: The updates.
    /// - Returns: The payloads.
    private static func pauses(in updates: [SessionUpdate]) -> [[String: FoundationModelsACP.JSONValue]] {
        updates.compactMap { update in
            guard case .unknown(let kind, .object(let members)) = update,
                kind == MailDeliveryPauseReport.updateKind
            else {
                return nil
            }
            return members
        }
    }

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
        let paused = try await Self.pauseTheMailDelivery(label: "MailDeliveryPauseTests-pause")
        let held = try await Self.queuedMail(of: paused.fixture)
        let history = try #require(
            await paused.fixture.harness.agent.sessions[paused.fixture.sessionId]?.history)
            .replayUpdates(from: .start)
        await paused.fixture.close()

        let updates = paused.updates.map(\.update)
        let pauses = Self.pauses(in: updates)
        #expect(pauses.count == 1)
        let pause = try #require(pauses.first)
        #expect(!held.isEmpty)
        #expect(pause[MailDeliveryPauseReport.MemberName.limit] == .number(0))
        #expect(pause[MailDeliveryPauseReport.MemberName.heldCount] == .number(Double(held.count)))
        guard case .array(let heldMail) = pause[MailDeliveryPauseReport.MemberName.heldMail] else {
            Issue.record("expected an array of held mail, got \(String(describing: pause[MailDeliveryPauseReport.MemberName.heldMail]))")
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
        let pauseIndex = try #require(updates.firstIndex { !Self.pauses(in: [$0]).isEmpty })
        let idleIndex = try #require(updates.firstIndex { if case .stateUpdate(.idle) = $0 { true } else { false } })
        #expect(pauseIndex < idleIndex)
        #expect(ScriptedPromptFixture.idleStopReason(in: paused.updates) == .endTurn)
        #expect(!ScriptedPromptFixture.agentChunkTexts(in: paused.updates).contains(Self.reply))
        #expect(Self.pauses(in: history).count == 1)
    }

    // MARK: - The next caller message lifts the pause

    /// The next prompt carries the held mail into its answer: after it, the
    /// session holds no mail, and no second pause comes. The prompt ends on
    /// `end_turn` with its reply.
    @Test
    func theNextPromptCarriesTheHeldMail() async throws {
        let paused = try await Self.pauseTheMailDelivery(label: "MailDeliveryPauseTests-lift")
        let heldAtPause = try await Self.queuedMail(of: paused.fixture)

        _ = try await paused.fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: paused.fixture.sessionId, text: Self.secondPromptText))
        let updates = try await ScriptedPromptFixture.waitForIdle(paused.fixture.collector, count: 2)
        let heldAfter = try await Self.queuedMail(of: paused.fixture)
        await paused.fixture.close()

        let afterPause = Array(updates[paused.updates.count...])
        #expect(!heldAtPause.isEmpty)
        #expect(heldAfter.isEmpty)
        #expect(Self.pauses(in: updates.map(\.update)).count == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: afterPause) == .endTurn)
        #expect(ScriptedPromptFixture.agentChunkTexts(in: afterPause).contains(Self.reply))
    }
}
