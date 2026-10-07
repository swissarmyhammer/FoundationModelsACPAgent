import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Testing
import Tracing

@testable import FoundationModelsACPAgent

// MARK: - The shared scripted wire fixture (plan.md §20.1)
//
// `PromptExecutionTests` and `CancellationTests` drive the same wiring: a
// scripted agent, a recording harness, an initialized wire, and one
// open session. This fixture owns that wiring, the collector waits,
// and the sequence readers, so a suite adds assertions and does not
// copy the setup.

/// One wired prompt fixture: a scripted agent, a recording
/// harness, an initialized wire, and one new session in `cwd`.
struct ScriptedPromptFixture {
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

    /// The observable model of the one open session. The connection model
    /// of the harness opened it, so the router of the model gives each
    /// elicitation of the session to it.
    let session: SessionModel

    /// The session working directory.
    let cwd: URL

    /// The `configOptions` list the `session/new` response announced
    /// (plan.md §15), for the config-options assertions. The response
    /// seeds the list into ``session``, and the fixture reads it there
    /// when `session/new` returns.
    let newSessionConfigOptions: [SessionConfigOption]?

    /// Closes each session of the agent with `session/close`, then closes
    /// the harness wire.
    ///
    /// The agent also closes each open session itself when the connection
    /// closes (plan.md §10.1, task `^56jbp35`), so this explicit
    /// `session/close` is not necessary to stop the MCP servers and their
    /// `SurfaceRefresher`. It stays because it is harmless, and because it
    /// ends each session on the request path that a client uses.
    /// `ConnectionCloseTests` proves the close with no `session/close`.
    func close() async {
        for sessionId in await harness.agent.sessions.keys {
            _ = try? await harness.connection.closeSession(CloseSessionRequest(sessionId: sessionId))
        }
        await harness.close()
    }

