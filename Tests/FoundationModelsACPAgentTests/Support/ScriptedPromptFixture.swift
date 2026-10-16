import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
@testable import FoundationModelsRouter
import Testing
import Tracing

@testable import FoundationModelsACPAgent

// MARK: - The shared scripted wire fixture
//
// `PromptExecutionTests` and `CancellationTests` drive the same wiring: a
// scripted agent, a recording harness, an initialized wire, and one
// open session. This fixture owns that wiring, the collector waits,
// and the sequence readers, so a suite adds assertions and does not
// copy the setup.

/// One wired prompt fixture: a scripted agent, a recording
/// harness, an initialized wire, and one new session in `cwd`.
struct ScriptedPromptFixture {
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
    /// (the model-slot `select`), for the config-options assertions. The response
    /// seeds the list into ``session``, and the fixture reads it there
    /// when `session/new` returns.
    let newSessionConfigOptions: [SessionConfigOption]?

    /// Closes each session of the agent with `session/close`, then closes
    /// the harness wire.
    ///
    /// The agent also closes each open session itself when the connection
    /// closes (task `^56jbp35`), so this explicit
    /// `session/close` is not necessary to stop the MCP servers and their
    /// `SurfaceRefresher`. It stays because it is harmless, and because it
    /// ends each session on the request path that a client uses.
    /// `ConnectionCloseTests` proves the close with no `session/close`.
    ///
    /// The `session/close` of a session returns after the projector of the
    /// session sent each event, so a test can read what the session wrote
    /// after this call (task ^3546eff). Thus a failed `session/close` fails
    /// the test: without it, the session closes on the task of the
    /// connection close, and a read after this call is not a fixed point.
    func close() async {
        for sessionId in await harness.agent.sessions.keys {
            do {
                _ = try await harness.connection.closeSession(CloseSessionRequest(sessionId: sessionId))
            } catch {
                Issue.record("session/close of \(sessionId.rawValue) failed: \(error)")
            }
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
    ///     cli-plan.md §5.9 cancel proof needs it.
    ///   - tracer: The tracer of each Router session, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time. A suite that
    ///     captures the Router spans gives the tracer of its capture.
    ///   - commandProviders: The command providers that the agent gets
    ///     before `session/new`, so the session has their commands.
    ///   - runClock: The clock of the runs of the session, or `nil` for the
    ///     real clock. A test that drives the run grace gives a
    ///     `ManualRunClock`.
    ///   - mailOnlyAnswerLimit: The `mailOnlyAnswerLimit` of each session of
    ///     the agent, or `nil` for the Router default. A test of the pause of
    ///     the mail delivery gives `0` (task ^t03jd5h).
    ///   - recorder: Records each prompt that the scripted model gets, or
    ///     `nil` for no record. A test that must read what a background run
    ///     gave the model reads the prompt of the run message here.
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
        commandProviders: [any SlashCommandProviding] = [],
        runClock: (any RunClock)? = nil,
        mailOnlyAnswerLimit: Int? = nil,
        recorder: PromptRecorder? = nil
    ) async throws -> ScriptedPromptFixture {
        try await make(
            loader: makeScriptedModelLoader(script: script, recorder: recorder),
            label: label,
            capabilities: capabilities,
            workingDirectory: workingDirectory,
            projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers,
            additionalDirectories: additionalDirectories,
            tapsAgentWire: tapsAgentWire,
            tracer: tracer,
            commandProviders: commandProviders,
            runClock: runClock,
            mailOnlyAnswerLimit: mailOnlyAnswerLimit)
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
    ///     prompt order proof needs it.
    ///   - tapsAgentWire: Whether the harness stands a `WireTap` on the
    ///     agent end, so a proof can read what the client sent. Only the
    ///     cli-plan.md §5.9 cancel proof needs it.
    ///   - tracer: The tracer of each Router session, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - commandProviders: The command providers that the agent gets
    ///     before `session/new`, so the session has their commands.
    ///   - runClock: The clock of the runs of the session, or `nil` for the
    ///     real clock. A test that drives the run grace gives a
    ///     `ManualRunClock`.
    ///   - mailOnlyAnswerLimit: The `mailOnlyAnswerLimit` of each session of
    ///     the agent, or `nil` for the Router default.
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
        commandProviders: [any SlashCommandProviding] = [],
        runClock: (any RunClock)? = nil,
        mailOnlyAnswerLimit: Int? = nil
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
            tracer: tracer
        ) { router in
            if let runClock {
                await router.useRunClock(runClock)
            }
        }
        await agent.registerCommandProviders(commandProviders)
        if let mailOnlyAnswerLimit {
            await agent.useMailOnlyAnswerLimit(mailOnlyAnswerLimit)
        }
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
    /// file the session's configuration load reads. The project layer
    /// resolves for each session, from the session working directory.
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

    /// The script of a tool prompt whose `runCode` call plays only on the
    /// pass of the caller prompt that contains `marker`. Each other pass
    /// plays no output.
    ///
    /// An elicitation answer is mail to the session, and that mail starts
    /// an answer of its own (`mailbox.md`, section 5). Each pass plays the
    /// same script, so with ``makeToolPromptScript(code:)`` the answer of
    /// that mail would run the eliciting call again, with no end.
    ///
    /// - Parameters:
    ///   - code: The snippet the call runs.
    ///   - marker: A text that only the caller prompt contains.
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    static func makeToolPromptScript(code: String, onPromptContaining marker: String) throws -> [ScriptedPassStep] {
        [.onPrompt(containing: marker, play: try makeToolPromptScript(code: code)), .endPass]
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

    /// Waits until `condition` accepts the collected sequence, then returns
    /// that sequence. Each append to the collector checks the condition
    /// again, so the wait uses no clock and no poll.
    ///
    /// - Parameters:
    ///   - collector: The collector to watch.
    ///   - label: What the wait is for, named in the error of a cancelled
    ///     wait.
    ///   - condition: The acceptance test over the collected sequence.
    /// - Returns: The first accepted sequence.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    static func waitForUpdates(
        of collector: UpdateCollector,
        toReach label: String,
        _ condition: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
    ) async throws -> [UpdateSessionNotification] {
        try await collector.wait(for: label, until: condition)
    }

    /// Waits until `condition` accepts the collected sequence, for an update
    /// that comes before the run settles, then returns that sequence.
    ///
    /// The wait also ends on the failure event of test rule T1: the run
    /// settled. The wait counts the idle state updates at its start. A new
    /// idle state update is the settle of the run. When the run settled
    /// and `condition` does not accept the sequence, the wait throws.
    ///
    /// Use this wait only for an update that the run sends before its idle
    /// state update. Some updates come after the idle, for example a config
    /// option update or the retained history. For those, use
    /// ``waitForUpdates(of:toReach:_:)``.
    ///
    /// - Parameters:
    ///   - collector: The collector to watch.
    ///   - label: What the wait is for, named in the error of the wait.
    ///   - condition: The acceptance test over the collected sequence.
    /// - Returns: The first accepted sequence.
    /// - Throws: ``WaitEndedOnFailure`` when the run settled first, and
    ///   ``ConditionWaitCancelled`` when the test is cancelled first.
    static func waitForUpdatesBeforeSettle(
        of collector: UpdateCollector,
        toReach label: String,
        _ condition: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
    ) async throws -> [UpdateSessionNotification] {
        let baseline = idleCount(in: await collector.updates)
        let updates = try await collector.wait(for: label) { updates in
            condition(updates) || idleCount(in: updates) > baseline
        }
        guard condition(updates) else {
            throw WaitEndedOnFailure(condition: label, event: "the run settled")
        }
        return updates
    }

    /// Waits until the collector holds `count` idle state updates.
    ///
    /// - Parameters:
    ///   - collector: The collector to watch.
    ///   - count: The number of prompt ends to wait for.
    /// - Returns: The collected sequence.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    static func waitForIdle(
        _ collector: UpdateCollector, count: Int = 1
    ) async throws -> [UpdateSessionNotification] {
        try await waitForUpdates(of: collector, toReach: "\(count) idle update(s)") { updates in
            idleCount(in: updates) >= count
        }
    }

