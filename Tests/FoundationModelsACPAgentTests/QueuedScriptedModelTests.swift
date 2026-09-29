import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The queued scripted model of the test support: its passes go through the
/// Router generation queue of one pool entry, its hold step ends on
/// `release()` and on cancel, and its pass counter shows what ran.
@Suite struct QueuedScriptedModelTests {
    /// The directory label of this suite.
    private static let label = "QueuedScriptedModelTests"

    /// The prompt text of each prompt of this suite.
    private static let promptText = "Run one pass"

    /// The number of ACP sessions of the fixture.
    private static let sessionCount = 2

    /// Wires the two-session fixture over a script that holds each pass
    /// until `hold` is released.
    ///
    /// - Parameter hold: The hold of each pass.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeHeldFixture(hold: ScriptedHold) async throws -> QueuedScriptedFixture {
        try await QueuedScriptedFixture.make(
            script: [.holdUntilReleased(hold), .textDelta("released"), .endTurn], label: label)
    }

    /// Wires the held fixture, prompts session A, and waits until the pass
    /// of session A runs, thus holds.
    ///
    /// - Parameter hold: The hold of each pass.
    /// - Returns: The fixture, with the pass of session A held.
    /// - Throws: Whatever the construction, the wire or the wait throws.
    private static func startHeldPass(hold: ScriptedHold) async throws -> QueuedScriptedFixture {
        let fixture = try await makeHeldFixture(hold: hold)
        try await fixture.prompt(fixture.firstSessionId, text: promptText)
        let counter = fixture.passCounter
        try await Poll.until("the pass of session A is held") { counter.runningCount == 1 }
        return fixture
    }

    /// Two sessions that prompt at the same time over one queued model never
    /// run two passes at the same time.
    @Test(.timeLimit(.minutes(1)))
    func twoSessionsNeverRunTwoPassesAtOnce() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.makeHeldFixture(hold: hold)
        try await fixture.prompt(fixture.firstSessionId, text: Self.promptText)
        try await fixture.prompt(fixture.secondSessionId, text: Self.promptText)
        let counter = fixture.passCounter
        try await Poll.until("both prompts reach the model") {
            await counter.startedCount + counter.waitingCount == Self.sessionCount
        }

        hold.release()
        try await fixture.waitForIdleOfBothSessions()
        await fixture.close()

        #expect(counter.maximumRunningCount == 1)
    }

    /// A held pass ends when the test calls `release()`.
    @Test(.timeLimit(.minutes(1)))
    func releaseEndsAHeldPass() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startHeldPass(hold: hold)

        hold.release()
        let updates = try await fixture.waitForIdle(of: fixture.firstSessionId)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        #expect(fixture.passCounter.runningCount == 0)
    }

    /// A held pass ends when the client cancels its prompt.
    @Test(.timeLimit(.minutes(1)))
    func cancelEndsAHeldPass() async throws {
        let fixture = try await Self.startHeldPass(hold: ScriptedHold())

        try await fixture.base.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.firstSessionId))
        let updates = try await fixture.waitForIdle(of: fixture.firstSessionId)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        #expect(fixture.passCounter.runningCount == 0)
    }

    /// While session A holds a pass, a prompt on session B waits for a queue
    /// place and starts no pass.
    @Test(.timeLimit(.minutes(1)))
    func aSecondSessionWaitsForTheHeldPass() async throws {
        let hold = ScriptedHold()
        let fixture = try await Self.startHeldPass(hold: hold)
        let counter = fixture.passCounter

        try await fixture.prompt(fixture.secondSessionId, text: Self.promptText)
        try await Poll.until("the prompt of session B waits for a queue place") {
            await counter.waitingCount == 1
        }
        let startedWhileHeld = counter.startedCount

        hold.release()
        try await fixture.waitForIdleOfBothSessions()
        await fixture.close()

        #expect(startedWhileHeld == 1)
    }
}
