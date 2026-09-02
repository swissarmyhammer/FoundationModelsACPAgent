import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The shared scripted wire fixture (plan.md §20.1)
//
// `PromptTurnTests` and `CancellationTests` drive the same wiring: a
// scripted agent, a recording harness, an initialized wire, and one
// open session. This fixture owns that wiring, the collector waits,
// and the sequence readers, so a suite adds assertions and does not
// copy the setup.

/// One wired prompt-turn fixture: a scripted agent, a recording
/// harness, an initialized wire, and one new session in `cwd`.
struct ScriptedTurnFixture {
    /// The number of milliseconds in ``pollInterval``.
    private static let pollIntervalMilliseconds = 20

    /// The pause between two looks at the collector.
    static let pollInterval: Swift.Duration = .milliseconds(pollIntervalMilliseconds)

    /// The number of looks a wait makes before it records a failure.
    static let maxPollAttempts = 500

    /// The wired harness.
    let harness: AgentClientHarness

    /// The collector of the raw update sequence.
    let collector: UpdateCollector

    /// The id of the one open session.
    let sessionId: SessionId

    /// The session working directory.
    let cwd: URL

    /// Closes the harness wire.
    func close() async {
        await harness.close()
    }

    /// Wires a scripted agent, completes `initialize`, and opens one
    /// session.
    ///
    /// - Parameters:
    ///   - script: The steps the model plays on every turn.
    ///   - label: The directory label of the calling suite, so a
    ///     leftover directory says where it came from.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(
        script: [ScriptedTurnStep], label: String
    ) async throws -> ScriptedTurnFixture {
        let userDirectory = makeResolvedDirectory(label: "\(label)-user")
        let cwd = makeResolvedDirectory(label: "\(label)-repo")
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: userDirectory,
            loader: makeScriptedModelLoader(script: script))
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let response = try await harness.connection.newSession(
            NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: cwd.path))))
        let collector = try #require(harness.collector)
        return ScriptedTurnFixture(
            harness: harness, collector: collector, sessionId: response.sessionId, cwd: cwd)
    }

    /// The prompt request with one text block.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - text: The text of the one block.
    /// - Returns: The request.
    static func makePromptRequest(sessionId: SessionId, text: String) -> PromptRequest {
        PromptRequest(prompt: [.text(TextContent(text: text))], sessionId: sessionId)
    }

    // MARK: - Waits

    /// Polls the collector until `condition` accepts the collected
    /// sequence, then returns that sequence.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - label: What the wait is for, named in the failure.
    ///   - condition: The acceptance test over the collected sequence.
    /// - Returns: The first accepted sequence, or the final look.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForUpdates(
        of collector: UpdateCollector,
        toReach label: String,
        _ condition: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
    ) async throws -> [UpdateSessionNotification] {
        for _ in 0..<maxPollAttempts {
            let updates = await collector.updates
            if condition(updates) {
                return updates
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("the collector never reached: \(label)")
        return await collector.updates
    }

    /// Waits until the collector holds `count` idle state updates.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - count: The number of turn ends to wait for.
    /// - Returns: The collected sequence.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForIdle(
        _ collector: UpdateCollector, count: Int = 1
    ) async throws -> [UpdateSessionNotification] {
        try await waitForUpdates(of: collector, toReach: "\(count) idle update(s)") { updates in
            idleCount(in: updates) >= count
        }
    }

    /// Waits for the running state update that starts a turn.
    ///
    /// - Parameter collector: The collector to poll.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForRunning(_ collector: UpdateCollector) async throws {
        _ = try await waitForUpdates(of: collector, toReach: "a running update") { updates in
            updates.contains { notification in
                if case .stateUpdate(.running) = notification.update { return true }
                return false
            }
        }
    }

    /// Polls the agent until the session accepts a new prompt again.
    /// The idle notification goes out before the agent clears the turn,
    /// so a follow-up prompt waits here first.
    ///
    /// - Parameters:
    ///   - agent: The agent under test.
    ///   - sessionId: The session to watch.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForAvailability(
        _ agent: RoutedACPAgent, _ sessionId: SessionId
    ) async throws {
        for _ in 0..<maxPollAttempts {
            if await agent.sessions[sessionId]?.availability == .idle {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("the session never returned to idle availability")
    }

    // MARK: - Readers

    /// The number of idle state updates in the sequence.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The count.
    static func idleCount(in updates: [UpdateSessionNotification]) -> Int {
        updates.count { notification in
            if case .stateUpdate(.idle) = notification.update { return true }
            return false
        }
    }

    /// The number of idle state updates in a raw update sequence.
    ///
    /// - Parameter updates: The recorded raw updates.
    /// - Returns: The count.
    static func idleCount(in updates: [SessionUpdate]) -> Int {
        updates.count { update in
            if case .stateUpdate(.idle) = update { return true }
            return false
        }
    }

    /// The stop reason of the first idle state update, or `nil`.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The stop reason, or `nil` when no idle arrived.
    static func idleStopReason(in updates: [UpdateSessionNotification]) -> StopReason? {
        for notification in updates {
            if case .stateUpdate(.idle(let idle)) = notification.update {
                return idle.stopReason
            }
        }
        return nil
    }
}
