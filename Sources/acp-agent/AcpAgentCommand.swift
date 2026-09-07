import ArgumentParser
import Foundation

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
/// adds is the exit code of a usage error, which ``AgentExitCode/usage``
/// fixes at 2 where the library would exit `EX_USAGE`.
///
/// stdout is data (§5.6): `--help` and `--version` write there, a usage
/// error writes to stderr, and each subcommand writes what its own
/// contract states.
@main
struct AcpAgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp-agent",
        abstract: "A headless coding agent over local models, and an ACP server.",
        version: AgentComposition.version,
        subcommands: [Run.self, Acp.self, Config.self, Instructions.self, Doctor.self],
        defaultSubcommand: Run.self)

    /// How the process ends after `parseAsRoot` or `run()` throws: the
    /// exit code, and whether the message goes to stderr (a failure) or to
    /// stdout (`--help` and `--version`, which exit 0).
    struct ExitOutcome: Equatable {
        /// The process exit code.
        let code: Int32

        /// `true` when the message is an error and belongs on stderr;
        /// `false` when the message is the requested output, on stdout.
        let writesToStandardError: Bool

        /// The outcome of one row of the ``AgentExitCode`` table: its
        /// code, and stderr for every row but 0.
        ///
        /// - Parameter code: The row of the table.
        init(_ code: AgentExitCode) {
            self.init(code: code.rawValue, writesToStandardError: code != .success)
        }

        /// The outcome of a code the ArgumentParser library chose.
        ///
        /// - Parameters:
        ///   - code: The process exit code.
        ///   - writesToStandardError: Whether the message is an error.
        init(code: Int32, writesToStandardError: Bool) {
            self.code = code
            self.writesToStandardError = writesToStandardError
        }
    }

    /// Maps a thrown error to its exit outcome (cli-plan.md §5.8).
    ///
    /// Every code the CLI itself chooses is a row of ``AgentExitCode``,
    /// and a subcommand hands one over as a thrown `ExitCode`, which the
    /// library's `exitCode(for:)` gives back unchanged. The one code this
    /// mapping has to correct is ArgumentParser's own usage failure.
    ///
    /// - Parameter error: The error `parseAsRoot` or `run()` threw.
    /// - Returns: A usage error exits ``AgentExitCode/usage`` with its
    ///   message on stderr; a clean exit (`--help`, `--version`) exits 0
    ///   with its text on stdout; any other error keeps the library's
    ///   code, on stderr.
    static func exitOutcome(for error: any Error) -> ExitOutcome {
        let code = exitCode(for: error)
        guard code != .validationFailure else {
            return ExitOutcome(.usage)
        }
        return ExitOutcome(code: code.rawValue, writesToStandardError: !code.isSuccess)
    }

    /// The program entry: parse, run, and exit by ``exitOutcome(for:)``.
    ///
    /// The library's own `main()` is not used because it exits a usage
    /// error with `EX_USAGE`. The help text, the version text and the
    /// error rendering stay the library's: ``exitAfterFailure(_:)`` writes
    /// `fullMessage(for:)`, and only the stream and the code are this
    /// type's.
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

    /// Exits the process for `error` by its ``exitOutcome(for:)``: the
    /// library's message on the stream the outcome names, then the
    /// outcome's code. An empty message writes nothing, as the library's
    /// `exit(withError:)` does.
    ///
    /// - Parameter error: The error `parseAsRoot` or `run()` threw.
    private static func exitAfterFailure(_ error: any Error) -> Never {
        let outcome = exitOutcome(for: error)
        let message = fullMessage(for: error)
        if !message.isEmpty {
            let stream: FileHandle = outcome.writesToStandardError ? .standardError : .standardOutput
            stream.write(Data((message + "\n").utf8))
        }
        Darwin.exit(outcome.code)
    }
}
