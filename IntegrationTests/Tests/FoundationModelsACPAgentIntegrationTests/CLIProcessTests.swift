import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Tier 3: the process contract of the agent CLI (cli-plan.md §5)
//
// The suite that runs the built `acp-agent` as a subprocess and reads what
// the process itself did: the exit code, and which stream carried the
// text. The in-process parse suite proves the mapping; this one proves
// the process honors it across a real boundary.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.
//
// No case composes an agent, so no case loads a model or reaches the
// network.

/// The exit code of a usage error (cli-plan.md §5.8).
private let usageExitCode: Int32 = 2

/// The exit code of an error (cli-plan.md §5.8): a stub subcommand body
/// exits with it until its card lands.
private let errorExitCode: Int32 = 1

/// The process contract of `--help`, `--version`, a usage error and a
/// stub subcommand.
@Suite struct CLIProcessTests {
    // MARK: - Constants

    /// The heading the help text carries.
    private static let usageHeading = "USAGE"

    /// The text every stub body writes to stderr.
    private static let notImplementedMarker = "is not implemented yet"

    /// A subcommand whose body is a stub on this card.
    private static let stubSubcommand = "doctor"

    // MARK: - The subprocess driver

    /// Runs the built `acp-agent` with `arguments` in fresh directories.
    ///
    /// - Parameter arguments: The command-line arguments for `acp-agent`.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgentCLI(arguments: [String]) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: arguments,
            workspace: makeResolvedDirectory(label: "CLIProcess-repo"),
            configHome: makeResolvedDirectory(label: "CLIProcess-config"))
    }

    // MARK: - The contract

    /// `--help` prints the usage to stdout, writes nothing to stderr, and
    /// exits 0 (§5.3, §5.6).
    @Test func helpWritesTheUsageToStdoutAndExitsZero() async throws {
        let run = try await Self.runAgentCLI(arguments: ["--help"])

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        #expect(run.standardOutput.contains(Self.usageHeading), "stdout: \(run.standardOutput)")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }

    /// `--version` prints the agent's build version to stdout, and exits
    /// 0 (§5.3, §5.6).
    @Test func versionWritesTheBuildVersionToStdoutAndExitsZero() async throws {
        let run = try await Self.runAgentCLI(arguments: ["--version"])

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        #expect(
            run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == RoutedACPAgent.buildVersion)
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }

    /// An unknown option exits 2 with the usage error on stderr, and
    /// writes nothing to stdout (§5.8).
    @Test func anUnknownOptionExitsTwoWithTheErrorOnStderr() async throws {
        let run = try await Self.runAgentCLI(arguments: ["--no-such-option"])

        #expect(run.exitCode == usageExitCode, "stderr: \(run.standardError)")
        #expect(!run.standardError.isEmpty, "the usage error is missing from stderr")
        #expect(run.standardOutput.isEmpty, "a usage error wrote to stdout: \(run.standardOutput)")
    }

    /// A stub subcommand exits 1 and says so on stderr, with nothing on
    /// stdout.
    @Test func aStubSubcommandExitsOneAndSaysSoOnStderr() async throws {
        let run = try await Self.runAgentCLI(arguments: [Self.stubSubcommand])

        #expect(run.exitCode == errorExitCode, "stderr: \(run.standardError)")
        #expect(
            run.standardError.contains(Self.notImplementedMarker), "stderr: \(run.standardError)")
        #expect(run.standardOutput.isEmpty, "a stub wrote to stdout: \(run.standardOutput)")
    }
}