    /// Waits for the running state update that starts a prompt.
    ///
    /// The running update always comes before the idle update of its run,
    /// so the wait also ends when the run settles (test rule T1).
    ///
    /// - Parameter collector: The collector to watch.
    /// - Throws: ``WaitEndedOnFailure`` when the run settled first, and
    ///   ``ConditionWaitCancelled`` when the test is cancelled first.
    static func waitForRunning(_ collector: UpdateCollector) async throws {
        _ = try await waitForUpdatesBeforeSettle(of: collector, toReach: "a running update") { updates in
            updates.contains { notification in
                if case .stateUpdate(.running) = notification.update { return true }
                return false
            }
        }
    }

    /// Waits until the session has no open prompt and the end work of its
    /// last prompt is done (``RoutedACPAgent/awaitPromptsFinished(of:)``).
    ///
    /// The idle update goes out before the end work of the prompt: the
    /// write of the retained history and the reconcile of the config
    /// options. A reader of the session table or of the history file waits
    /// here after the idle. The end work resumes the wait, so it uses no
    /// clock.
    ///
    /// - Parameters:
    ///   - agent: The agent under test.
    ///   - sessionId: The session to watch.
    static func waitForPromptsFinished(_ agent: RoutedACPAgent, _ sessionId: SessionId) async {
        await agent.awaitPromptsFinished(of: sessionId)
    }

    /// Waits until the session model applied the idle state update that
    /// ends a prompt.
    ///
    /// The collector and the session model read the same updates on two
    /// paths: the collector gets each one from the served `Client`, and
    /// the model reads its own subscription. When the collector holds the
    /// idle update, the model can still be behind. The agent sends the
    /// idle update last in a prompt, so after the model applied it, the
    /// model holds each earlier update of the prompt. A reader of
    /// ``session`` waits here first. Each change of the model ends one
    /// observation, so the wait uses no clock and no poll.
    ///
    /// The wait also ends when the session closes (test rule T1). When the
    /// session closed and the model does not show the idle state, the wait
    /// throws.
    ///
    /// - Throws: ``WaitEndedOnFailure`` when the session closed first, and
    ///   ``ConditionWaitCancelled`` when the test is cancelled first.
    func waitForSessionModelIdle() async throws {
        let condition = "the session model applied the idle state update"
        try await ObservedValue.wait(for: condition) { [session] in
            Self.isIdle(session.agentState) || session.isClosed
        }
        if await !Self.isIdle(session.agentState) {
            throw WaitEndedOnFailure(condition: condition, event: "the session closed")
        }
    }

    /// Whether `state` is the idle state.
    ///
    /// - Parameter state: The state of the agent that a session model shows.
    /// - Returns: `true` for the idle state.
    private static func isIdle(_ state: StateUpdate?) -> Bool {
        guard case .idle = state else { return false }
        return true
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
