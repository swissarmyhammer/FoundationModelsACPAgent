import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// Which session one `run` turn speaks to (cli-plan.md §5.4).
enum RunSession {
    /// A fresh session, opened with `session/new` in this directory.
    /// `--cwd` names the directory, and the process working directory is
    /// the default.
    case new(workingDirectory: URL)

    /// A recorded session, continued with `session/load`. `--resume`
    /// names it.
    case resumed(SessionId)
}

/// What one `run` turn gave back.
///
/// The answer itself is not here. It went to the ``AnswerWriter`` chunk
/// by chunk while the turn ran (cli-plan.md §5.6), so the text has one
/// path and no second copy.
struct RunTurnResult {
    /// The stop reason the turn ended on, or `nil` when the wire ended
    /// before an idle update arrived.
    let stopReason: StopReason?
}

/// The refusal of a `--resume` whose id no listed session carries.
///
/// The run refuses by name instead of opening a fresh session, because a
/// silent fresh session would answer a question the person did not ask.
struct UnknownResumedSessionError: Error, CustomStringConvertible {
    /// The id the run asked to continue.
    let sessionId: String

    var description: String {
        "no recorded session carries the id \(sessionId)"
    }
}

/// One `run` turn, in one process, over `InMemoryTransport.pair()`
/// (cli-plan.md §4, §5.4, plan.md §19).
///
/// **The one architecture rule.** The CLI reaches the agent through an
/// ACP connection in every mode, and only the transport changes: this
/// file pairs two in-process ends, and `acp` mode speaks ndJSON on stdin
/// and stdout. The CLI never calls the agent directly. Break the rule and
/// the later socket mode becomes a rewrite, and the CLI stops proving the
/// protocol.
///
/// This is the wiring the Mac app uses as well (plan.md §19): an
/// `AgentSideConnection` on one end, a `ClientSideConnection` on the
/// other, with no pipe and no subprocess.
enum RunTurn {
    /// The client name `initialize` reports to the agent. One binary
    /// stands on both ends of the pair, so the name is the binary's.
    private static let clientName = "acp-agent"

    /// Runs one turn against `composed`, and writes what it said.
    ///
    /// The drive is the protocol's own: `initialize`, then `session/new`
    /// or `session/load`, then `session/prompt`, then the notifications
    /// until a stop reason arrives.
    ///
    /// - Parameters:
    ///   - composed: The composition whose agent serves the agent end.
    ///   - session: The session the turn runs in.
    ///   - prompt: The text of the one turn.
    ///   - writer: The writer each `agent_message_chunk` goes to, as it
    ///     arrives (cli-plan.md §5.6).
    ///   - events: The writer each session event goes to, one line each
    ///     (cli-plan.md §5.7). The default writes nothing, so a caller
    ///     that says nothing about the event lines writes none.
    ///   - install: How the turn gets its `Ctrl-C` watch. The default
    ///     watches nothing, so a caller that says nothing about
    ///     interrupts arms no signal.
    /// - Returns: The stop reason of the turn.
    /// - Throws: ``UnknownResumedSessionError`` when a resumed id is in no
    ///   listing, ``AnswerWriteError`` when a chunk cannot be written,
    ///   and whatever the handshake, the session call or the prompt
    ///   throws.
    static func answer(
        of composed: AgentComposition.Composed,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter = .silent,
        interruptedBy install: InterruptHandler.Installer = InterruptHandler.unwatched
    ) async throws -> RunTurnResult {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await composed.serve(over: agentEnd)
        let client = await SwiftUIACPClient()
        let connection = await client.connect(over: clientEnd)
        // Swift has no asynchronous `defer`, and the wire must come down
        // on the failing path as well, so the outcome is held here and
        // rethrown after the teardown.
        let outcome: Result<RunTurnResult, any Error>
        do {
            outcome = .success(
                try await drive(
                    connection, in: session, prompt: prompt, into: writer,
                    reporting: events, interruptedBy: install))
        } catch {
            outcome = .failure(error)
        }
        await connection.close()
        await agentConnection.close()
        clientEnd.close()
        agentEnd.close()
        return try outcome.get()
    }

    /// Drives the turn over `connection`: the handshake, the session, the
    /// prompt, and the updates until the turn goes idle.
    ///
    /// - Parameters:
    ///   - connection: The client end of the pair.
    ///   - session: The session the turn runs in.
    ///   - prompt: The text of the one turn.
    ///   - writer: The writer each `agent_message_chunk` goes to.
    ///   - events: The writer each session event goes to, one line each.
    ///   - install: How the turn gets its `Ctrl-C` watch.
    /// - Returns: The stop reason of the turn.
    /// - Throws: Whatever the handshake, the session call, the prompt or
    ///   the writer throws.
    private static func drive(
        _ connection: ClientSideConnection,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter,
        interruptedBy install: InterruptHandler.Installer
    ) async throws -> RunTurnResult {
        _ = try await connection.initialize(
            InitializeRequest(
                info: Implementation(name: clientName, version: AgentComposition.version),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities))
        let sessionId = try await open(session, over: connection)
        // Subscribe before the prompt: an update with no subscriber is
        // dropped by the connection's router.
        let updates = connection.updates(for: sessionId)
        let collector = Task {
            try await collect(from: updates, into: writer, reporting: events)
        }
        // The watch is armed here, with a session open and the collector
        // reading: a `session/cancel` that reached the agent before the
        // turn ran would find no active turn and be ignored (§8.6).
        let watch = install()
        let watching = Task {
            await react(to: watch.arrivals, cancelling: sessionId, over: connection)
        }
        let outcome: Result<StopReason?, any Error>
        do {
            _ = try await connection.prompt(
                PromptRequest(prompt: [.text(TextContent(text: prompt))], sessionId: sessionId))
            outcome = .success(try await collector.value)
        } catch {
            collector.cancel()
            // The prompt failure is the one to report, so a write
            // failure the collector met on the way down goes with it.
            _ = try? await collector.value
            outcome = .failure(error)
        }
        watch.disarm()
        watching.cancel()
        return RunTurnResult(stopReason: try outcome.get())
    }

