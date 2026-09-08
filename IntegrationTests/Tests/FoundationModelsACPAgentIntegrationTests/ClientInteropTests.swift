import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - Tier 3: the `acp-client` interop contract (cli-plan.md §9)
//
// The suite that runs the built `acp-client` of the client package against
// the built `acp-agent` of this one. `acp-print` already proves that an
// example client can drive this agent; this suite proves it for the
// client package's own CLI, which is the binary a person reaches for.
//
// The two binaries stand in one products directory, because this package
// declares both as product dependencies, so the agent command is an
// absolute path beside the client's own binary.
//
// The run carries `ACP_AGENT_STUB_MODEL=1`, and the spawned agent inherits
// it through `acp-client`. So the answer is deterministic, and the same
// prompt run through `acp-agent run` is the yardstick the client's stdout
// is held to.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The interop contract of `acp-client run … -- acp-agent acp`.
///
/// Serialized so at most one spawned turn runs at a time.
@Suite(.serialized)
struct ClientInteropTests {
    // MARK: - Constants

    /// The product name of the client package's CLI this suite runs.
    private static let clientExecutableName = "acp-client"

    /// The subcommand of `acp-client` that runs one turn.
    private static let runSubcommand = "run"

    /// The separator the agent command follows on the client's command line.
    private static let agentCommandSeparator = "--"

    /// The prompt of the turn. The stub model echoes it, so the answer is
    /// deterministic and is not empty.
    private static let promptText = "the two roles meet on a real pipe"

    /// The wire marker that must never appear on the client's stdout: every
    /// ndJSON frame carries it, and stdout holds only answer text.
    private static let wireMarker = "\"jsonrpc\""

    /// The exit code of a turn that reached its end.
    private static let endTurnExitCode: Int32 = 0

    // MARK: - The subprocess drivers

    /// Runs the built `acp-client` for one turn against the built
    /// `acp-agent`, over the stub model.
    ///
    /// - Parameter label: The directory label, so a leftover directory says
    ///   where it came from.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runClientCLI(label: String) async throws -> BuiltExecutableRun {
        let agentPath = try BuiltProductLocator.executableURL(
            named: TierThreeFixture.agentExecutableName
        ).path
        return try await BuiltExecutableRun.run(
            executableNamed: clientExecutableName,
            arguments: [
                runSubcommand, promptText,
                agentCommandSeparator, agentPath, TierThreeFixture.acpSubcommand,
            ],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: TierThreeFixture.stubModelEnvironment)
    }

    /// Runs the built `acp-agent` for the same turn in process, which is the
    /// yardstick the client's answer is held to.
    ///
    /// - Parameter label: The directory label.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgentCLI(label: String) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: [runSubcommand, promptText],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: TierThreeFixture.stubModelEnvironment)
    }

    // MARK: - The contract

    /// `acp-client run "…" -- acp-agent acp` exits 0, writes the answer and
    /// nothing else to stdout, and leaves no agent process behind.
    ///
    /// The answer is compared after the surrounding whitespace is trimmed
    /// off both sides, because the client completes an answer that does not
    /// end with a newline and the agent CLI writes the chunks verbatim
    /// (cli-plan.md §5.6). The text between is the claim.
    @Test(.timeLimit(.minutes(3)))
    func theClientCLIPrintsOnlyTheAnswerAndLeavesNoAgent() async throws {
        let yardstick = try await Self.runAgentCLI(label: "ClientInterop-yardstick")
        #expect(yardstick.exitCode == Self.endTurnExitCode, "stderr: \(yardstick.standardError)")

        let run = try await Self.runClientCLI(label: "ClientInterop")

        #expect(run.exitCode == Self.endTurnExitCode, "stderr: \(run.standardError)")
        let answer = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!answer.isEmpty, "the answer text is missing from stdout")
        #expect(
            !run.standardOutput.contains(Self.wireMarker),
            "a wire frame leaked onto stdout: \(run.standardOutput)")
        #expect(
            answer == yardstick.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "the client answered something else than the agent did: \(answer)")
        try ProcessCensus.expectNoAgentOutlivedItsRun()
    }
}
