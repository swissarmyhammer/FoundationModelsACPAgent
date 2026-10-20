import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import MCPTestServer
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The six builtin slash commands: `/compact`,
/// `/context`, `/memory`, `/status`, `/config` and `/help`. Each streams its
/// text as an `.action` prompt, with no model pass. The suite drives them over
/// the harness and asserts the streamed text and the filesystem effects.
@Suite(.closesHarnesses) struct BuiltinCommandsTests {
    /// The bare names of the six builtins, in registration order.
    private static let builtinNames = ["compact", "context", "memory", "status", "config", "help"]

    /// The default `standard` slot candidate the stub profile resolves. The
    /// `/status` model line and the `/compact` summarizer line both name it.
    private static let defaultStandardModel = "mlx-community/Qwen3.8-27B-mxfp4"

    // MARK: - Fixture

    /// One wired builtin fixture: a stub-model agent whose builtins are
    /// registered by `session/new`, a recording harness, an initialized wire,
    /// and one open session in `cwd`.
    private struct Fixture {
        /// The wired harness.
        let harness: AgentClientHarness

        /// The collector of the raw update sequence.
        let collector: UpdateCollector

        /// The id of the one open session.
        let sessionId: SessionId

        /// The session working directory.
        let cwd: URL

        /// The injected user layer root.
        let userDirectory: URL

        /// Closes the harness wire.
        func close() async {
            await harness.close()
        }

