import FoundationModelsACP
import Testing

@testable import acp_agent

/// The end of the own prompt of a headless run (elicitation-plan task 43,
/// rule A): the first `idle` after the `user_message` echo of the own
/// `messageId`. The response and the echo can arrive in either order.
@Suite struct PromptEndTrackerTests {
    /// The `messageId` of the own prompt.
    private static let ownId = MessageId(rawValue: "01J9ZOWNPROMPT00000000000A")

    /// The `messageId` of an earlier prompt of the session.
    private static let earlierId = MessageId(rawValue: "01J9ZEARLIERPROMPT0000000A")

    /// The echo of a user message with `messageId`.
    ///
    /// - Parameter messageId: The id of the message.
    /// - Returns: The update.
    private static func echo(_ messageId: MessageId) -> SessionUpdate {
        .userMessage(UserMessage(messageId: messageId, content: .value([])))
    }

    /// An `idle` with `stopReason`.
    ///
    /// - Parameter stopReason: The stop reason.
    /// - Returns: The update.
    private static func idle(_ stopReason: StopReason) -> SessionUpdate {
        .stateUpdate(.idle(IdleStateUpdate(stopReason: stopReason)))
    }

    /// The idle of earlier work, before the own echo, does not end the own
    /// prompt. The first idle after the own echo does.
    @Test func anIdleBeforeTheOwnEchoDoesNotEndThePrompt() {
        var tracker = PromptEndTracker()
        tracker.learn(ownMessage: Self.ownId)
        tracker.receive(Self.echo(Self.earlierId))
        tracker.receive(Self.idle(.cancelled))
        #expect(!tracker.ended)

        tracker.receive(Self.echo(Self.ownId))
        tracker.receive(Self.idle(.endTurn))

        #expect(tracker.ended)
        #expect(tracker.stopReason == .endTurn)
    }

    /// The echo and its idle can arrive before the response gives the own
    /// `messageId`: the tracker ends the prompt when it learns the id.
    @Test func theResponseCanComeAfterTheEchoAndTheIdle() {
        var tracker = PromptEndTracker()
        tracker.receive(Self.echo(Self.ownId))
        tracker.receive(Self.idle(.maxTokens))
        #expect(!tracker.ended)

        tracker.learn(ownMessage: Self.ownId)

        #expect(tracker.ended)
        #expect(tracker.stopReason == .maxTokens)
    }

    /// With no echo of the own prompt, no idle ends it.
    @Test func noIdleEndsThePromptBeforeItsEcho() {
        var tracker = PromptEndTracker()
        tracker.learn(ownMessage: Self.ownId)
        tracker.receive(Self.idle(.endTurn))

        #expect(!tracker.ended)
    }

    // MARK: - The pause of the mail delivery (task ^t03jd5h)

    /// A `_mail_delivery_paused` update that holds `heldCount` results at
    /// the limit `limit`.
    ///
    /// - Parameters:
    ///   - heldCount: How many results the session held.
    ///   - limit: The limit in force.
    /// - Returns: The update.
    private static func pause(heldCount: Int, limit: Int) -> SessionUpdate {
        .unknown(
            HeldMailNotice.updateKind,
            .object(["limit": .number(Double(limit)), "heldCount": .number(Double(heldCount))]))
    }

    /// A pause between the own echo and the ending idle is the pause of the
    /// run, also when the idle says `end_turn`.
    @Test func aPauseBetweenTheOwnEchoAndTheEndingIdleIsThePauseOfTheRun() {
        var tracker = PromptEndTracker()
        tracker.learn(ownMessage: Self.ownId)
        tracker.receive(Self.echo(Self.ownId))
        tracker.receive(Self.pause(heldCount: 2, limit: 0))
        tracker.receive(Self.idle(.endTurn))

        #expect(tracker.ended)
        #expect(tracker.stopReason == .endTurn)
        #expect(tracker.mailPause == HeldMailNotice(heldCount: 2, limit: 0))
    }

    /// A pause before the own echo belongs to earlier work of the session.
    @Test func aPauseBeforeTheOwnEchoIsNotThePauseOfTheRun() {
        var tracker = PromptEndTracker()
        tracker.learn(ownMessage: Self.ownId)
        tracker.receive(Self.pause(heldCount: 1, limit: 0))
        tracker.receive(Self.echo(Self.ownId))
        tracker.receive(Self.idle(.endTurn))

        #expect(tracker.ended)
        #expect(tracker.mailPause == nil)
    }

    /// A pause after the ending idle comes after the end of the run, so it
    /// does not change the result.
    @Test func aPauseAfterTheEndingIdleIsNotThePauseOfTheRun() {
        var tracker = PromptEndTracker()
        tracker.learn(ownMessage: Self.ownId)
        tracker.receive(Self.echo(Self.ownId))
        tracker.receive(Self.idle(.endTurn))
        tracker.receive(Self.pause(heldCount: 1, limit: 0))

        #expect(tracker.mailPause == nil)
    }
}
