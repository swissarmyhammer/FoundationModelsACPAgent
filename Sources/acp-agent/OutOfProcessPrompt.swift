import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// The refusal of an `--out-of-process` run that cannot name its own
/// binary.
///
/// `AgentProcess` requires an absolute path, and the only honest source of
/// one is this process's own executable. A run that cannot read it must say
/// so rather than guess at a path or fall back to the in-process mode,
/// because a silent fall-back would answer a question the person did not
/// ask: the whole point of the flag is the wire.
struct OwnExecutableUnknownError: Error, CustomStringConvertible {
    var description: String {
        "--out-of-process cannot resolve the path of this binary, so it has no agent to start"
    }
}

/// One `run` prompt over a real pipe: a second copy of this binary in `acp`
/// mode, spoken to over its stdio (cli-plan.md §5.4).
///
/// **Only the transport changes.** ``RunPrompt`` pairs two in-process ends,
/// and this file spawns a child and takes the pipe the client package
/// hands back. Everything after the wire is open is the same code — the
/// same handshake, the same prompt — so the two modes cannot answer one
/// prompt differently. That is the claim `--out-of-process` exists to
/// test, and the tier-3 suite reads it byte for byte.
///
/// **The child inherits this process's environment**, because that is what
/// `AgentProcess` gives it. So `ACP_AGENT_STUB_MODEL` and every other
/// setting reach the spawned agent unchanged, and the child then composes
/// its own agent from its own copy of them. It also inherits this
/// process's working directory, which is what roots its start-up
/// configuration; `--cwd` still names the session's directory, and the
/// child obeys that per session, as `acp` mode does for every client
/// (cli-plan.md §5.10).
///
/// **Nothing outlives the run.** `AgentProcess` starts the child in a
/// process group of its own and group-kills and reaps it on `shutdown()`,
/// which stands on the success path, the failing path and the interrupted
/// path alike.
enum OutOfProcessPrompt {
    /// The subcommand the spawned copy runs. Bare `acp-agent` is `run`,
    /// which would read the inherited stdin as a prompt, so the spawn names
    /// this one (cli-plan.md §5.3).
    static let acpSubcommand = "acp"

    /// The absolute path of this binary, which is the agent an
    /// `--out-of-process` run starts.
    ///
    /// `Bundle.main.executableURL` is the same reading `acp-print` makes to
    /// find the agent standing beside it.
    ///
    /// - Returns: The path of this executable.
    /// - Throws: ``OwnExecutableUnknownError`` when the bundle names none.
    static func ownExecutablePath() throws -> String {
        guard let executable = Bundle.main.executableURL else {
            throw OwnExecutableUnknownError()
        }
        return executable.path
    }

    /// Starts a second copy of `command` in `acp` mode, runs one prompt over
    /// its stdio, and reaps it.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the binary to start.
    ///   - session: The session the prompt runs in.
    ///   - prompt: The text of the one prompt.
    ///   - writer: The writer each `agent_message_chunk` goes to, as it
    ///     arrives (cli-plan.md §5.6).
    ///   - events: The writer each session event goes to, one line each
    ///     (cli-plan.md §5.7). The default writes nothing.
    ///   - install: How the two windows of §5.9 get their `Ctrl-C` watch.
    ///     The default watches nothing, so a caller that says nothing about
    ///     interrupts arms no signal.
    ///   - terminate: How the handshake and the prompt get their `SIGTERM`
    ///     watch. The default watches nothing, so a caller that says nothing
    ///     about `SIGTERM` arms no signal.
    /// - Returns: The stop reason of the prompt, or the `cancelled` stop
    ///   reason when the first `Ctrl-C` stopped the child's composition.
    /// - Throws: `AgentProcessError` when the spawn fails,
    ///   ``TerminationHandler/signalEnd`` when a `SIGTERM` stopped the run,
    ///   and whatever the handshake, the session call, the prompt or the
    ///   writer throws.
    static func answer(
        command: String,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter = .silent,
        interruptedBy install: InterruptHandler.Installer = InterruptHandler.unwatched,
        terminatedBy terminate: TerminationHandler.Installer = TerminationHandler.unwatched
    ) async throws -> RunPromptResult {
        let agent = try AgentProcess(command: command, arguments: [acpSubcommand])
        let model = await ConnectionModel()
        // `.disabled` and never stdout: the answer of the prompt owns file
        // descriptor 1 (§5.6). The child writes its own diagnostics to the
        // stderr it inherits.
        let connection = await model.connect(over: agent.transport)
        // Swift has no asynchronous `defer`, and the child must be reaped
        // on the failing path as well, so the outcome is held here and
        // rethrown after the teardown.
        let outcome: Result<RunPromptResult, any Error>
        do {
            outcome = .success(
                try await drive(
                    connection, startedBy: agent, in: session, prompt: prompt,
                    into: writer, reporting: events, interruptedBy: install,
                    terminatedBy: terminate))
        } catch {
            outcome = .failure(error)
        }
        await connection.close()
        agent.shutdown()
        return try outcome.get()
    }