        /// Wires an agent over `loader`, having optionally seeded a project
        /// `config.yaml` and an `AGENTS.md` under `cwd`, completes
        /// `initialize`, and opens one session.
        ///
        /// - Parameters:
        ///   - label: The directory label of the calling test.
        ///   - loader: The model loader the agent resolves against. Defaults
        ///     to the echo loader, which no builtin drives.
        ///   - projectConfigYAML: The `config.yaml` to write under
        ///     `<cwd>/.<name>/`, or `nil` to write none.
        ///   - agentsMarkdown: The `AGENTS.md` to write in `cwd`, or `nil`.
        ///   - secretStore: The store that gives the value of each secret
        ///     reference of the configuration. The default is an empty
        ///     in-memory store.
        /// - Returns: The wired fixture.
        /// - Throws: Whatever the construction or the handshake throws.
        static func make(
            label: String,
            loader: any ModelLoader = StubModelLoader(),
            projectConfigYAML: String? = nil,
            agentsMarkdown: String? = nil,
            secretStore: any SecretStore = InMemorySecretStore()
        ) async throws -> Fixture {
            let cwd = makeResolvedDirectory(label: "\(label)-repo")
            let userDirectory = makeResolvedDirectory(label: "\(label)-user")
            if let projectConfigYAML {
                let dotfolder = cwd.appendingPathComponent(
                    ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: dotfolder, withIntermediateDirectories: true)
                try projectConfigYAML.write(
                    to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
                    atomically: true, encoding: .utf8)
            }
            if let agentsMarkdown {
                try agentsMarkdown.write(
                    to: cwd.appendingPathComponent(InstructionsAssembler.agentsFileName),
                    atomically: true, encoding: .utf8)
            }
            let agent = try await makeStubAgent(
                name: AgentClientHarness.dotfolderName,
                cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
                userDirectory: userDirectory,
                loader: loader,
                secretStore: secretStore)
            let harness = await AgentClientHarness.makeRecording(agent: agent)
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            let response = try await harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))
            let collector = try #require(harness.collector)
            return Fixture(
                harness: harness, collector: collector, sessionId: response.sessionId,
                cwd: cwd, userDirectory: userDirectory)
        }

        /// Prompts `command` over the wire, waits for the prompt to end, and
        /// returns the streamed agent-message text joined into one string.
        ///
        /// - Parameter command: The full command text, e.g. `"/status"`.
        /// - Returns: The joined streamed text and the collected sequence.
        /// - Throws: Whatever the prompt or the wait throws.
        func runCommand(_ command: String) async throws -> (
            text: String, updates: [UpdateSessionNotification]
        ) {
            _ = try await harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: sessionId, text: command))
            let updates = try await ScriptedPromptFixture.waitForIdle(collector)
            return (ScriptedPromptFixture.agentText(in: updates), updates)
        }
    }

    // MARK: - /help

    /// `/help` names all six builtins in its streamed output.
    @Test
    func helpListsAllSixBuiltins() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-help")

        let result = try await fixture.runCommand("/help")
        await fixture.close()

        for name in Self.builtinNames {
            #expect(result.text.contains("/\(name)"))
        }
    }

    // MARK: - /status

    /// `/status` names the session id, the cwd, the model, the profile and
    /// the transcript path.
    @Test
    func statusNamesSessionCwdModelAndTranscript() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-status")

        let result = try await fixture.runCommand("/status")

        #expect(result.text.contains(fixture.sessionId.rawValue))
        #expect(result.text.contains(fixture.cwd.path))
        #expect(result.text.contains(Self.defaultStandardModel))
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        await fixture.close()
        #expect(result.text.contains(entry.transcriptDirectory.path))
    }

    // MARK: - /context

    /// The context report guards a NaN fill with "not measured yet" and never
    /// prints the word NaN.
    @Test func contextReportGuardsANaNFill() {
        let unmeasured = BuiltinCommands.contextReport(fill: Double.nan)
        #expect(unmeasured.contains("not measured yet"))
        #expect(!unmeasured.lowercased().contains("nan"))
    }

    /// The context report shows a measured fraction as a whole-number percent.
    @Test func contextReportShowsAMeasuredPercent() {
        let halfFull = 0.5
        let report = BuiltinCommands.contextReport(fill: halfFull)
        #expect(report.contains("50%"))
        #expect(!report.contains("not measured yet"))
    }

    /// `/context` before the first model pass streams a line that never
    /// contains the word NaN.
    @Test
    func contextBeforeAnyPromptNeverPrintsNaN() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-context")

        let result = try await fixture.runCommand("/context")
        await fixture.close()

        #expect(result.text.lowercased().contains("context"))
        #expect(!result.text.lowercased().contains("nan"))
    }

    // MARK: - /memory

    /// `/memory` prints the assembled instructions, including the
    /// absolute-path header of an on-disk `AGENTS.md`.
    @Test
    func memoryPrintsInstructionsWithSourceHeaders() async throws {
        let agentsBody = "Follow the house rules."
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-memory", agentsMarkdown: agentsBody)

        let agentsPath = fixture.cwd
            .appendingPathComponent(InstructionsAssembler.agentsFileName).path
        let result = try await fixture.runCommand("/memory")
        await fixture.close()

        #expect(result.text.contains(agentsPath))
        #expect(result.text.contains(agentsBody))
    }

    // MARK: - /compact

    /// Runs `/compact`, and waits for the terminal entry of its compaction,
    /// which comes from the compaction events after the end of the command.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The streamed text of the command, and the compaction
    ///   updates of its compaction in order.
    /// - Throws: Whatever the prompt or the wait throws.
    private static func compactAndReadTheEntry(
        on fixture: Fixture
    ) async throws -> (text: String, entry: [CompactionUpdate]) {
        let result = try await fixture.runCommand("/compact")
        let updates = try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the terminal compaction entry"
        ) { updates in
            Self.compactionUpdates(in: updates).contains { $0.status != .inProgress }
        }
        return (result.text, Self.compactionUpdates(in: updates))
    }

    /// The compaction updates in a collected sequence, in order.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The compaction updates.
    private static func compactionUpdates(in updates: [UpdateSessionNotification]) -> [CompactionUpdate] {
        updates.compactMap { notification in
            if case .compactionUpdate(let update) = notification.update { return update }
            return nil
        }
    }

    /// The joined text of the summary blocks of an entry.
    ///
    /// - Parameter update: The compaction update.
    /// - Returns: The text.
    private static func summaryText(of update: CompactionUpdate?) -> String {
        guard case .value(let blocks) = update?.summary else { return "" }
        return blocks.map { block in
            guard case .text(let text) = block else { return "" }
            return text.text
        }.joined(separator: "\n")
    }

    /// `/compact` only starts the compaction: its text says so. The completed
    /// entry of the compaction carries the report: the token counts before
    /// and after, and the summarizer model.
    @Test
    func compactReportsTokenCountsAndSummarizerModel() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact",
            loader: CompactionStubBackend.makeLoader(shouldFail: false))

        let (text, entry) = try await Self.compactAndReadTheEntry(on: fixture)
        await fixture.close()
        let report = Self.summaryText(of: entry.last)

        #expect(text.contains("Compaction started."))
        #expect(entry.last?.status == .completed)
        #expect(report.contains("tokens before"))
        #expect(report.contains("tokens after"))
        #expect(report.contains(Self.defaultStandardModel))
    }

    /// A scripted summarizer failure gives a failed entry, not a success:
    /// the error names the failure, and no entry gives token counts.
    @Test
    func compactReportsAFailureHonestly() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact-fail",
            loader: CompactionStubBackend.makeLoader(shouldFail: true))

        let (_, entry) = try await Self.compactAndReadTheEntry(on: fixture)
        await fixture.close()
        let error = try #require(entry.last.flatMap { patchValue($0.error) })

        #expect(entry.last?.status == .failed)
        #expect(error.lowercased().contains("failed"))
        #expect(!Self.summaryText(of: entry.last).contains("tokens after"))
    }

    /// A fold that leaves the context as it was is not reported as a
    /// compaction. The oversized seed does not fit the window of any
    /// summarizer, thus Router gives a shortfall and calls no model, and the
    /// failed entry says that nothing was compacted, and why.
    @Test
    func compactReportsAShortfallHonestly() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact-shortfall",
            loader: CompactionStubBackend.makeLoader(
                shouldFail: false, phraseRepeat: CompactionStubBackend.oversizedPhraseRepeat))

        let (_, entry) = try await Self.compactAndReadTheEntry(on: fixture)
        await fixture.close()
        let error = try #require(entry.last.flatMap { patchValue($0.error) })

        #expect(entry.last?.status == .failed)
        #expect(error.contains("not compacted"))
        #expect(error.contains("does not fit the window of any summarizer"))
        #expect(!error.contains("Compacted the session"))
        #expect(!error.contains(Self.defaultStandardModel))
    }

    /// The check of row 4 of `mailbox.md`, section 8: `/compact` returns at
    /// once. The prompt of the command ends while the summarizer of its
    /// compaction still waits at the gate, and no compaction entry is
    /// terminal then. The compaction is Router work, so the session stays
    /// `running` until it ends: after the gate opens, the completed entry
    /// comes, and then the one `idle` (elicitation-plan task 2).
    @Test
    func compactReturnsBeforeItsCompactionEnds() async throws {
        let gate = SummarizerGate()
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact-at-once",
            loader: CompactionStubBackend.makeLoader(shouldFail: false, gate: gate))

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/compact"))
        await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
        try await gate.waitForArrival(beforeSettleOf: fixture.collector)
        let whileHeld = await fixture.collector.updates
        gate.open()
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(!Self.compactionUpdates(in: whileHeld).contains { $0.status != .inProgress })
        #expect(ScriptedPromptFixture.idleCount(in: whileHeld) == 0)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        let idle = try #require(updates.firstIndex { isIdleState($0.update) })
        let completed = try #require(
            updates.firstIndex { notification in
                if case .compactionUpdate(let update) = notification.update { return update.status == .completed }
                return false
            })
        #expect(completed < idle)
    }

    // MARK: - /config

    /// `/config` prints the effective configuration as YAML: the section keys
    /// and at least one comment line.
    @Test
    func configPrintsYAMLWithSectionsAndComments() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-config")

        let result = try await fixture.runCommand("/config")
        await fixture.close()

        #expect(result.text.contains("profile:"))
        #expect(result.text.contains("tools:"))
        #expect(result.text.contains("recording:"))
        #expect(result.text.contains("#"))
    }

    /// `/config export project` writes `<cwd>/.<name>/config.yaml`, whose
    /// content round-trips through the loader to the same effective
    /// configuration the session was composed from.
    @Test
    func configExportProjectRoundTripsThroughTheLoader() async throws {
        let seededConfig = "recording:\n  level: off\n"
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-export", projectConfigYAML: seededConfig)

        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        let result = try await fixture.runCommand("/config export project")

        let configFile = fixture.cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(ConfigurationLoader.configFileName)
        #expect(FileManager.default.fileExists(atPath: configFile.path))
        #expect(result.text.contains(configFile.path))

        let reloaded = try ConfigurationLoader(
            name: try DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: fixture.cwd,
            userDirectory: fixture.userDirectory,
            environment: [:]
        ).load()
        await fixture.close()
        #expect(reloaded.configuration == entry.configuration)
        #expect(reloaded.configuration.recording.level == .off)
    }

    /// `/config export project` writes no API key value: the file holds
    /// an empty `apiKeys` map, and the confirmation says that the export
    /// wrote no key.
    @Test
    func configExportWritesNoAPIKeyValue() async throws {
        let keyValue = "export-key-value"
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-export-key",
            projectConfigYAML: "tools:\n  web:\n    apiKeys:\n      kagi: \(keyValue)\n")

        let result = try await fixture.runCommand("/config export project")

        let configFile = fixture.cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(ConfigurationLoader.configFileName)
        await fixture.close()
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(!written.contains(keyValue))
        #expect(written.contains("apiKeys: {}"))
        #expect(result.text.contains("tools.web.apiKeys"))
    }

    /// The reference name of the `keychain:` cases.
    private static let referenceName = "builtin-kagi-key"

    /// The value that the store of the `keychain:` cases holds.
    private static let referenceValue = "builtin-secret-value-9d03c4"

    /// A project `config.yaml` that sets the Kagi key as a `keychain:`
    /// reference.
    private static let referenceYAML = "tools:\n  web:\n    apiKeys:\n      kagi: keychain:\(referenceName)\n"

    /// `/config` shows a `keychain:` reference as its reference, and never
    /// the value that the store gives.
    @Test
    func configShowsAReferenceAndNeverItsValue() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-config-reference", projectConfigYAML: Self.referenceYAML,
            secretStore: InMemorySecretStore([Self.referenceName: Self.referenceValue]))

        let result = try await fixture.runCommand("/config")
        await fixture.close()

        #expect(result.text.contains("kagi: \"keychain:\(Self.referenceName)\""))
        #expect(!result.text.contains(Self.referenceValue))
    }

    /// `/config export project` keeps a `keychain:` reference in the file,
    /// because a reference holds no key, and never writes the value.
    @Test
    func configExportKeepsAReferenceAndNeverItsValue() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-export-reference", projectConfigYAML: Self.referenceYAML,
            secretStore: InMemorySecretStore([Self.referenceName: Self.referenceValue]))

        let result = try await fixture.runCommand("/config export project")

        let configFile = fixture.cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(ConfigurationLoader.configFileName)
        await fixture.close()
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written.contains("kagi: \"keychain:\(Self.referenceName)\""))
        #expect(!written.contains(Self.referenceValue))
        #expect(!result.text.contains(Self.referenceValue))
    }

    /// A literal MCP header value of the `keychain:` cases.
    private static let literalHeaderValue = "builtin-literal-header-2c58d1"

    /// A literal MCP env value of the `keychain:` cases, which is not a
    /// secret.
    private static let literalEnvValue = "builtin-literal-env-value"

    /// A project `config.yaml` with one stdio MCP server, the echo mode of
    /// `mcp-test-server`: the `TOKEN` variable is a `keychain:` reference,
    /// and the `MODE` variable is a literal.
    ///
    /// - Returns: The YAML document.
    /// - Throws: When the built `mcp-test-server` product is not found.
    private static func makeMCPEnvYAML() throws -> String {
        """
        tools:
          mcp:
            - name: echoer
              command: \(try BuiltProductLocator.mcpTestServerURL().path)
              args: ["\(ServerMode.flagName)", "\(ServerMode.echo.rawValue)"]
              env:
                TOKEN: keychain:\(referenceName)
                MODE: \(literalEnvValue)
        """
    }

    /// `/config` shows an MCP env reference as its reference and a literal
    /// env value as it is. The value of the store never shows.
    @Test
    func configShowsAnMCPEnvReferenceAndNeverItsValue() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-config-mcp-env", projectConfigYAML: try Self.makeMCPEnvYAML(),
            secretStore: InMemorySecretStore([Self.referenceName: Self.referenceValue]))

        let result = try await fixture.runCommand("/config")
        await fixture.close()

        #expect(result.text.contains("TOKEN: \"keychain:\(Self.referenceName)\""))
        #expect(result.text.contains("MODE: \"\(Self.literalEnvValue)\""))
        #expect(!result.text.contains(Self.referenceValue))
    }

    /// The `/config` text shows an MCP header reference as its reference and
    /// redacts a literal header value. No value shows.
    @Test func theConfigTextRedactsALiteralMCPHeader() throws {
        let configuration = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              mcp:
                - name: remote
                  url: https://example.test/mcp
                  headers:
                    Authorization: keychain:\(Self.referenceName)
                    X-Api-Key: \(Self.literalHeaderValue)
            """,
            secretStore: InMemorySecretStore([Self.referenceName: Self.referenceValue])
        ).configuration

        let text = BuiltinCommands.renderConfiguration(configuration)

        #expect(text.contains("Authorization: \"keychain:\(Self.referenceName)\""))
        #expect(text.contains("X-Api-Key: \"\(ConfiguredSecret.redactedForm)\""))
        #expect(!text.contains(Self.referenceValue))
        #expect(!text.contains(Self.literalHeaderValue))
    }

    /// `/config export project` keeps an MCP env reference in the file and
    /// never writes the value. The confirmation says that the file holds no
    /// literal MCP header value.
    @Test
    func configExportKeepsAnMCPEnvReferenceAndNamesTheHeaders() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-export-mcp-env", projectConfigYAML: try Self.makeMCPEnvYAML(),
            secretStore: InMemorySecretStore([Self.referenceName: Self.referenceValue]))

        let result = try await fixture.runCommand("/config export project")

        let configFile = fixture.cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(ConfigurationLoader.configFileName)
        await fixture.close()
        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written.contains("TOKEN: \"keychain:\(Self.referenceName)\""))
        #expect(!written.contains(Self.referenceValue))
        #expect(!result.text.contains(Self.referenceValue))
        #expect(result.text.contains("tools.mcp headers"))
    }

    /// The emitted YAML round-trips a non-default configuration — a read-only
    /// files body with an exclude list, an stdio `mcp` server with args and
    /// env, extra sandbox write paths and a changed compaction trigger — back
    /// through the loader to the same value, proving the emitter's nested
    /// mapping and sequence forms parse. The exclude list is set, because a
    /// load puts the dotfolder default in for a list that no layer sets.
    @Test func configYAMLRoundTripsANonDefaultConfiguration() throws {
        let changedTrigger = 0.7
        var configuration = AgentConfiguration()
        configuration.tools.files = .enabled(
            FilesToolOptions(readOnly: true, exclude: ["build/", "*.log"]))
        configuration.tools.mcp = .enabled(servers: [
            MCPServerConfiguration(
                name: "svc",
                transport: .stdio(
                    command: "/bin/echo", args: ["--flag"], env: ["KEY": ConfiguredSecret("VALUE")]))
        ])
        configuration.sandbox.extraWritePaths = ["/private/tmp/extra"]
        configuration.compaction.trigger = changedTrigger

        let projectRoot = makeResolvedDirectory(label: "BuiltinCommandsTests-yaml-repo")
        let userDirectory = makeResolvedDirectory(label: "BuiltinCommandsTests-yaml-user")
        let dotfolder = projectRoot.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try ConfigurationYAML.documentText(for: configuration).write(
            to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)

        let reloaded = try ConfigurationLoader(
            name: try DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: projectRoot,
            userDirectory: userDirectory,
            environment: [:]
        ).load()
        #expect(reloaded.configuration == configuration)
    }

    // MARK: - No model pass

    /// The sentinel a scripted model would stream on a model pass. No builtin
    /// output ever carries it, so its absence proves the backend was not
    /// invoked.
    private static let modelSentinel = "SCRIPTED-MODEL-BACKEND-SENTINEL"

    /// None of the six builtins invokes the model backend: a scripted model
    /// that would stream a sentinel on any pass is never reached, so no
    /// builtin's streamed text carries the sentinel.
    @Test
    func noBuiltinInvokesTheModelBackend() async throws {
        for name in Self.builtinNames {
            let fixture = try await Fixture.make(
                label: "BuiltinCommandsTests-no-model-pass-\(name)",
                loader: makeScriptedModelLoader(script: [.textDelta(Self.modelSentinel), .endPass]))
            let result = try await fixture.runCommand("/\(name)")
            #expect(!result.text.contains(Self.modelSentinel))
            #expect(ScriptedPromptFixture.idleStopReason(in: result.updates) == .endTurn)
            await fixture.close()
        }
    }
}

// MARK: - The compaction stub

/// The typed failure the compaction stub's summarizer throws when it is
/// scripted to fail, so a caller-driven `/compact` reports it honestly.
enum CompactionStubError: Error, Equatable {
    /// The summarizer model was scripted to be unavailable.
    case summarizerUnavailable
}

/// A session backend seeded with a large synthetic transcript, so a
/// caller-driven `compact()` runs past the deterministic stages into the
/// model-assisted summarizer. Its `respond` — the call the summarizer makes
/// on a blank-slate clone — either returns a short summary or throws, so the
/// suite drives both the success and the failure of a fold.
///
/// `@unchecked Sendable`: the seed and the two flags are immutable, and the
/// owning `RoutedSession` actor serializes every call.
final class CompactionStubBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The number of passes the seed transcript holds. More than the fold's
    /// four-pass recency window, so an old span remains to summarize.
    private static let seedPassCount = 8

    /// The number of times the seed phrase repeats in one segment.
    ///
    /// The span that the summarizer reads must fit its window: Router counts
    /// with the container's counter (one token per character here) against
    /// the stub window of 32,768 tokens, and a span that does not fit gives a
    /// shortfall and no summarizer call. The span must also be large enough
    /// that the fold needs a summary at all. Measured on 2026-09-23 at that
    /// window: 120 folds with no summary, 160 to 220 call the summarizer.
    /// 180 is the middle of that band.
    static let seedPhraseRepeat = 180

    /// A repeat far past the summarizer window, for the shortfall case.
    static let oversizedPhraseRepeat = 900

    /// The phrase each seeded segment repeats.
    private static let seedPhrase = "context "

    /// The token usage the backend reports, in the pattern of the other stub
    /// backends: a constant, so a usage consumer observes a report.
    private static let seedUsage = (input: 1, output: 1)

    /// The short summary a successful summarizer call returns.
    private static let summaryText = "A short synthesized summary of the earlier prompts."

    /// The seed transcript this backend folds.
    private let entries: [Transcript.Entry]

    /// Whether the summarizer call throws instead of returning a summary.
    private let shouldFail: Bool

    /// The gate that each summarizer call waits at, or `nil` for none.
    private let gate: SummarizerGate?

    /// Creates a seeded backend.
    ///
    /// - Parameters:
    ///   - entries: The seed transcript.
    ///   - shouldFail: Whether the summarizer call throws.
    ///   - gate: The gate that each summarizer call waits at, or `nil`.
    init(entries: [Transcript.Entry], shouldFail: Bool, gate: SummarizerGate? = nil) {
        self.entries = entries
        self.shouldFail = shouldFail
        self.gate = gate
    }

    /// Makes a loader whose LLM containers vend seeded compaction backends.
    ///
    /// - Parameters:
    ///   - shouldFail: Whether each backend's summarizer call throws.
    ///   - phraseRepeat: How many times the seed phrase repeats in one
    ///     segment.
    ///   - gate: The gate that each summarizer call waits at, or `nil`.
    /// - Returns: The loader to inject into the stub agent.
    static func makeLoader(
        shouldFail: Bool, phraseRepeat: Int = seedPhraseRepeat, gate: SummarizerGate? = nil
    ) -> StubModelLoader {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { _ in
            CompactionStubContainer(shouldFail: shouldFail, phraseRepeat: phraseRepeat, gate: gate)
        }
        return loader
    }

    /// The seed transcript: ``seedPassCount`` prompt/response passes, each
    /// segment a repeated phrase large enough to keep the recency window over
    /// the fold target.
    ///
    /// - Parameter phraseRepeat: How many times the phrase repeats in one
    ///   segment.
    /// - Returns: The seed entries, in append order.
    static func makeSeedEntries(phraseRepeat: Int) -> [Transcript.Entry] {
        let segmentText = String(repeating: seedPhrase, count: phraseRepeat)
        var entries: [Transcript.Entry] = []
        for _ in 0..<seedPassCount {
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: segmentText))])))
            entries.append(
                .response(
                    Transcript.Response(segments: [.text(Transcript.TextSegment(content: segmentText))])))
        }
        return entries
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        // Only the summarizer call waits at the gate: its prompt holds the
        // compaction instructions verbatim. Each other model call of the
        // session passes.
        if prompt.contains(CompactionPrompt.default.text) {
            try await gate?.pass()
        }
        if shouldFail {
            throw CompactionStubError.summarizerUnavailable
        }
        return Self.summaryText
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let playback = Task {
                do {
                    continuation.yield(try await respond(to: prompt, maxTokens: maxTokens))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in playback.cancel() }
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: entries, shouldFail: shouldFail, gate: gate)
    }

    /// The summarizer of a compaction calls the blank backend that this
    /// method makes, so the blank backend keeps the gate.
    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail, gate: gate)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        entries
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        Self.seedUsage
    }
}

/// A resident model that hands every session a seeded ``CompactionStubBackend``.
///
/// All four factories are written out, for the reason the fixture file
/// comment of `StubProfileFixtures.swift` states: the public default of
/// `makeSession(instructions:tools:)` drops `tools`.
struct CompactionStubContainer: LoadedLLMContainer {
    /// The counter of a model with no tokenizer: one token per character.
    var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

    /// Whether each vended backend's summarizer call throws.
    let shouldFail: Bool

    /// How many times the seed phrase repeats in one segment.
    let phraseRepeat: Int

    /// The gate that each summarizer call waits at, or `nil` for none.
    var gate: SummarizerGate?

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        CompactionStubBackend(
            entries: CompactionStubBackend.makeSeedEntries(phraseRepeat: phraseRepeat),
            shouldFail: shouldFail, gate: gate)
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        CompactionStubBackend(
            entries: CompactionStubBackend.makeSeedEntries(phraseRepeat: phraseRepeat),
            shouldFail: shouldFail, gate: gate)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail, gate: gate)
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail, gate: gate)
    }
}

/// A gate that the summarizer call of a ``CompactionStubBackend`` waits at,
/// so a test keeps a compaction running in a fixed order, with no clock.
///
/// The test waits until a summarizer call arrived (``waitForArrival(beforeSettleOf:)``),
/// does its work, and then opens the gate (``open()``). A cancel of the
/// summarizer call, for example by `close()`, ends its wait with
/// `CancellationError`.
final class SummarizerGate: Sendable {
    /// The state of the gate.
    private struct State {
        /// Whether the gate is open.
        var isOpen = false

        /// The waits of the summarizer calls, keyed by a token.
        var passes: [Int: CheckedContinuation<Void, any Error>] = [:]

        /// The token of the next wait.
        var nextToken = 0

        /// The number of summarizer calls that arrived.
        var arrivals = 0

        /// The tests that wait for an arrival, keyed by a token.
        var arrivalWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    /// The state, under one lock.
    private let state = Mutex(State())

    /// Waits until the gate opens. Each call counts as one arrival.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled
    ///   first.
    func pass() async throws {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (resumeNow, arrivalWaiters) = state.withLock {
                    state -> (Bool, [CheckedContinuation<Void, any Error>]) in
                    state.arrivals += 1
                    let waiters = Array(state.arrivalWaiters.values)
                    state.arrivalWaiters = [:]
                    if state.isOpen || Task.isCancelled {
                        return (true, waiters)
                    }
                    state.passes[token] = continuation
                    return (false, waiters)
                }
                for waiter in arrivalWaiters {
                    waiter.resume()
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let pass = state.withLock { $0.passes.removeValue(forKey: token) }
            pass?.resume(throwing: CancellationError())
        }
    }

    /// Waits until at least one summarizer call arrived at the gate.
    ///
    /// The compaction keeps the session `running`, so the run cannot settle
    /// before a summarizer call arrives. Thus the settle of the run is the
    /// failure event of this wait (test rule T1): a new idle state update in
    /// `collector` ends the wait, and the wait throws.
    ///
    /// - Parameter collector: The collector of the updates of the session
    ///   that runs the compaction.
    /// - Throws: ``WaitEndedOnFailure`` when the run settled first, and
    ///   ``ConditionWaitCancelled`` when the test is cancelled first.
    func waitForArrival(beforeSettleOf collector: UpdateCollector) async throws {
        let condition = "a summarizer call arrives at the gate"
        let baseline = ScriptedPromptFixture.idleCount(in: await collector.updates)
        let arrived = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await self.waitForAnyArrival(condition: condition)
                return true
            }
            group.addTask {
                _ = try await collector.wait(for: "the run settles") { updates in
                    ScriptedPromptFixture.idleCount(in: updates) > baseline
                }
                return false
            }
            // The first wait that ends decides. The cancel ends the other
            // wait, and the group drops its error.
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard arrived else {
            throw WaitEndedOnFailure(condition: condition, event: "the run settled")
        }
    }

    /// Waits until at least one summarizer call arrived at the gate, or
    /// until the task of the wait is cancelled.
    ///
    /// - Parameter condition: The name of the condition, for the error of a
    ///   cancelled wait.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
    ///   cancelled first.
    private func waitForAnyArrival(condition: String) async throws {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> Result<Void, any Error>? in
                    if state.arrivals > 0 {
                        return .success(())
                    }
                    if Task.isCancelled {
                        return .failure(ConditionWaitCancelled(condition: condition))
                    }
                    state.arrivalWaiters[token] = waiter
                    return nil
                }
                if let outcome {
                    waiter.resume(with: outcome)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.arrivalWaiters.removeValue(forKey: token) }
            waiter?.resume(throwing: ConditionWaitCancelled(condition: condition))
        }
    }

    /// Opens the gate: each waiting summarizer call and each later one
    /// passes.
    func open() {
        let passes = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = true
            let passes = Array(state.passes.values)
            state.passes = [:]
            return passes
        }
        for pass in passes {
            pass.resume()
        }
    }
}
