// `SpawnedAgentPromptDrive` — one prompt over a spawned `acp-agent acp`
// with an environment of its own, and then one chosen end of the agent.
//
// The telemetry suites each spawn the agent over the stub model, run
// `initialize`, `session/new` and one prompt, and then end the agent on a
// path they choose. This type holds that drive, so the suites do not keep
// copies of it.

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient

/// What one prompt over a spawned `acp-agent acp` gave back.
struct SpawnedAgentPromptDrive {
    /// The response to `initialize`.
    let initialized: InitializeResponse

    /// The stop reason of the prompt, or `nil` when the prompt did not end.
    let stopReason: StopReason?

    /// The raw bytes the agent wrote to its stdout.
    let standardOutput: Data

    /// How the agent ended.
    let exit: SpawnedAgentExit

    /// Spawns `acp-agent acp` over the stub model, runs `initialize`,
    /// `session/new` and one prompt, and then ends the agent with `ending`.
    ///
    /// The child starts with no `OTEL_*` variable of this process (see
    /// ``SpawnedACPAgent/environmentWithoutOpenTelemetry``), and gets each
    /// pair of `environment` and its own configuration home on top.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory tells where it
    ///     came from.
    ///   - environment: The extra environment pairs for the agent.
    ///   - promptText: The text of the one prompt.
    ///   - ending: The end request and the wait for the end.
    /// - Returns: The drive.
    /// - Throws: The spawn, request or wait error.
    static func run(
        label: String,
        environment: [String: String],
        promptText: String,
        ending: (SpawnedACPAgent) async throws -> SpawnedAgentExit
    ) async throws -> SpawnedAgentPromptDrive {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let configHome = makeResolvedDirectory(label: "\(label)-config")
        let childEnvironment = TierThreeFixture.stubModelEnvironment
            .merging(environment) { _, extra in extra }
            .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
        let agent = try SpawnedACPAgent.start(workspace: workspace, environment: childEnvironment)
        let tap = InboundTapTransport(wrapping: agent.transport)
        let model = await ConnectionModel()
        let connection = await model.connect(over: tap)

        let initialized = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
        let session = try await connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        // Subscribe before the prompt, so the stream holds each update of
        // the prompt in order.
        let updates = connection.subscribe(to: session.sessionId).updates
        _ = try await connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: promptText))
        let stopReason = await StdoutFrameChecks.waitForIdle(on: updates)

        let exit = try await ending(agent)
        await connection.close()
        return SpawnedAgentPromptDrive(
            initialized: initialized, stopReason: stopReason,
            standardOutput: tap.recordedBytes, exit: exit)
    }
}
