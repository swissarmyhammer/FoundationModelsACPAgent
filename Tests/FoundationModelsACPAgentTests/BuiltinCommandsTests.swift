import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The six builtin slash commands (plan.md §14.1, source 1): `/compact`,
/// `/context`, `/memory`, `/status`, `/config` and `/help`. Each streams its
/// text as an `.action` turn, with no model turn. The suite drives them over
/// the harness and asserts the streamed text and the filesystem effects.
struct BuiltinCommandsTests {
    /// The bare names of the six builtins, in registration order.
    private static let builtinNames = ["compact", "context", "memory", "status", "config", "help"]

    /// The default `standard` slot candidate the stub profile resolves. The
    /// `/status` model line and the `/compact` summarizer line both name it.
    private static let defaultStandardModel = "mlx-community/Qwen2.5-14B-Instruct-4bit"

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
        /// - Returns: The wired fixture.
        /// - Throws: Whatever the construction or the handshake throws.
        static func make(
            label: String,
            loader: any ModelLoader = StubModelLoader(),
            projectConfigYAML: String? = nil,
            agentsMarkdown: String? = nil
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
                loader: loader)
            let harness = await AgentClientHarness.makeRecording(agent: agent)
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            let response = try await harness.connection.newSession(
                NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: cwd.path))))
            let collector = try #require(harness.collector)
            return Fixture(
                harness: harness, collector: collector, sessionId: response.sessionId,
                cwd: cwd, userDirectory: userDirectory)
        }

        /// Prompts `command` over the wire, waits for the turn to end, and
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
            let updates = try await ScriptedTurnFixture.waitForIdle(collector)
            return (Self.streamedText(in: updates), updates)
        }

        /// The joined `agent_message_chunk` text of the collected sequence.
        ///
        /// - Parameter updates: The collected notifications.
        /// - Returns: The chunk texts joined in arrival order.
        static func streamedText(in updates: [UpdateSessionNotification]) -> String {
            updates.compactMap { notification in
                guard case .agentMessageChunk(let chunk) = notification.update,
                    case .text(let content) = chunk.content
                else {
                    return nil
                }
                return content.text
            }.joined()
        }
    }

    // MARK: - /help (plan.md §14.1)

    /// `/help` names all six builtins in its streamed output.
    @Test(.timeLimit(.minutes(1)))
    func helpListsAllSixBuiltins() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-help")
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/help")

        for name in Self.builtinNames {
            #expect(result.text.contains("/\(name)"))
        }
    }

    // MARK: - /status (plan.md §14.1)

    /// `/status` names the session id, the cwd, the model, the profile and
    /// the transcript path.
    @Test(.timeLimit(.minutes(1)))
    func statusNamesSessionCwdModelAndTranscript() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-status")
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/status")

        #expect(result.text.contains(fixture.sessionId.rawValue))
        #expect(result.text.contains(fixture.cwd.path))
        #expect(result.text.contains(Self.defaultStandardModel))
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        #expect(result.text.contains(entry.transcriptDirectory.path))
    }

    // MARK: - /context (plan.md §14.1)

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

    /// `/context` before the first model turn streams a line that never
    /// contains the word NaN.
    @Test(.timeLimit(.minutes(1)))
    func contextBeforeAnyTurnNeverPrintsNaN() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-context")
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/context")

        #expect(result.text.lowercased().contains("context"))
        #expect(!result.text.lowercased().contains("nan"))
    }

    // MARK: - /memory (plan.md §14.1, §3.2)

    /// `/memory` prints the assembled instructions, including the
    /// absolute-path header of an on-disk `AGENTS.md`.
    @Test(.timeLimit(.minutes(1)))
    func memoryPrintsInstructionsWithSourceHeaders() async throws {
        let agentsBody = "Follow the house rules."
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-memory", agentsMarkdown: agentsBody)
        defer { Task { await fixture.close() } }

        let agentsPath = fixture.cwd
            .appendingPathComponent(InstructionsAssembler.agentsFileName).path
        let result = try await fixture.runCommand("/memory")

        #expect(result.text.contains(agentsPath))
        #expect(result.text.contains(agentsBody))
    }

    // MARK: - /compact (plan.md §14.1, §8.5)

    /// `/compact` on a session whose fold applies a summary reports the token
    /// counts before and after and names the summarizer model.
    @Test(.timeLimit(.minutes(1)))
    func compactReportsTokenCountsAndSummarizerModel() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact",
            loader: CompactionStubBackend.makeLoader(shouldFail: false))
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/compact")

        #expect(result.text.contains("tokens before"))
        #expect(result.text.contains("tokens after"))
        #expect(result.text.contains(Self.defaultStandardModel))
    }

    /// A scripted summarizer failure makes `/compact` report the failure and
    /// not a success: the streamed text names the failure and no token counts.
    @Test(.timeLimit(.minutes(1)))
    func compactReportsAFailureHonestly() async throws {
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-compact-fail",
            loader: CompactionStubBackend.makeLoader(shouldFail: true))
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/compact")

        #expect(result.text.lowercased().contains("failed"))
        #expect(!result.text.contains("tokens after"))
    }

    // MARK: - /config (plan.md §14.1, §2.2)

    /// `/config` prints the effective configuration as YAML: the section keys
    /// and at least one comment line.
    @Test(.timeLimit(.minutes(1)))
    func configPrintsYAMLWithSectionsAndComments() async throws {
        let fixture = try await Fixture.make(label: "BuiltinCommandsTests-config")
        defer { Task { await fixture.close() } }

        let result = try await fixture.runCommand("/config")

        #expect(result.text.contains("profile:"))
        #expect(result.text.contains("tools:"))
        #expect(result.text.contains("recording:"))
        #expect(result.text.contains("#"))
    }

    /// `/config export project` writes `<cwd>/.<name>/config.yaml`, whose
    /// content round-trips through the loader to the same effective
    /// configuration the session was composed from.
    @Test(.timeLimit(.minutes(1)))
    func configExportProjectRoundTripsThroughTheLoader() async throws {
        let seededConfig = "recording:\n  level: off\n"
        let fixture = try await Fixture.make(
            label: "BuiltinCommandsTests-export", projectConfigYAML: seededConfig)
        defer { Task { await fixture.close() } }

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
        #expect(reloaded.configuration == entry.configuration)
        #expect(reloaded.configuration.recording.level == .off)
    }

    /// The emitted YAML round-trips a non-default configuration — a read-only
    /// files body, an stdio `mcp` server with args and env, extra sandbox
    /// write paths and a changed compaction trigger — back through the loader
    /// to the same value, proving the emitter's nested mapping and sequence
    /// forms parse.
    @Test func configYAMLRoundTripsANonDefaultConfiguration() throws {
        let changedTrigger = 0.7
        var configuration = AgentConfiguration()
        configuration.tools.files = .enabled(FilesToolOptions(readOnly: true))
        configuration.tools.mcp = .enabled(servers: [
            MCPServerConfiguration(
                name: "svc",
                transport: .stdio(command: "/bin/echo", args: ["--flag"], env: ["KEY": "VALUE"]))
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

    // MARK: - No model turn (plan.md §14.3)

    /// The sentinel a scripted model would stream on a model turn. No builtin
    /// output ever carries it, so its absence proves the backend was not
    /// invoked.
    private static let modelSentinel = "SCRIPTED-MODEL-BACKEND-SENTINEL"

    /// None of the six builtins invokes the model backend: a scripted model
    /// that would stream a sentinel on any turn is never reached, so no
    /// builtin's streamed text carries the sentinel.
    @Test(.timeLimit(.minutes(1)))
    func noBuiltinInvokesTheModelBackend() async throws {
        for name in Self.builtinNames {
            let fixture = try await Fixture.make(
                label: "BuiltinCommandsTests-noturn-\(name)",
                loader: makeScriptedModelLoader(script: [.textDelta(Self.modelSentinel), .endTurn]))
            let result = try await fixture.runCommand("/\(name)")
            #expect(!result.text.contains(Self.modelSentinel))
            #expect(ScriptedTurnFixture.idleStopReason(in: result.updates) == .endTurn)
            await fixture.close()
        }
    }
}

// MARK: - The compaction stub (plan.md §20.1)

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
    /// The number of turns the seed transcript holds. More than the fold's
    /// four-turn recency window, so an old span remains to summarize.
    private static let seedTurnCount = 8

    /// The number of times the seed phrase repeats in one segment, sized so
    /// the recency window alone stays over the fold target.
    private static let seedPhraseRepeat = 900

    /// The phrase each seeded segment repeats.
    private static let seedPhrase = "context "

    /// The token usage the backend reports, in the pattern of the other stub
    /// backends: a constant, so a usage consumer observes a report.
    private static let seedUsage = (input: 1, output: 1)

    /// The short summary a successful summarizer call returns.
    private static let summaryText = "A short synthesized summary of the earlier turns."

    /// The seed transcript this backend folds.
    private let entries: [Transcript.Entry]

    /// Whether the summarizer call throws instead of returning a summary.
    private let shouldFail: Bool

    /// Creates a seeded backend.
    ///
    /// - Parameters:
    ///   - entries: The seed transcript.
    ///   - shouldFail: Whether the summarizer call throws.
    init(entries: [Transcript.Entry], shouldFail: Bool) {
        self.entries = entries
        self.shouldFail = shouldFail
    }

    /// Makes a loader whose LLM containers vend seeded compaction backends.
    ///
    /// - Parameter shouldFail: Whether each backend's summarizer call throws.
    /// - Returns: The loader to inject into the stub agent.
    static func makeLoader(shouldFail: Bool) -> StubModelLoader {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { _ in CompactionStubContainer(shouldFail: shouldFail) }
        return loader
    }

    /// The seed transcript: ``seedTurnCount`` prompt/response turns, each
    /// segment a repeated phrase large enough to keep the recency window over
    /// the fold target.
    ///
    /// - Returns: The seed entries, in append order.
    static func makeSeedEntries() -> [Transcript.Entry] {
        let segmentText = String(repeating: seedPhrase, count: seedPhraseRepeat)
        var entries: [Transcript.Entry] = []
        for _ in 0..<seedTurnCount {
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: segmentText))])))
            entries.append(
                .response(
                    Transcript.Response(segments: [.text(Transcript.TextSegment(content: segmentText))])))
        }
        return entries
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
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
        CompactionStubBackend(entries: entries, shouldFail: shouldFail)
    }

    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail)
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
    /// Whether each vended backend's summarizer call throws.
    let shouldFail: Bool

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: CompactionStubBackend.makeSeedEntries(), shouldFail: shouldFail)
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: CompactionStubBackend.makeSeedEntries(), shouldFail: shouldFail)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail)
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        CompactionStubBackend(entries: Array(transcript), shouldFail: shouldFail)
    }
}
