import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Two ACP sessions over one queued scripted model

/// Two ACP sessions of one agent over the queued scripted model. The two
/// sessions resolve the same pool entry, thus each pass of each session goes
/// through the one generation queue of that entry.
struct QueuedScriptedFixture {
    /// The wired agent, the harness, and the first session (session A).
    let base: ScriptedTurnFixture

    /// The id of the second session (session B), in the same working
    /// directory as session A.
    let secondSessionId: SessionId

    /// The counter of the passes of the model of both sessions.
    let passCounter: ScriptedPassCounter

    /// The id of the first session (session A).
    var firstSessionId: SessionId {
        base.sessionId
    }

    /// Wires an agent over a queued scripted model, and opens two sessions.
    ///
    /// - Parameters:
    ///   - script: The steps each pass of each session plays.
    ///   - label: The directory label of the calling suite.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(script: [ScriptedTurnStep], label: String) async throws -> QueuedScriptedFixture {
        let passCounter = ScriptedPassCounter()
        let base = try await ScriptedTurnFixture.make(
            loader: StubModelLoader.makeQueuedScriptedLoader(script: script, passCounter: passCounter),
            label: label)
        let second = try await base.harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: base.cwd.path)))
        return QueuedScriptedFixture(
            base: base, secondSessionId: second.sessionId, passCounter: passCounter)
    }

    /// Sends one text prompt to `sessionId`. The agent acknowledges the
    /// prompt at once, and the prompt runs after that.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - text: The prompt text.
    /// - Throws: Whatever the wire throws.
    func prompt(_ sessionId: SessionId, text: String) async throws {
        _ = try await base.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text))
    }

    /// Waits until `sessionId` sent its idle state update, and gives the
    /// updates of that session.
    ///
    /// - Parameter sessionId: The session to watch.
    /// - Returns: The collected updates of `sessionId`.
    /// - Throws: `CancellationError` when the test is cancelled.
    func waitForIdle(of sessionId: SessionId) async throws -> [UpdateSessionNotification] {
        let updates = try await ScriptedTurnFixture.waitForUpdates(
            of: base.collector, toReach: "an idle update of \(sessionId.rawValue)"
        ) { updates in
            ScriptedTurnFixture.idleCount(in: Self.updates(of: sessionId, in: updates)) > 0
        }
        return Self.updates(of: sessionId, in: updates)
    }

    /// Waits until session A and session B each sent an idle state update.
    ///
    /// - Throws: `CancellationError` when the test is cancelled.
    func waitForIdleOfBothSessions() async throws {
        _ = try await waitForIdle(of: firstSessionId)
        _ = try await waitForIdle(of: secondSessionId)
    }

    /// Closes the harness wire.
    func close() async {
        await base.close()
    }

    /// The updates of one session in a collected sequence.
    ///
    /// - Parameters:
    ///   - sessionId: The session to keep.
    ///   - updates: The collected updates of all sessions.
    /// - Returns: The updates of `sessionId`, in arrival order.
    private static func updates(
        of sessionId: SessionId, in updates: [UpdateSessionNotification]
    ) -> [UpdateSessionNotification] {
        updates.filter { $0.sessionId == sessionId }
    }
}
