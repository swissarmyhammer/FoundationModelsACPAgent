import ArgumentParser
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The subcommand tree of cli-plan.md §5.3, parsed in process through
/// `AcpAgentCommand.parseAsRoot(_:)`: which subcommand each form selects,
/// the §5.4 options of `run`, and the exit outcome of a usage error, of
/// `--help` and of `--version` (§5.8).
struct CLIParsingTests {
    // MARK: - Constants

    /// The prompt of the bare form, and of the explicit `run` form.
    private static let haikuPrompt = "write a haiku"

    /// The prompt that is also a subcommand name (§5.3).
    private static let doctorPrompt = "doctor"

    /// The `--cwd` value of the options test.
    private static let projectPath = "/tmp/project"

    /// The `--resume` value of the options test.
    private static let sessionIdValue = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// The heading the help text carries.
    private static let usageHeading = "USAGE"

    /// One row of the subcommand table: the arguments, and the command
    /// type the parse must select.
    struct SubcommandRow: CustomStringConvertible {
        /// The command-line arguments, without the binary name.
        let arguments: [String]

        /// The command type the parse selects.
        let selects: any ParsableCommand.Type

        var description: String {
            arguments.joined(separator: " ")
        }
    }

    /// Every form of §5.3, one row each.
    static let subcommandRows: [SubcommandRow] = [
        SubcommandRow(arguments: [haikuPrompt], selects: AcpAgentCommand.Run.self),
        SubcommandRow(arguments: ["run", haikuPrompt], selects: AcpAgentCommand.Run.self),
        SubcommandRow(arguments: ["acp"], selects: AcpAgentCommand.Acp.self),
        SubcommandRow(arguments: ["config", "show"], selects: AcpAgentCommand.Config.Show.self),
        SubcommandRow(arguments: ["config", "init"], selects: AcpAgentCommand.Config.Init.self),
        SubcommandRow(arguments: ["config", "path"], selects: AcpAgentCommand.Config.Path.self),
        SubcommandRow(arguments: ["config", "edit"], selects: AcpAgentCommand.Config.Edit.self),
        SubcommandRow(
            arguments: ["instructions", "eject"], selects: AcpAgentCommand.Instructions.Eject.self),
        SubcommandRow(arguments: ["doctor"], selects: AcpAgentCommand.Doctor.self),
    ]

    // MARK: - Helpers

    /// Parses `arguments` as the root command, runs the selected command
    /// the way `AcpAgentCommand.main()` does, and returns the error either
    /// step threw. `--help` parses into the library's help command and
    /// throws from its `run()`; a usage error throws from the parse.
    ///
    /// - Parameter arguments: The command-line arguments to parse.
    /// - Returns: The thrown error, or `nil` when both steps succeeded.
    private static func outcomeError(of arguments: [String]) async -> (any Error)? {
        do {
            var command = try AcpAgentCommand.parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return nil
        } catch {
            return error
        }
    }

    /// Parses `arguments` and returns the selected `Run` command.
    ///
    /// - Parameter arguments: The command-line arguments to parse.
    /// - Returns: The `Run` command.
    /// - Throws: When the parse fails, or selects another subcommand.
    private static func parseRun(_ arguments: [String]) throws -> AcpAgentCommand.Run {
        try #require(try AcpAgentCommand.parseAsRoot(arguments) as? AcpAgentCommand.Run)
    }

    // MARK: - The subcommand tree (§5.3)

    /// Each form of §5.3 selects its own subcommand: a bare prompt gives
    /// `run`, `acp` gives `acp`, and every reporting form gives its leaf.
    @Test(arguments: subcommandRows)
    func eachFormSelectsItsSubcommand(row: SubcommandRow) throws {
        let command = try AcpAgentCommand.parseAsRoot(row.arguments)

        #expect(ObjectIdentifier(type(of: command)) == ObjectIdentifier(row.selects))
    }

    /// A bare prompt is `run` with that prompt: `run` is the default
    /// subcommand.
    @Test func aBarePromptIsRunWithThatPrompt() throws {
        let run = try Self.parseRun([Self.haikuPrompt])

        #expect(run.prompt == Self.haikuPrompt)
    }

    /// `acp-agent run doctor` is the prompt "doctor", and not the check:
    /// the explicit form resolves a prompt that is a subcommand name.
    @Test func runDoctorIsThePromptDoctorAndNotTheCheck() throws {
        let run = try Self.parseRun(["run", Self.doctorPrompt])

        #expect(run.prompt == Self.doctorPrompt)
    }

    /// `run` is the default: the root configuration names it, so the
    /// parser hands a non-subcommand first argument to it.
    @Test func runIsTheDefaultSubcommand() {
        let defaultSubcommand = AcpAgentCommand.configuration.defaultSubcommand

        #expect(defaultSubcommand.map(ObjectIdentifier.init) == ObjectIdentifier(AcpAgentCommand.Run.self))
    }

