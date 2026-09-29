import CryptoKit
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

// MARK: - The tool calling gate

/// The proof that the shipped model can call the tools: in one prompt, the
/// model writes a file with the `files` tool and runs a command with the
/// `shell` tool.
///
/// **The disk is the proof.** The model writes `probe.txt` with a marker
/// text. Then it runs `shasum -a 256 probe.txt > probe.sha256`. A model
/// cannot calculate a SHA-256 hash itself, thus a correct hash on the disk
/// shows that the shell ran. The marker in `probe.txt` shows that the file
/// write ran.
///
/// **It is fast because the task is small.** Two tool calls and a short
/// answer: 90 seconds on 2026-09-27, with the model load.
///
/// **It drains the session before it ends.** A settled background run comes
/// back as mail, and the mail can start a new answer after `end_turn`. A
/// generation that still runs on the MLX queue when the process exits
/// crashes it after the test passed. So the test lets the prompt end, calls
/// Router's `drain()` through ``SessionDrain``, and closes the session.
///
/// **It is repeatable because it decodes greedy.** The same model and the
/// same code give the same tool calls in every run. Thus a red gate is a
/// change of the code, of a tool description or of the instructions.
///
/// Run the gate with:
///
/// ```sh
/// swift test --package-path IntegrationTests --filter ToolCallingTests
/// ```
@Suite(
    .serialized,
    .timeLimit(.minutes(15)))
struct ToolCallingTests {
    /// The text the model writes into ``probeFileName``.
    private static let marker = "tool-calling-ok"

    /// The file the `files` tool writes.
    private static let probeFileName = "probe.txt"

    /// The file the `shell` command writes.
    private static let hashFileName = "probe.sha256"

    /// The pause between two looks at the disk and the wire.
    private static let pollInterval: Duration = .milliseconds(100)

    /// How long a run waits for the prompt to end.
    ///
    /// The first run of a process also loads the model. On 2026-09-27 the
    /// whole gate took 90 seconds with that load. The CI machine is
    /// slower: on 2026-09-21 the skill trigger gate took 76 seconds there,
    /// and 15 seconds on a warm machine. 600 seconds stands clear of both.
    /// The deadline is a guard against a hang, not a budget.
    private static let promptDeadline: Duration = .seconds(600)

    /// The user-layer `config.yaml`. The shell is on, because the gate
    /// needs it. The code context is off, because the gate does not need
    /// it and it makes a prompt slower.
    private static var userConfigYAML: String {
        """
        transcripts:
          location: home
        tools:
          shell: true
          codeContext: false
        profile:
          standard: ["\(shippedStandardModel)"]
        """
    }

    /// The standard model the agent ships with. The gate follows a change
    /// of that default with no edit.
    private static var shippedStandardModel: String {
        guard let shipped = ProfileConfiguration.defaultStandard.first?.stringValue else {
            preconditionFailure("ProfileConfiguration.defaultStandard names no model")
        }
        return shipped
    }

    /// The prompt text. It names the two verb paths and the
    /// workspace, so the gate measures the tool calls and not a search for
    /// the tools.
    ///
    /// - Parameter workspace: The session working directory.
    /// - Returns: The prompt.
    private static func prompt(workspace: URL) -> String {
        """
        Do these two steps with the runCode tool, in the workspace \(workspace.path).
        1. With tools.files.write, write the file \(probeFileName) with exactly this \
        content: \(marker)
        2. With tools.shell.execute, run this command in the workspace: \
        shasum -a 256 \(probeFileName) > \(hashFileName)
        Then tell me the hash.
        """
    }