    /// Drives the prompt over the open pipe: the handshake under the
    /// composition watch, then the prompt under its own.
    ///
    /// - Parameters:
    ///   - connection: The client end of the pipe.
    ///   - agent: The spawned child, which the composition watch reaps.
    ///   - session: The session the prompt runs in.
    ///   - prompt: The text of the one prompt.
    ///   - writer: The writer each chunk goes to.
    ///   - events: The writer each session event goes to, one line each.
    ///   - install: How the two windows get their `Ctrl-C` watch.
    ///   - terminate: How the two windows get their `SIGTERM` watch. In the
    ///     handshake the first `SIGTERM` reaps the child, as the first
    ///     `Ctrl-C` does; in the prompt it sends `session/cancel`.
    /// - Returns: The stop reason of the prompt, or `cancelled` when the
    ///   first `Ctrl-C` stopped the child's composition.
    /// - Throws: ``TerminationHandler/signalEnd`` when a `SIGTERM` stopped
    ///   the run, and whatever the handshake, the session call, the prompt
    ///   or the writer throws.
    private static func drive(
        _ connection: ClientSideConnection,
        startedBy agent: AgentProcess,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter,
        interruptedBy install: InterruptHandler.Installer,
        terminatedBy terminate: TerminationHandler.Installer
    ) async throws -> RunPromptResult {
        let shookHands = try await TerminationHandler.run(
            watchedBy: terminate, stoppingWith: { agent.shutdown() }
        ) {
            try await shakeHands(over: connection, with: agent, interruptedBy: install)
        }
        guard shookHands else {
            // The child is gone and no session was ever opened, so there is
            // no `session/cancel` to send and no answer text to keep. The
            // run reports the `cancelled` stop reason, and `run()` changes
            // that into exit 4 (§5.8, §5.9).
            return RunPromptResult(stopReason: .cancelled)
        }
        return try await RunPrompt.send(
            over: connection, in: session, prompt: prompt, into: writer,
            reporting: events, interruptedBy: install, terminatedBy: terminate)
    }

    /// Sends the handshake under the composition watch of this mode.
    ///
    /// This is the first of the two windows of §5.9. The child resolves its
    /// profile before it answers `initialize`, so the download and the
    /// model load stand inside this one `await`. The wire is open but no
    /// session exists, so the reaction is not a `session/cancel`: the run
    /// reaps the child, which ends the download and leaves the part files
    /// in the Hugging Face cache, and which closes the pipe so the awaited
    /// handshake stops rather than waiting for an answer nobody will send.
    ///
    /// Each arrival reaps before it does anything else, because the second
    /// `Ctrl-C` ends this process at once and `_exit(2)` runs no teardown.
    ///
    /// - Parameters:
    ///   - connection: The client end of the pipe.
    ///   - agent: The spawned child to reap.
    ///   - install: How this window gets its `Ctrl-C` watch.
    /// - Returns: `true` when the handshake finished, and `false` when a
    ///   `Ctrl-C` ended the child before it answered.
    /// - Throws: Whatever the handshake throws, unless a `Ctrl-C` is what
    ///   made it throw.
    private static func shakeHands(
        over connection: ClientSideConnection,
        with agent: AgentProcess,
        interruptedBy install: InterruptHandler.Installer
    ) async throws -> Bool {
        let interrupted = ArrivalFlag()
        let watch = install()
        let watching = Task {
            for await ordinal in watch.arrivals {
                interrupted.raise()
                agent.shutdown()
                guard ordinal == InterruptHandler.firstArrival else {
                    InterruptHandler.endAtOnce()
                }
            }
        }
        defer {
            watch.disarm()
            watching.cancel()
        }
        do {
            try await RunPrompt.handshake(over: connection)
        } catch {
            guard interrupted.isRaised else {
                throw error
            }
            return false
        }
        return !interrupted.isRaised
    }
}
