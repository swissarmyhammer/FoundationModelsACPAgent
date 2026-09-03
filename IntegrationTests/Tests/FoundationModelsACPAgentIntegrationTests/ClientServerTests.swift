import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Tier 3: the client-server interop contract (plan.md §20.2)
//
// The suite that runs the built `acp-print` example as a subprocess.
// `acp-print` itself spawns `acp-agent` through the client package, so one
// run proves the two role packages interoperate across two real process
// boundaries.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.
//
// The spawned agent resolves a REAL profile with a live loader, so the
// prompt case needs the network on its first run, and the model load can
// take tens of seconds. The known live-model defect ^pez780d can give an
// empty zero-token answer; the assertions here state the card's contract
// and the run reports what the model did.

/// The case's time limit in minutes. It covers the first-run model
/// download and the model load of the spawned agent.
private let spawnedRunTimeLimitMinutes = 20

/// The tier-3 interop contract: run `acp-print` end to end and assert
/// the exit code, the stdout purity, the stderr logs, and the agent
/// reap.
///
/// Serialized so at most one live model turn runs at a time.
@Suite(
    .serialized,
    .timeLimit(.minutes(spawnedRunTimeLimitMinutes)))
struct ClientServerTests {
    // MARK: - Constants

    /// The product name of the one-shot client CLI this suite runs.
    private static let printExecutableName = "acp-print"

    /// The trivial prompt of the live turn.
    private static let promptText = "say hello"

    /// The wire marker that must never appear on `acp-print`'s stdout:
    /// every ndJSON frame carries it, and stdout holds only answer text.
    private static let wireMarker = "\"jsonrpc\""

    /// The stop reason a completed turn logs to stderr.
    private static let endTurnWireValue = "end_turn"

    /// A user-layer `config.yaml` that does not parse. The spawned agent
    /// fails before the wire opens, so the CLI sees a dead agent and must
    /// exit nonzero with the reason on stderr.
    private static let brokenConfigYAML = """
        profile:
          standard: [
        """

    /// The exit status `pgrep` reports when no process matches.
    private static let pgrepNoMatchStatus: Int32 = 1

    // MARK: - The subprocess driver

    /// One finished `acp-print` run: its exit code and its captured
    /// stdout and stderr text.
    private struct CLIRun {
        /// The process exit code.
        let exitCode: Int32

        /// The captured stdout text.
        let standardOutput: String

        /// The captured stderr text.
        let standardError: String
    }

    /// Runs the built `acp-print` with `arguments` and captures its exit
    /// code, stdout, and stderr.
    ///
    /// The run gets `configHome` as `XDG_CONFIG_HOME`. The inner
    /// `acp-agent` inherits the CLI's environment, so the injected
    /// configuration reaches it too.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-print`.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runPrintCLI(
        arguments: [String], workspace: URL, configHome: URL
    ) async throws -> CLIRun {
        let process = Process()
        process.executableURL = try BuiltProductLocator.executableURL(named: printExecutableName)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment[TierThreeFixture.configHomeVariable] = configHome.path
        process.environment = environment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        // Drain the two pipes on their own tasks. A full pipe buffer
        // would block the child, so the reads run before the wait.
        let standardOutputData = Task.detached {
            try standardOutputPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let standardErrorData = Task.detached {
            try standardErrorPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            if !process.isRunning {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
        return CLIRun(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try await standardOutputData.value, as: UTF8.self),
            standardError: String(decoding: try await standardErrorData.value, as: UTF8.self))
    }

    // MARK: - The reap assertion

    /// Asserts that no `acp-agent` process remains after the run: the
    /// client group-killed and reaped the agent it spawned.
    ///
    /// - Throws: The locator or spawn error.
    private static func assertNoAgentProcessRemains() throws {
        let agentPath = try BuiltProductLocator.executableURL(
            named: TierThreeFixture.agentExecutableName
        ).path
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", agentPath]
        pgrep.standardOutput = Pipe()
        try pgrep.run()
        pgrep.waitUntilExit()
        #expect(
            pgrep.terminationStatus == pgrepNoMatchStatus,
            "an acp-agent process remains after the run")
    }

    // MARK: - The contract

    /// The one-shot happy path: `acp-print "say hello"` streams the
    /// answer text to stdout, logs to stderr, exits 0 for `end_turn`,
    /// and leaves no agent process behind.
    @Test func aTrivialPromptPrintsOnlyTheAnswerAndExitsZero() async throws {
        let workspace = makeResolvedDirectory(label: "ClientServer-repo")
        let configHome = makeResolvedDirectory(label: "ClientServer-config")
        try TierThreeFixture.writeUserConfig(under: configHome)

        let run = try await Self.runPrintCLI(
            arguments: [Self.promptText], workspace: workspace, configHome: configHome)

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        let answer = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!answer.isEmpty, "the answer text is missing from stdout")
        #expect(
            !run.standardOutput.contains(Self.wireMarker),
            "a wire frame leaked onto stdout: \(run.standardOutput)")
        #expect(
            run.standardError.contains(Self.endTurnWireValue),
            "the stop reason is missing from stderr: \(run.standardError)")
        try Self.assertNoAgentProcessRemains()
    }

    /// The failure path: an agent that dies before the wire opens makes
    /// the CLI exit nonzero, with the reason on stderr and nothing on
    /// stdout.
    @Test func aDeadAgentExitsNonzeroWithTheReasonOnStderr() async throws {
        let workspace = makeResolvedDirectory(label: "ClientServer-broken-repo")
        let configHome = makeResolvedDirectory(label: "ClientServer-broken-config")
        try TierThreeFixture.writeUserConfig(under: configHome, yaml: Self.brokenConfigYAML)

        let run = try await Self.runPrintCLI(
            arguments: [Self.promptText], workspace: workspace, configHome: configHome)

        #expect(run.exitCode != 0, "a failed turn must not exit 0")
        #expect(
            !run.standardError.isEmpty,
            "the failure reason is missing from stderr")
        #expect(
            run.standardOutput.isEmpty,
            "a failed turn wrote to stdout: \(run.standardOutput)")
        try Self.assertNoAgentProcessRemains()
    }

    /// The argument contract: the CLI takes exactly one positional
    /// prompt. A run with no argument exits nonzero with the usage line
    /// on stderr and writes nothing to stdout.
    @Test func aMissingPromptExitsNonzeroWithUsageOnStderr() async throws {
        let workspace = makeResolvedDirectory(label: "ClientServer-usage-repo")
        let configHome = makeResolvedDirectory(label: "ClientServer-usage-config")

        let run = try await Self.runPrintCLI(
            arguments: [], workspace: workspace, configHome: configHome)

        #expect(run.exitCode != 0, "a usage error must not exit 0")
        #expect(
            run.standardError.contains("usage"),
            "the usage line is missing from stderr: \(run.standardError)")
        #expect(
            run.standardOutput.isEmpty,
            "a usage error wrote to stdout: \(run.standardOutput)")
    }
}
