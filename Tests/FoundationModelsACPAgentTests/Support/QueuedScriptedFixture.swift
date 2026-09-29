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
    ///   - workingDirectory: The working directory of both sessions, or `nil`
    ///     (the default) to make a fresh one.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(
        script: [ScriptedTurnStep], label: String, workingDirectory: URL? = nil
    ) async throws -> QueuedScriptedFixture {
        let passCounter = ScriptedPassCounter()
        let base = try await ScriptedTurnFixture.make(
            loader: StubModelLoader.makeQueuedScriptedLoader(script: script, passCounter: passCounter),
            label: label,
            workingDirectory: workingDirectory)
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

    /// Waits until `sessionId` sent `count` idle state updates, one for each
    /// prompt that ended, and gives the updates of that session.
    ///
    /// - Parameters:
    ///   - sessionId: The session to watch.
    ///   - count: The number of idle updates to wait for. The default is 1.
    /// - Returns: The collected updates of `sessionId`.
    /// - Throws: `CancellationError` when the test is cancelled.
    func waitForIdle(
        of sessionId: SessionId, count: Int = 1
    ) async throws -> [UpdateSessionNotification] {
        try await Poll.until("idle update \(count) of \(sessionId.rawValue)") {
            ScriptedTurnFixture.idleCount(in: await updates(of: sessionId)) >= count
        }
        return await updates(of: sessionId)
    }

    /// The updates that `sessionId` sent until now, in arrival order.
    ///
    /// - Parameter sessionId: The session to read.
    /// - Returns: The collected updates of `sessionId`.
    func updates(of sessionId: SessionId) async -> [UpdateSessionNotification] {
        await base.collector.updates.filter { $0.sessionId == sessionId }
    }

    /// The elicitations of `sessionId` that the client did not answer yet.
    ///
    /// - Parameter sessionId: The session to read.
    /// - Returns: The pending elicitations of `sessionId`, in arrival order.
    func pendingElicitations(of sessionId: SessionId) async -> [PendingElicitation] {
        await ElicitationPoll.pendingElicitations(of: sessionId, on: base.harness.client)
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

    /// Closes session A and session B with `session/close`, and then the
    /// harness wire.
    ///
    /// A close stops each background run of the session and each pending
    /// elicitation. A test that leaves a run in the background calls this,
    /// so no work of its sessions continues after the test.
    ///
    /// - Throws: Whatever the wire throws.
    func closeSessions() async throws {
        for sessionId in [firstSessionId, secondSessionId] {
            _ = try await base.harness.connection.closeSession(
                CloseSessionRequest(sessionId: sessionId))
        }
        await close()
    }
}
