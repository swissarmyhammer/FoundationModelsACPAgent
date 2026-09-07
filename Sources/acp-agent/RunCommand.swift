import ArgumentParser
import Foundation
import FoundationModelsACP

extension AcpAgentCommand {
    /// `acp-agent run <prompt>`: run one turn, and print the answer
    /// (cli-plan.md §5.3). The default subcommand, so a bare prompt
    /// selects it; `run` written out is the script form, which no prompt
    /// word can surprise.
    ///
    /// The turn runs in this process, over `InMemoryTransport.pair()`
    /// (§4): the CLI reaches the agent through an ACP connection, and only
    /// the transport changes between the modes. ``RunTurn`` holds that
    /// drive.
    ///
    /// The options are the whole §5.4 surface, so the parse is final.
    /// `--out-of-process`, `--verbose` and `--quiet` parse here and take
    /// effect with their own cards; this body prints the answer plainly.
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run one turn, and print the answer. This is the default.")

        /// The prompt of the turn (§5.5): the argument when one is given,
        /// stdin when the argument is `-` or absent on a pipe.
        @Argument(
            help: "The prompt of the one turn. `-` reads stdin, and so does no prompt on a piped stdin.")
        var prompt: String?

        /// The `--cwd` option (§5.4, §5.10). It roots the dotfolder stack
        /// and the session, so the CLI applies it before it loads
        /// `config.yaml`.
        @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

        /// The `--cwd` value, or `nil` for the process working directory.
        var workingDirectory: String? {
            workingDirectoryOptions.workingDirectory
        }

        /// The session to continue with `session/load` (§5.4).
        @Option(
            name: .customLong("resume"),
            help: "Continue an existing session with session/load. Default: a new session.")
        var resumeSessionId: String?

        /// Whether a second copy of this binary serves the turn in `acp`
        /// mode over stdio (§5.4), which tests the wire path.
        @Flag(
            name: .customLong("out-of-process"),
            help: "Start a second copy of this binary in acp mode, and speak to it over stdio.")
        var outOfProcess = false

        /// Whether the session events go to stderr, one line each (§5.7).
        @Flag(help: "Write the session events to stderr.")
        var verbose = false

        /// Whether stderr carries nothing but errors, in a terminal too
        /// (§5.7).
        @Flag(help: "Draw no progress and no decoration, in a terminal too.")
        var quiet = false

        /// `--cwd` with `--resume` is a usage error (§5.4): the stored
        /// session already has a working directory, and it wins.
        mutating func validate() throws {
            guard workingDirectory == nil || resumeSessionId == nil else {
                throw ValidationError(
                    "--cwd cannot be combined with --resume: the stored session already has a working directory, and it wins."
                )
            }
        }

        mutating func run() async throws {
            try await report(environment: ProcessInfo.processInfo.environment).write()
        }

        /// Runs the one turn and builds the report: the answer on stdout,
        /// verbatim and with no trailing newline (§5.6), and nothing on
        /// stderr.
        ///
        /// - Parameter environment: The environment the stack reads
        ///   `XDG_CONFIG_HOME` from, and the composition reads the model
        ///   switch from.
        /// - Returns: The report.
        /// - Throws: `ValidationError` when no prompt argument is given,
        ///   and whatever the composition or the turn throws.
        func report(environment: [String: String]) async throws -> CommandReport {
            let text = try promptText()
            let composed = try await compose(environment: environment)
            let result = try await RunTurn.answer(of: composed, in: session, prompt: text)
            return CommandReport(standardOutput: result.answer, standardErrorLines: [])
        }

        /// Composes the agent of this run — the first of the two loads of
        /// §5.10.
        ///
        /// `--cwd` selects WHICH dotfolder stack the loader reads, so it
        /// is applied here, before the configuration load. A run with
        /// `--resume` carries no `--cwd`, so it composes over the process
        /// working directory; the resumed session takes its own layer
        /// from the recorded directory, at `session/load`.
        ///
        /// - Parameter environment: The environment the stack reads
        ///   `XDG_CONFIG_HOME` from, and the composition reads the model
        ///   switch from.
        /// - Returns: The composition.
        /// - Throws: Whatever ``AgentComposition/compose(workingDirectory:environment:)``
        ///   throws.
        func compose(environment: [String: String]) async throws -> AgentComposition.Composed {
            try await AgentComposition.compose(
                workingDirectory: workingDirectoryOptions.directoryURL,
                environment: environment)
        }

        /// The session the turn runs in: the recorded one when `--resume`
        /// names it, and otherwise a fresh session in `--cwd`.
        var session: RunSession {
            guard let resumeSessionId else {
                return .new(workingDirectory: workingDirectoryOptions.directoryURL)
            }
            return .resumed(SessionId(rawValue: resumeSessionId))
        }

        /// The text of the one turn: the prompt argument.
        ///
        /// The stdin rows of the §5.5 source table land with the
        /// prompt-source card. Until then an absent argument is the
        /// table's terminal row, which is a usage error.
        ///
        /// - Returns: The prompt text.
        /// - Throws: `ValidationError` when no prompt argument is given.
        private func promptText() throws -> String {
            guard let prompt else {
                throw ValidationError("a prompt is necessary: give it as the argument.")
            }
            return prompt
        }
    }
}
