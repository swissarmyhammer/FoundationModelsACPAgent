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

/// The exit code of an error (cli-plan.md §5.8): `doctor` exits with it
/// when any check fails.
private let errorExitCode: Int32 = 1

/// The process contract of `--help`, `--version`, a usage error and
/// `doctor`.
struct CLIProcessTests {
    // MARK: - Constants

    /// The heading the help text carries.
    private static let usageHeading = "USAGE"

    /// The text `doctor` writes for a profile reference that is not
    /// `owner/name` (cli-plan.md §5.12).
    private static let malformedReferenceMarker = "is not a well formed owner/name reference"

    /// The `doctor` subcommand (cli-plan.md §5.12).
    private static let doctorSubcommand = "doctor"

    /// A user-layer `config.yaml` with one malformed profile reference and
    /// two empty slots.
    ///
    /// The malformed shape fails before any lookup starts — `ProfileDoctor`
    /// looks up only a well formed reference — so this run makes no network
    /// call, and the empty `flash` and `embedding` slots make none either.
    /// That failure is deterministic and reachable with no model and no
    /// network, so it is the one `doctor` exit this suite can assert.
    private static let malformedProfileYAML = """
        profile:
          standard: ["not-well-formed"]
          flash: []
          embedding: []
        """

    /// The number of rows `config path` writes: builtin, user and project.
    private static let layerRowCount = 3

    // MARK: - The subprocess driver

    /// Runs the built `acp-agent` with `arguments` in fresh directories.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-agent`.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root. The default
    ///     makes a fresh, empty directory.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgentCLI(
        arguments: [String], configHome: URL? = nil
    ) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: arguments,
            workspace: makeResolvedDirectory(label: "CLIProcess-repo"),
            configHome: configHome ?? makeResolvedDirectory(label: "CLIProcess-config"))
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

    /// `doctor` finds the malformed profile reference, exits 1, and states
    /// the failure on stderr, with nothing on stdout (cli-plan.md §5.12).
    @Test func aMalformedProfileReferenceMakesDoctorExitOneWithTheFailureOnStderr() async throws {
        let configHome = makeResolvedDirectory(label: "CLIProcess-config")
        try TierThreeFixture.writeUserConfig(under: configHome, yaml: Self.malformedProfileYAML)

        let run = try await Self.runAgentCLI(
            arguments: [Self.doctorSubcommand], configHome: configHome)

        #expect(run.exitCode == errorExitCode, "stderr: \(run.standardError)")
        #expect(
            run.standardError.contains(Self.malformedReferenceMarker),
            "stderr: \(run.standardError)")
        #expect(run.standardOutput.isEmpty, "doctor wrote to stdout: \(run.standardOutput)")
    }

    // MARK: - The config reports (cli-plan.md §5.11)

    /// `config show` writes the merged configuration to stdout, nothing
    /// to stderr, and exits 0.
    @Test func configShowWritesTheConfigurationToStdoutAndExitsZero() async throws {
        let run = try await Self.runAgentCLI(arguments: ["config", "show"])

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        #expect(run.standardOutput.contains("profile:"), "stdout: \(run.standardOutput)")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }

    /// `config path` writes the three layer rows to stdout, nothing to
    /// stderr, and exits 0.
    @Test func configPathWritesTheLayerRowsToStdoutAndExitsZero() async throws {
        let run = try await Self.runAgentCLI(arguments: ["config", "path"])

        #expect(run.exitCode == 0, "stderr: \(run.standardError)")
        let rows = run.standardOutput.split(separator: "\n")
        #expect(rows.count == Self.layerRowCount, "stdout: \(run.standardOutput)")
        #expect(rows.first?.hasPrefix("builtin") == true, "stdout: \(run.standardOutput)")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }
}
