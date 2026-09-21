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
// The prompt case runs on the deterministic stub model, because its
// contract is the exit code of a turn that ends, and a small real model
// does not always end a turn. `StdioContractTests` drives the real profile
// and the live loader behind the spawned binary.

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

    // MARK: - The subprocess driver

    /// Runs the built `acp-print` with `arguments` and captures its exit
    /// code, stdout, and stderr, through the shared `BuiltExecutableRun`
    /// driver. The inner `acp-agent` inherits the CLI's environment, so
    /// the injected `configHome` configuration reaches it too.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-print`.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runPrintCLI(
        arguments: [String], workspace: URL, configHome: URL,
        environment: [String: String] = [:]
    ) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.run(
            executableNamed: printExecutableName,
            arguments: arguments,
            workspace: workspace,
            configHome: configHome,
            environment: environment)
    }

    // MARK: - The contract

    /// The one-shot happy path: `acp-print "say hello"` streams the
    /// answer text to stdout, logs to stderr, exits 0 for `end_turn`,
    /// and leaves no agent process behind.
    ///
    /// The turn runs on the deterministic stub model. This case proves the
    /// contract of the CLI for a turn that ends, and only the stub model
    /// always ends a turn. The small real model of the fixture wrote 14 KB
    /// of noise to "say hello" until it reached its token ceiling, and the
    /// agent then reports `_truncated` and the CLI exits nonzero — the
    /// correct answer for that turn, but not the case this test names.
    /// `StdioContractTests` keeps the real profile and the live loader
    /// behind the spawned binary.
    @Test func aTrivialPromptPrintsOnlyTheAnswerAndExitsZero() async throws {
        let workspace = makeResolvedDirectory(label: "ClientServer-repo")
        let configHome = makeResolvedDirectory(label: "ClientServer-config")
        try TierThreeFixture.writeUserConfig(under: configHome)

        let run = try await Self.runPrintCLI(
            arguments: [Self.promptText], workspace: workspace, configHome: configHome,
            environment: TierThreeFixture.stubModelEnvironment)

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        let answer = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!answer.isEmpty, "the answer text is missing from stdout")
        #expect(
            !run.standardOutput.contains(Self.wireMarker),
            "a wire frame leaked onto stdout: \(run.standardOutput)")
        #expect(
            run.standardError.contains(Self.endTurnWireValue),
            "the stop reason is missing from stderr: \(run.standardError)")
        try ProcessCensus.expectNoAgentOutlivedItsRun()
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
        try ProcessCensus.expectNoAgentOutlivedItsRun()
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
