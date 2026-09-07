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
    /// `--verbose` and `--quiet` select the verbosity of stderr (§5.7),
    /// which ``EventLineWriter`` and the download bar each read.
    /// `--out-of-process` parses here and takes effect with its own card.
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

        /// The verbosity of this run's stderr (cli-plan.md §5.7), read off
        /// the two flags of §5.4.
        var eventVerbosity: EventVerbosity {
            EventVerbosity(verbose: verbose, quiet: quiet)
        }

        /// The writer the session event lines go to: the process standard
        /// error, at the verbosity the flags select.
        ///
        /// stderr, and never stdout: the answer of the turn owns file
        /// descriptor 1 (§5.6), and an event line is decoration beside it.
        var eventLineWriter: EventLineWriter {
            EventLineWriter(destination: .standardError, verbosity: eventVerbosity)
        }

        mutating func run() async throws {
            let result = try await perform(
                environment: ProcessInfo.processInfo.environment,
                into: AnswerWriter(),
                reporting: eventLineWriter,
                interruptedBy: InterruptHandler.onSIGINT)
            if let code = Self.exitCode(of: result) {
                throw code
            }
        }

        /// The exit code of a finished turn, or `nil` when the turn ends
        /// the process with 0.
        ///
        /// One row of the §5.8 table stands here: a `cancelled` turn
        /// exits 4, which is what a `Ctrl-C` gives (§5.9). Every other
        /// stop reason keeps exit 0 until the exit-code table card
        /// lands.
        ///
        /// - Parameter result: The finished turn.
        /// - Returns: The code to exit with, or `nil` for a plain end.
        static func exitCode(of result: RunTurnResult) -> ExitCode? {
            guard result.stopReason == .cancelled else {
                return nil
            }
            return ExitCode(InterruptHandler.cancelledExitCode)
        }

        /// Runs the one turn: the prompt by the §5.5 table, and the
        /// answer to `writer` chunk by chunk as it arrives (§5.6).
        ///
        /// stdout carries the answer bytes and nothing else. Not a
        /// session id, not a token count, not a stop reason: those are
        /// stderr's, and they arrive with their own cards.
        ///
        /// - Parameters:
        ///   - environment: The environment the stack reads
        ///     `XDG_CONFIG_HOME` from, and the composition reads the
        ///     model switch from.
        ///   - writer: The writer the answer goes to. `run()` gives the
        ///     one over standard output; a test gives one over a pipe.
        ///   - events: The writer the session event lines go to (§5.7).
        ///     `run()` gives the one over standard error, at the verbosity
        ///     the flags select; the default writes nothing.
        ///   - install: How the composition window and the turn get their
        ///     `Ctrl-C` watch. `run()` gives the real `SIGINT` watch; the
        ///     default watches nothing, so no suite arms a process-wide
        ///     signal. The two windows are armed one after the other and
        ///     never overlap.
        /// - Returns: The stop reason of the turn.
        /// - Throws: `ValidationError` for the terminal row of the §5.5
        ///   table, and whatever the composition, the turn or the writer
        ///   throws.
        func perform(
            environment: [String: String],
            into writer: AnswerWriter,
            reporting events: EventLineWriter = .silent,
            interruptedBy install: InterruptHandler.Installer = InterruptHandler.unwatched
        ) async throws -> RunTurnResult {
            try await perform(
                environment: environment, into: writer, reporting: events,
                interruptedBy: install
            ) {
                try await compose(environment: environment)
            }
        }

        /// Runs the one turn over a supplied composition.
        ///
        /// The composition is a parameter for the same reason the watch is:
        /// `run()` gives the real one, and a test gives one it can hold open
        /// long enough for a scripted `Ctrl-C` to reach it.
        ///
        /// - Parameters:
        ///   - environment: The environment the turn reads.
        ///   - writer: The writer the answer goes to.
        ///   - events: The writer the session event lines go to (§5.7).
        ///   - install: How the composition window and the turn get their
        ///     `Ctrl-C` watch.
        ///   - compose: The composition work to run under the first watch.
        /// - Returns: The stop reason of the turn, or the `cancelled` stop
        ///   reason when the first `Ctrl-C` stopped the composition.
        /// - Throws: `ValidationError` for the terminal row of the §5.5
        ///   table, and whatever the composition, the turn or the writer
        ///   throws.
        func perform(
            environment: [String: String],
            into writer: AnswerWriter,
            reporting events: EventLineWriter = .silent,
            interruptedBy install: InterruptHandler.Installer,
            composedBy compose: @escaping @Sendable () async throws -> AgentComposition.Composed
        ) async throws -> RunTurnResult {
            let text = try promptSource.text()
            let composed: AgentComposition.Composed
            do {
                composed = try await InterruptibleComposition.run(
                    interruptedBy: install, compose)
            } catch is CompositionInterrupted {
                // The wire never opened, so there is no `session/cancel` to
                // send and no answer text to keep. The run reports the
                // `cancelled` stop reason, and `run()` turns that into exit 4
                // (§5.8, §5.9).
                return RunTurnResult(stopReason: .cancelled)
            }
            return try await RunTurn.answer(
                of: composed, in: session, prompt: text, into: writer,
                reporting: events, interruptedBy: install)
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

        /// Where this run takes its prompt from: the §5.5 table, over the
        /// process's own stdin.
        var promptSource: PromptSource {
            PromptSource(argument: prompt)
        }
    }
}