    /// Reacts to each `Ctrl-C` of `arrivals` (cli-plan.md §5.9).
    ///
    /// The first arrival sends `session/cancel`. Nothing is awaited for
    /// it: the notification carries no response, and the `cancelled`
    /// stop reason arrives on the update stream, where the collector
    /// reads it and ends the turn. So the text that already arrived is
    /// on the descriptor, and ``RunCommand`` exits 4.
    ///
    /// Every later arrival ends the process at once. A model whose
    /// generate loop never checks for cancellation runs to its end, and
    /// a person who pressed `Ctrl-C` twice is done waiting.
    ///
    /// A cancel that cannot be sent is dropped: the wire is already
    /// down, so the turn is already ending, and a thrown error here
    /// would replace the turn's own outcome with a teardown detail.
    ///
    /// - Parameters:
    ///   - arrivals: The ordinals of the watch.
    ///   - sessionId: The session to cancel.
    ///   - connection: The client end of the pair.
    static func react(
        to arrivals: AsyncStream<Int>,
        cancelling sessionId: SessionId,
        over connection: ClientSideConnection
    ) async {
        await InterruptHandler.react(to: arrivals) {
            try? await connection.sessionCancel(CancelSessionNotification(sessionId: sessionId))
        }
    }

    /// Opens the session the turn runs in.
    ///
    /// - Parameters:
    ///   - session: The session to open.
    ///   - connection: The client end of the pair.
    /// - Returns: The id of the open session.
    /// - Throws: ``UnknownResumedSessionError`` when a resumed id is in no
    ///   listing, and whatever the session call throws.
    private static func open(
        _ session: RunSession, over connection: ClientSideConnection
    ) async throws -> SessionId {
        switch session {
        case .new(let workingDirectory):
            let response = try await connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: workingDirectory.path)))
            return response.sessionId
        case .resumed(let sessionId):
            // The stored session already has a working directory, and it
            // wins (§5.4). So the run reads that directory off the
            // listing and sends it back: the agent refuses a resume whose
            // `cwd` does not equal the recorded one (plan.md §7.4).
            let cwd = try await recordedWorkingDirectory(of: sessionId, over: connection)
            _ = try await connection.resumeSession(
                ResumeSessionRequest(cwd: cwd, sessionId: sessionId))
            return sessionId
        }
    }

    /// The recorded working directory of `sessionId`, read off the paged
    /// `session/list` surface.
    ///
    /// The listing is unfiltered, because the run knows no directory to
    /// filter by: that is the whole reason `--cwd` is refused beside
    /// `--resume`.
    ///
    /// - Parameters:
    ///   - sessionId: The session to find.
    ///   - connection: The client end of the pair.
    /// - Returns: The recorded working directory.
    /// - Throws: ``UnknownResumedSessionError`` when no page carries the
    ///   id, and whatever the listing call throws.
    private static func recordedWorkingDirectory(
        of sessionId: SessionId, over connection: ClientSideConnection
    ) async throws -> AbsolutePath {
        var cursor: SessionListCursor?
        repeat {
            let page = try await connection.listSessions(ListSessionsRequest(cursor: cursor))
            if let listed = page.sessions.first(where: { $0.sessionId == sessionId }) {
                return listed.cwd
            }
            cursor = page.nextCursor
        } while cursor != nil
        throw UnknownResumedSessionError(sessionId: sessionId.rawValue)
    }

    /// Consumes the session's update stream: writes the text of each
    /// agent message chunk as it arrives, and stops at the first idle
    /// state update.
    ///
    /// One stream feeds two writers. The answer text goes to `writer`, on
    /// stdout (§5.6), and the same update goes to `events`, which writes
    /// one line on stderr when `--verbose` asked for it (§5.7). The event
    /// line goes out first, so the update that ends the turn is reported
    /// before the loop leaves.
    ///
    /// - Parameters:
    ///   - updates: The session's update stream, subscribed before the
    ///     prompt.
    ///   - writer: The writer each chunk goes to.
    ///   - events: The writer each session event goes to, one line each.
    /// - Returns: The stop reason, or `nil` when the stream ended before
    ///   an idle update arrived.
    /// - Throws: ``AnswerWriteError`` when a chunk cannot be written.
    private static func collect(
        from updates: AsyncStream<SessionUpdate>,
        into writer: AnswerWriter,
        reporting events: EventLineWriter
    ) async throws -> StopReason? {
        var events = events
        for await update in updates {
            events.receive(update)
            switch update {
            case .agentMessageChunk(let chunk):
                guard case .text(let content) = chunk.content else { break }
                try writer.receive(content.text)
            case .stateUpdate(.idle(let idle)):
                return idle.stopReason
            default:
                break
            }
        }
        return nil
    }
}