    // MARK: - The options of `run` (§5.4)

    /// Every §5.4 option parses onto `Run`, beside the prompt.
    @Test func theRunOptionsParse() throws {
        let run = try Self.parseRun([
            "run", "--cwd", Self.projectPath, "--out-of-process", "--verbose", "--quiet",
            Self.haikuPrompt,
        ])

        #expect(run.workingDirectory == Self.projectPath)
        #expect(run.outOfProcess)
        #expect(run.verbose)
        #expect(run.quiet)
        #expect(run.prompt == Self.haikuPrompt)
        #expect(run.resumeSessionId == nil)
    }

    /// `--resume` parses, and a `run` with no prompt is legal at the
    /// parse: the prompt source table (§5.5) decides later.
    @Test func resumeParsesWithoutAPrompt() throws {
        let run = try Self.parseRun(["run", "--resume", Self.sessionIdValue])

        #expect(run.resumeSessionId == Self.sessionIdValue)
        #expect(run.prompt == nil)
        #expect(run.workingDirectory == nil)
    }

    /// The option defaults: no working directory, no session, and every
    /// flag off.
    @Test func theRunOptionsDefaultOff() throws {
        let run = try Self.parseRun(["run"])

        #expect(run.prompt == nil)
        #expect(run.workingDirectory == nil)
        #expect(run.resumeSessionId == nil)
        #expect(!run.outOfProcess)
        #expect(!run.verbose)
        #expect(!run.quiet)
    }

    /// `--cwd` with `--resume` is a usage error (§5.4): exit 2, on stderr.
    @Test func cwdWithResumeIsAUsageError() async throws {
        let error = try #require(
            await Self.outcomeError(of: [
                "run", "--cwd", Self.projectPath, "--resume", Self.sessionIdValue,
            ]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: AcpAgentCommand.usageExitCode, writesToStandardError: true))
        #expect(!AcpAgentCommand.fullMessage(for: error).isEmpty)
    }

    // MARK: - `acp` declares no `--cwd` (§5.10)

    /// `acp` takes no `--cwd`: the client gives the working directory
    /// with each `session/new`, and a flag would fight the protocol. The
    /// option is therefore unknown on that subcommand, which is a usage
    /// error — exit 2, on stderr — and the parse never reaches the body.
    @Test func cwdOnAcpIsAUsageError() async throws {
        let error = try #require(
            await Self.outcomeError(of: ["acp", "--cwd", Self.projectPath]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: AcpAgentCommand.usageExitCode, writesToStandardError: true))
        #expect(!AcpAgentCommand.fullMessage(for: error).isEmpty)
    }

    // MARK: - The exit outcomes (§5.8)

    /// An unknown option is a usage error: exit 2, with the message on
    /// stderr and nothing on stdout.
    @Test func anUnknownOptionExitsTwoOnStderr() async throws {
        let error = try #require(await Self.outcomeError(of: ["--no-such-option"]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: AcpAgentCommand.usageExitCode, writesToStandardError: true))
        #expect(!AcpAgentCommand.fullMessage(for: error).isEmpty)
    }

    /// The usage exit code is the §5.8 value, and not the library's
    /// `EX_USAGE`.
    @Test func theUsageExitCodeIsTwo() {
        #expect(AcpAgentCommand.usageExitCode == 2)
        #expect(ExitCode.validationFailure.rawValue != AcpAgentCommand.usageExitCode)
    }

    /// `--help` prints the usage to stdout, and exits 0.
    @Test func helpExitsZeroOnStdout() async throws {
        let error = try #require(await Self.outcomeError(of: ["--help"]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(code: 0, writesToStandardError: false))
        #expect(AcpAgentCommand.fullMessage(for: error).contains(Self.usageHeading))
    }

    /// `--version` prints the agent's build version to stdout, and exits
    /// 0. One version: the one `initialize` reports (plan.md §5).
    @Test func versionIsTheAgentBuildVersion() async throws {
        let error = try #require(await Self.outcomeError(of: ["--version"]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(code: 0, writesToStandardError: false))
        #expect(AcpAgentCommand.fullMessage(for: error) == RoutedACPAgent.buildVersion)
        #expect(AcpAgentCommand.configuration.version == RoutedACPAgent.buildVersion)
    }

    /// A stub body exits 1 with its own name on stderr: `doctor` names
    /// `doctor`, and a nested leaf names its leaf.
    @Test func aStubBodyExitsOneWithItsNameOnStderr() async throws {
        let error = try #require(await Self.outcomeError(of: [Self.doctorPrompt]))

        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: ExitCode.failure.rawValue, writesToStandardError: true))
        #expect(AcpAgentCommand.fullMessage(for: error).contains(Self.doctorPrompt))
        #expect(
            NotImplementedError(command: AcpAgentCommand.Config.Show.self).description.contains("show"))
    }
}