    /// Wires a scripted agent, completes `initialize`, and opens one
    /// session.
    ///
    /// - Parameters:
    ///   - script: The steps the model plays on every pass.
    ///   - label: The directory label of the calling suite, so a
    ///     leftover directory says where it came from.
    ///   - capabilities: The client capabilities `initialize` announces.
    ///     The default is the driver's full advertisement; an
    ///     elicitation-gate suite passes a reduced set.
    ///   - workingDirectory: The session working directory to open the
    ///     session in, or `nil` to make a fresh one. A suite passes a
    ///     pre-made directory when the script embeds its path.
    ///   - projectConfigYAML: The project `config.yaml` to write under
    ///     `<cwd>/.<name>/` before `session/new`, or `nil` for none.
    ///   - mcpServers: The client's per-session MCP servers to pass in
    ///     `session/new`, or `nil` for none.
    ///   - additionalDirectories: The `session/new` additional roots, or
    ///     `nil` for none.
    ///   - tapsAgentWire: Whether the harness stands a `WireTap` on the
    ///     agent end, so a proof can read what the client sent. Only the
    ///     §5.9 cancel proof needs it.
    ///   - tracer: The tracer of each Router session, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time. A suite that
    ///     captures the Router spans gives the tracer of its capture.
    ///   - commandProviders: The command providers that the agent gets
    ///     before `session/new`, so the session has their commands.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(
        script: [ScriptedPassStep],
        label: String,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities,
        workingDirectory: URL? = nil,
        projectConfigYAML: String? = nil,
        mcpServers: [MCPServer]? = nil,
        additionalDirectories: [AbsolutePath]? = nil,
        tapsAgentWire: Bool = false,
        tracer: (any Tracer)? = nil,
        commandProviders: [any SlashCommandProviding] = []
    ) async throws -> ScriptedPromptFixture {
        try await make(
            loader: makeScriptedModelLoader(script: script),
            label: label,
            capabilities: capabilities,
            workingDirectory: workingDirectory,
            projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers,
            additionalDirectories: additionalDirectories,
            tapsAgentWire: tapsAgentWire,
            tracer: tracer,
            commandProviders: commandProviders)
    }

    /// Wires an agent over `loader`, completes `initialize`, and opens
    /// one session. The config-options suite injects a per-slot loader
    /// here; the plain `make(script:label:)` builds the shared scripted
    /// loader.
    ///
    /// - Parameters:
    ///   - loader: The model loader the agent resolves against.
    ///   - label: The directory label of the calling suite, so a
    ///     leftover directory says where it came from.
    ///   - capabilities: The client capabilities `initialize` announces.
    ///     The default is the driver's full advertisement; an
    ///     elicitation-gate suite passes a reduced set.
    ///   - workingDirectory: The session working directory to open the
    ///     session in, or `nil` to make a fresh one. A suite passes a
    ///     pre-made directory when the script embeds its path.
    ///   - projectConfigYAML: The project `config.yaml` to write under
    ///     `<cwd>/.<name>/` before `session/new`, or `nil` for none.
    ///   - mcpServers: The client's per-session MCP servers to pass in
    ///     `session/new`, or `nil` for none.
    ///   - additionalDirectories: The `session/new` additional roots, or
    ///     `nil` for none.
    ///   - tapsWire: Whether the harness stands a `WireTap` on the
    ///     client end, so a proof can read the raw line order. Only the
    ///     §8.1 order proof needs it.
    ///   - tapsAgentWire: Whether the harness stands a `WireTap` on the
    ///     agent end, so a proof can read what the client sent. Only the
    ///     §5.9 cancel proof needs it.
    ///   - tracer: The tracer of each Router session, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - commandProviders: The command providers that the agent gets
    ///     before `session/new`, so the session has their commands.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(
        loader: any ModelLoader,
        label: String,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities,
        workingDirectory: URL? = nil,
        projectConfigYAML: String? = nil,
        mcpServers: [MCPServer]? = nil,
        additionalDirectories: [AbsolutePath]? = nil,
        tapsWire: Bool = false,
        tapsAgentWire: Bool = false,
        tracer: (any Tracer)? = nil,
        commandProviders: [any SlashCommandProviding] = []
    ) async throws -> ScriptedPromptFixture {
        let userDirectory = makeResolvedDirectory(label: "\(label)-user")
        let cwd = workingDirectory ?? makeResolvedDirectory(label: "\(label)-repo")
        if let projectConfigYAML {
            try writeProjectConfig(yaml: projectConfigYAML, under: cwd)
        }
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: userDirectory,
            loader: loader,
            tracer: tracer)
        await agent.registerCommandProviders(commandProviders)
        let harness = await AgentClientHarness.makeRecording(
            agent: agent, tapsWire: tapsWire, tapsAgentWire: tapsAgentWire)
        // The model must send `initialize` itself: it keeps the agent
        // capabilities, and `newSession(_:)` sends MCP servers and
        // additional directories only when the agent advertises them.
        _ = try await harness.client.initialize(
            AgentClientHarness.makeInitializeRequest(capabilities: capabilities))
        let session = try await harness.client.newSession(
            NewSessionRequest(
                cwd: AbsolutePath(rawValue: cwd.path),
                additionalDirectories: additionalDirectories,
                mcpServers: mcpServers))
        let (sessionId, configOptions) = await MainActor.run { (session.sessionId, session.configOptions) }
        let collector = try #require(harness.collector)
        return ScriptedPromptFixture(
            harness: harness, collector: collector, sessionId: sessionId, session: session, cwd: cwd,
            newSessionConfigOptions: configOptions)
    }

    /// Writes `yaml` as the project-layer `config.yaml` of `cwd`, the
    /// file the session's configuration load reads (plan.md §2.2).
    ///
    /// - Parameters:
    ///   - yaml: The configuration document to write.
    ///   - cwd: The session working directory the dotfolder roots at.
    /// - Throws: The directory-creation or write error.
    static func writeProjectConfig(yaml: String, under cwd: URL) throws {
        try ConfigFileFixture.write(
            yaml,
            in: cwd.appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true))
    }

    // MARK: - Script builders

    /// The name of the code-mode session tool a scripted tool prompt invokes.
    static let runCodeToolName = "runCode"

    /// The script of one tool prompt: `runCode` with `code`, then the end.
    ///
    /// A snippet that settles inside the inline grace of `runCode` answers
    /// in the `runCode` call itself. A longer run comes back as mail when
    /// it comes back, and the script waits for nothing.
    ///
    /// - Parameter code: The snippet the prompt runs.
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    static func makeToolPromptScript(code: String) throws -> [ScriptedPassStep] {
        [try makeRunCodeCall(code: code), .endPass]
    }

    /// The step of one `runCode` call with `code`.
    ///
    /// - Parameter code: The snippet the call runs.
    /// - Returns: The tool-call step.
    /// - Throws: The arguments-encoding error.
    static func makeRunCodeCall(code: String) throws -> ScriptedPassStep {
        let arguments = String(decoding: try JSONEncoder().encode(["code": code]), as: UTF8.self)
        return .toolCall(name: runCodeToolName, argumentsJSON: arguments)
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
    ///   - count: The number of prompt ends to wait for.
    /// - Returns: The collected sequence.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForIdle(
        _ collector: UpdateCollector, count: Int = 1
    ) async throws -> [UpdateSessionNotification] {
        try await waitForUpdates(of: collector, toReach: "\(count) idle update(s)") { updates in
            idleCount(in: updates) >= count
        }
    }

    /// Waits for the running state update that starts a prompt.
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
    /// The idle notification goes out before the agent clears the prompt,
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

    /// Polls the session model until it applied the idle state update
    /// that ends a prompt.
    ///
    /// The collector and the session model read the same updates on two
    /// paths: the collector gets each one from the served `Client`, and
    /// the model reads its own subscription. When the collector holds the
    /// idle update, the model can still be behind. The agent sends the
    /// idle update last in a prompt, so after the model applied it, the
    /// model holds each earlier update of the prompt. A reader of
    /// ``session`` waits here first, and never sleeps for it.
    ///
    /// - Throws: `CancellationError` when the test is cancelled.
    func waitForSessionModelIdle() async throws {
        try await Poll.until("the session model applied the idle state update") {
            await MainActor.run {
                guard case .idle = session.agentState else { return false }
                return true
            }
        }
    }

    // MARK: - Readers

    /// The agent message text of a collected sequence, one item for each
    /// `agent_message_chunk`, in arrival order. A suite that asks about
    /// one chunk reads this; a suite that asks about the whole message
    /// reads ``agentText(in:)``.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The chunk texts.
    static func agentChunkTexts(in updates: [UpdateSessionNotification]) -> [String] {
        updates.compactMap { notification in
            if case .agentMessageChunk(let chunk) = notification.update,
                case .text(let content) = chunk.content
            {
                return content.text
            }
            return nil
        }
    }

    /// The agent message text of a collected sequence: the text of each
    /// `agent_message_chunk`, joined in arrival order.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The agent text.
    static func agentText(in updates: [UpdateSessionNotification]) -> String {
        agentChunkTexts(in: updates).joined()
    }

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

    /// The stop reason of the first idle state update in a raw update
    /// sequence, or `nil`.
    ///
    /// - Parameter updates: The recorded raw updates.
    /// - Returns: The stop reason, or `nil` when no idle arrived.
    static func idleStopReason(in updates: [SessionUpdate]) -> StopReason? {
        for update in updates {
            if case .stateUpdate(.idle(let idle)) = update {
                return idle.stopReason
            }
        }
        return nil
    }
}