    @Test("The shipped model writes a file and runs a shell command")
    func theShippedModelWritesAFileAndRunsAShellCommand() async throws {
        // Under `swift test`, mlx-swift does not find its shader library
        // beside the test binary. Router's bootstrap symlinks it once per
        // process, and it must run before the first model load.
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = makeResolvedDirectory(label: "ToolCalling-user")
        try Self.userConfigYAML.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let configuration = try ConfigurationLoader(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: userDirectory,
            userDirectory: userDirectory,
            environment: [:]
        ).load().configuration
        let router = Router(
            recordingsDir: makeResolvedDirectory(label: "ToolCalling-recordings"),
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()),
            samplingMode: .greedy)
        let agent = try await RoutedACPAgent(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            router: router,
            configuration: configuration,
            userDirectory: userDirectory,
            environment: [:])
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let collector = try #require(harness.collector)

        let workspace = makeResolvedDirectory(label: "ToolCalling-workspace")
        let session = try await harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        let sessionId = session.sessionId
        let start = ContinuousClock.now
        _ = try await harness.connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: sessionId, text: Self.prompt(workspace: workspace)))
        let stopReason = await Self.waitForIdle(
            collector: collector,
            sessionId: sessionId,
            deadline: ContinuousClock.now + Self.promptDeadline)
        let elapsed = start.duration(to: ContinuousClock.now)
        await harness.flushPendingChunks()
        let titles = await Self.toolTitles(of: collector, sessionId: sessionId)
        let drained = try await SessionDrain.drainAndClose(sessionId, in: harness)
        await harness.close()
        #expect(drained, "the session still had work \(SessionDrain.deadline) after the prompt")

        // The report goes to the reader whether the gate passes or fails.
        let report =
            "TOOL CALLING seconds=\(elapsed.components.seconds) "
            + "stop=\(stopReason.map { "\($0)" } ?? "none") tools=\(titles)"
        print(report)

        #expect(stopReason == .endTurn, "the prompt did not end with end_turn: \(report)")

        let probe = workspace.appendingPathComponent(Self.probeFileName)
        let probeData = try #require(
            FileManager.default.contents(atPath: probe.path),
            "the files tool wrote no \(Self.probeFileName): \(report)")
        let probeText = String(decoding: probeData, as: UTF8.self)
        #expect(
            probeText.trimmingCharacters(in: .whitespacesAndNewlines) == Self.marker,
            "\(Self.probeFileName) holds \"\(probeText)\": \(report)")

        let hashFile = workspace.appendingPathComponent(Self.hashFileName)
        let hashData = try #require(
            FileManager.default.contents(atPath: hashFile.path),
            "the shell tool wrote no \(Self.hashFileName): \(report)")
        let hashText = String(decoding: hashData, as: UTF8.self)
        let expectedHash = SHA256.hash(data: probeData)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(
            hashText.hasPrefix(expectedHash),
            "\(Self.hashFileName) holds \"\(hashText)\", not \(expectedHash): \(report)")
    }

    // MARK: - Waiting

    /// Waits for the idle terminator of one session, or for the deadline.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to watch.
    ///   - deadline: The instant the wait gives up at.
    /// - Returns: The stop reason, or `nil` at the deadline.
    private static func waitForIdle(
        collector: UpdateCollector, sessionId: SessionId, deadline: ContinuousClock.Instant
    ) async -> StopReason? {
        while ContinuousClock.now < deadline {
            let reasons = await collector.updates.compactMap { notification -> StopReason? in
                guard notification.sessionId == sessionId,
                    case .stateUpdate(.idle(let idle)) = notification.update
                else { return nil }
                return idle.stopReason
            }
            if let reason = reasons.last {
                return reason
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    /// The title of every tool call the wire carried for one session. A
    /// failed run says here what the model did instead.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to read.
    /// - Returns: The titles, in wire order.
    private static func toolTitles(
        of collector: UpdateCollector, sessionId: SessionId
    ) async -> [String] {
        await collector.updates.compactMap { notification -> String? in
            guard notification.sessionId == sessionId,
                case .toolCallUpdate(let update) = notification.update,
                case .value(let title) = update.title
            else { return nil }
            return title
        }
    }
}
