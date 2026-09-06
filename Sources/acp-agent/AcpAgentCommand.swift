import ArgumentParser
import Foundation
import FoundationModelsACPAgent

/// # The `acp-agent` CLI: the subcommand tree over this package.
///
/// One binary, every mode (cli-plan.md §4, §5.3): `run` runs one turn
/// and prints the answer, `acp` serves ACP on stdin and stdout, and
/// `config`, `instructions` and `doctor` report on the configuration.
/// `run` is the default subcommand, so `acp-agent "write a haiku"` runs
/// a turn, and `acp-agent run doctor` sends the prompt "doctor" instead
/// of running the check.
///
/// The parser is swift-argument-parser (§5.1): it gives `--help`,
/// `--version`, the tree and the usage errors. The one thing this type
/// adds is the exit code of a usage error, which §5.8 fixes at 2 where
/// the library would exit `EX_USAGE`.
///
/// stdout is data (§5.6): `--help` and `--version` write there, a usage
/// error writes to stderr, and each subcommand writes what its own
/// contract states.
@main
struct AcpAgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp-agent",
        abstract: "A headless coding agent over local models, and an ACP server.",
        version: RoutedACPAgent.buildVersion,
        subcommands: [Run.self, Acp.self, Config.self, Instructions.self, Doctor.self],
        defaultSubcommand: Run.self)

    /// The exit code of a usage error (cli-plan.md §5.8): 2, the code a
    /// script tests for. ArgumentParser's own `validationFailure` is
    /// `EX_USAGE`, so ``exitOutcome(for:)`` maps it here.
    static let usageExitCode: Int32 = 2

    /// How the process ends after `parseAsRoot` or `run()` throws: the
    /// exit code, and whether the message goes to stderr (a failure) or to
    /// stdout (`--help` and `--version`, which exit 0).
    struct ExitOutcome: Equatable {
        /// The process exit code.
        let code: Int32

        /// `true` when the message is an error and belongs on stderr;
        /// `false` when the message is the requested output, on stdout.
        let writesToStandardError: Bool
    }

    /// Maps a thrown error to its exit outcome (cli-plan.md §5.8).
    ///
    /// - Parameter error: The error `parseAsRoot` or `run()` threw.
    /// - Returns: A usage error exits ``usageExitCode`` with its message on
    ///   stderr; a clean exit (`--help`, `--version`) exits 0 with its text
    ///   on stdout; any other error keeps the library's code, on stderr.
    static func exitOutcome(for error: any Error) -> ExitOutcome {
        let code = exitCode(for: error)
        guard code != .validationFailure else {
            return ExitOutcome(code: usageExitCode, writesToStandardError: true)
        }
        return ExitOutcome(code: code.rawValue, writesToStandardError: !code.isSuccess)
    }

    /// The program entry: parse, run, and exit by ``exitOutcome(for:)``.
    ///
    /// The library's own `main()` is not used because it exits a usage
    /// error with `EX_USAGE`. Every other outcome still goes through the
    /// library's `exit(withError:)`, so the help text, the version text
    /// and the error rendering stay the library's.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exitAfterFailure(error)
        }
    }

    /// Exits the process for `error`: a usage error with ``usageExitCode``
    /// and the library's message on stderr; anything else through the
    /// library's `exit(withError:)`.
    ///
    /// - Parameter error: The error `parseAsRoot` or `run()` threw.
    private static func exitAfterFailure(_ error: any Error) -> Never {
        let outcome = exitOutcome(for: error)
        guard outcome.code == usageExitCode else {
            exit(withError: error)
        }
        FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
        Darwin.exit(outcome.code)
    }
}
