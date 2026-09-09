import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Tier 3: the agent CLI records what it did (plan.md §4.1)
//
// The suite that spawns the built `acp-agent`, runs one turn, and reads
// the file the process left behind. A test at this level cannot pass on a
// no-op recorder: no fixture stands between the composition and the disk.
//
// It reads `transcript.jsonl` and never `sessions.jsonl`. The index is
// written by this package's own `SessionIndex`, on a path that never
// touches the Router recorder, so it stays correct while every event
// drops.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The name of the file the Router recorder appends each event to.
private let transcriptFileName = "transcript.jsonl"

/// How many sessions one `acp-agent run` opens.
private let sessionsPerRun = 1

/// The recorded transcript of one spawned `acp-agent run`.
struct TranscriptRecordingTests {
    // MARK: - Constants

    /// The prompt of the one turn. The stub model answers with the prompt
    /// it received, so the answer text carries it.
    private static let promptText = "record this turn"

    /// The prompt of the resumed turn. It differs from ``promptText`` so
    /// the recorded file says which turn wrote which line.
    private static let resumedPromptText = "record the second turn too"

    /// The subcommand that runs one turn (cli-plan.md §5.4).
    private static let runSubcommand = "run"

    /// The option that names the working directory of the run.
    private static let workingDirectoryOption = "--cwd"

    /// The option that continues a recorded session (cli-plan.md §5.4).
    private static let resumeOption = "--resume"

    // MARK: - The contract

    /// `acp-agent run` writes the events of its turn to
    /// `<cwd>/.acp-agent/transcripts/<sessionId>/transcript.jsonl`.
    ///
    /// The run opens one session, so the root holds one session directory,
    /// and that directory holds the recorded file.
    @Test(.timeLimit(.minutes(2)))
    func theRunRecordsTheTurnUnderTheProjectTranscriptsRoot() async throws {
        let workspace = makeResolvedDirectory(label: "TranscriptRecording-repo")
        let configHome = makeResolvedDirectory(label: "TranscriptRecording-config")

        let run = try await Self.runAgent(
            arguments: [
                Self.runSubcommand, Self.workingDirectoryOption, workspace.path, Self.promptText,
            ],
            workspace: workspace,
            configHome: configHome)

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        #expect(run.standardOutput.contains(Self.promptText), "stdout: \(run.standardOutput)")
        let root = try Self.recordingRoot(of: workspace)
        let sessionDirectories = try Self.sessionDirectories(under: root)
        #expect(
            sessionDirectories.count == sessionsPerRun,
            "the run left \(sessionDirectories.count) session directories under \(root.path)")
        let file = try #require(sessionDirectories.first)
            .appendingPathComponent(transcriptFileName, isDirectory: false)
        let recorded = try String(contentsOf: file, encoding: .utf8)
        #expect(!recorded.isEmpty, "the recorded transcript at \(file.path) is empty")
        #expect(
            recorded.contains(file.deletingLastPathComponent().lastPathComponent),
            "the recorded events do not name their own session")
    }

    /// `--resume` continues the session the first run recorded: the second
    /// turn runs in the same id, and the recorded file grows.
    ///
    /// The run that resumes carries no `--cwd`, because the stored session
    /// already has a working directory and it wins (cli-plan.md §5.4). The
    /// spawn starts in `workspace`, so the composition reads that stack.
    @Test(.timeLimit(.minutes(2)))
    func resumeContinuesTheSessionTheFirstRunRecorded() async throws {
        let workspace = makeResolvedDirectory(label: "TranscriptRecording-resume-repo")
        let configHome = makeResolvedDirectory(label: "TranscriptRecording-resume-config")
        _ = try await Self.runAgent(
            arguments: [
                Self.runSubcommand, Self.workingDirectoryOption, workspace.path, Self.promptText,
            ],
            workspace: workspace,
            configHome: configHome)
        let root = try Self.recordingRoot(of: workspace)
        let recordedDirectory = try #require(try Self.sessionDirectories(under: root).first)
        let file = recordedDirectory.appendingPathComponent(
            transcriptFileName, isDirectory: false)
        let afterFirstTurn = try String(contentsOf: file, encoding: .utf8)

        let resumed = try await Self.runAgent(
            arguments: [
                Self.runSubcommand, Self.resumeOption, recordedDirectory.lastPathComponent,
                Self.resumedPromptText,
            ],
            workspace: workspace,
            configHome: configHome)

        #expect(resumed.exitCode == 0, "stderr: \(resumed.standardError)")
        #expect(
            resumed.standardOutput.contains(Self.resumedPromptText),
            "stdout: \(resumed.standardOutput)")
        #expect(
            try Self.sessionDirectories(under: root).count == sessionsPerRun,
            "the resumed run opened a second session")
        let afterSecondTurn = try String(contentsOf: file, encoding: .utf8)
        #expect(
            afterSecondTurn.count > afterFirstTurn.count,
            "the resumed turn recorded nothing at \(file.path)")
    }

    // MARK: - The subprocess driver

    /// Runs the built `acp-agent` with the stub model selected.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-agent`.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgent(
        arguments: [String], workspace: URL, configHome: URL
    ) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: arguments,
            workspace: workspace,
            configHome: configHome,
            environment: TierThreeFixture.stubModelEnvironment)
    }

    // MARK: - Reading the recording root

    /// The `project` recording root of `workspace`, the default location
    /// (plan.md §4.1): `<workspace>/.acp-agent/transcripts/`.
    ///
    /// The shared helper builds the path, so this suite and the unit
    /// suites cannot disagree about where a project records.
    ///
    /// - Parameter workspace: The working directory of the run.
    /// - Returns: The recording root.
    private static func recordingRoot(of workspace: URL) throws -> URL {
        try projectRecordingRoot(
            of: workspace, dotfolderName: TierThreeFixture.agentDotfolderName)
    }

    /// The session directories under `root`: the entries that hold a
    /// recorded transcript file.
    ///
    /// - Parameter root: The recording root to read.
    /// - Returns: The session directories, in name order.
    /// - Throws: The directory-read error, when the root itself is absent.
    private static func sessionDirectories(under root: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(transcriptFileName).path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
