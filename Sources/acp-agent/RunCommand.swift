import ArgumentParser

extension AcpAgentCommand {
    /// `acp-agent run <prompt>`: run one turn, and print the answer
    /// (cli-plan.md §5.3). The default subcommand, so a bare prompt
    /// selects it; `run` written out is the script form, which no prompt
    /// word can surprise.
    ///
    /// The options are the whole §5.4 surface, so the parse is final. The
    /// body is a stub until the run card lands: it exits 1.
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run one turn, and print the answer. This is the default.")

        /// The prompt of the turn (§5.5): the argument when one is given,
        /// stdin when the argument is `-` or absent on a pipe.
        @Argument(
            help: "The prompt of the one turn. `-` reads stdin, and so does no prompt on a piped stdin.")
        var prompt: String?

        /// The working directory (§5.4, §5.10). It roots the dotfolder
        /// stack and the session, so the CLI applies it before it loads
        /// `config.yaml`.
        @Option(
            name: .customLong("cwd"),
            help:
                "The working directory. It roots the dotfolder stack and the session. Default: the process working directory."
        )
        var workingDirectory: String?

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
            throw NotImplementedError(command: Self.self)
        }
    }
}
