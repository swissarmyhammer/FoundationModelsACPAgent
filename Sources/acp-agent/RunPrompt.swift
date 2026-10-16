import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// Which session one `run` prompt speaks to (cli-plan.md §5.4).
enum RunSession {
    /// A fresh session, opened with `session/new` in this directory.
    /// `--cwd` names the directory, and the process working directory is
    /// the default.
    case new(workingDirectory: URL)

    /// A recorded session, continued with `session/load`. `--resume`
    /// names it.
    case resumed(SessionId)
}

/// What one `run` prompt gave back.
///
/// The answer itself is not here. It went to the ``AnswerWriter`` chunk
/// by chunk while the prompt ran (cli-plan.md §5.6), so the text has one
/// path and no second copy.
struct RunPromptResult {
    /// The stop reason the prompt ended on, or `nil` when the wire ended
    /// before an idle update arrived.
    let stopReason: StopReason?

    /// The pause of the mail delivery that came after the own prompt and
    /// before its ending idle, or `nil` when none came (task ^t03jd5h).
    var mailPause: HeldMailNotice? = nil
}

/// A `_mail_delivery_paused` update that a headless run read (task
/// ^t03jd5h).
///
/// Router held run results of the session and started no answer for them,
/// because too many answers in a row had no caller message. The next caller
/// message would carry them, but a headless run sends no next message, so the
/// results are lost. The run reports it on stderr and exits
/// ``AgentExitCode/mailDeliveryPaused``.
struct HeldMailNotice: Equatable, Sendable {
    /// The `sessionUpdate` value of the update. It is the same text as
    /// `MailDeliveryPauseReport.updateKind` of the agent; `ExitCodeTests`
    /// holds the two side by side.
    static let updateKind = "_mail_delivery_paused"

    /// How many run results the session held.
    let heldCount: Int

    /// The limit in force: the most answers in a row that run mail alone
    /// starts.
    let limit: Int

    /// Reads the notice of one update.
    ///
    /// - Parameter update: The update.
    /// - Returns: The notice, or `nil` when `update` is no
    ///   `_mail_delivery_paused` update, or its payload has no counts.
    init?(_ update: SessionUpdate) {
        guard case .unknown(let kind, .object(let members)) = update, kind == Self.updateKind,
            case .number(let heldCount) = members["heldCount"],
            case .number(let limit) = members["limit"]
        else {
            return nil
        }
        self.heldCount = Int(heldCount)
        self.limit = Int(limit)
    }

    /// Creates a notice.
    ///
    /// - Parameters:
    ///   - heldCount: How many run results the session held.
    ///   - limit: The limit in force.
    init(heldCount: Int, limit: Int) {
        self.heldCount = heldCount
        self.limit = limit
    }

    /// The line that the run writes on stderr, with no line end.
    var standardErrorLine: String {
        """
        acp-agent: the session held \(heldCount) run results and gave no answer for them: \
        \(limit) answers in a row had no caller message. A headless run cannot send the next \
        message, so these results are lost.
        """
    }
}

/// How the collector of a headless prompt ended.
struct CollectedPromptEnd: Sendable {
    /// The stop reason of the ending idle, or `nil` when the update stream
    /// ended before an idle update arrived.
    let stopReason: StopReason?

    /// The pause that came after the own prompt and before its ending idle,
    /// or `nil`.
    let mailPause: HeldMailNotice?
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

/// One `run` prompt, in one process, over `InMemoryTransport.pair()`
/// (cli-plan.md §4, §5.4).
///
/// **The one architecture rule.** The CLI reaches the agent through an
/// ACP connection in every mode, and only the transport changes: this
/// file pairs two in-process ends, and `acp` mode speaks ndJSON on stdin
/// and stdout. The CLI never calls the agent directly. Break the rule and
/// the later socket mode becomes a rewrite, and the CLI stops proving the
/// protocol.
///
/// This is the wiring the Mac app uses as well: an
/// `AgentSideConnection` on one end, a `ClientSideConnection` on the
/// other, with no pipe and no subprocess.
///
/// The drive over the open wire is two steps, and each is its own entry
/// point here because `--out-of-process` arms a `Ctrl-C` watch between
/// them (``OutOfProcessPrompt``). ``handshake(over:)`` is `initialize`, and
/// ``send(over:in:prompt:into:reporting:interruptedBy:terminatedBy:)`` is everything
/// after it. Both modes call the same two, so the two cannot drift apart.
enum RunPrompt {
    /// The client name `initialize` reports to the agent. One binary
    /// stands on both ends of the pair, so the name is the binary's.
    private static let clientName = "acp-agent"

    /// Runs one prompt against `composed`, and writes what it said.
    ///
    /// The drive is the protocol's own: `initialize`, then `session/new`
    /// or `session/load`, then `session/prompt`, then the notifications
    /// until a stop reason arrives.
    ///
    /// - Parameters:
    ///   - composed: The composition whose agent serves the agent end.
    ///   - session: The session the prompt runs in.
    ///   - prompt: The text of the one prompt.
    ///   - writer: The writer each `agent_message_chunk` goes to, as it
    ///     arrives (cli-plan.md §5.6).
    ///   - events: The writer each session event goes to, one line each
    ///     (cli-plan.md §5.7). The default writes nothing, so a caller
    ///     that says nothing about the event lines writes none.
    ///   - install: How the prompt gets its `Ctrl-C` watch. The default
    ///     watches nothing, so a caller that says nothing about
    ///     interrupts arms no signal.
    ///   - terminate: How the prompt gets its `SIGTERM` watch. The default
    ///     watches nothing, so a caller that says nothing about `SIGTERM`
    ///     arms no signal.
    /// - Returns: The stop reason of the prompt.
    /// - Throws: ``UnknownResumedSessionError`` when a resumed id is in no
    ///   listing, ``AnswerWriteError`` when a chunk cannot be written,
    ///   ``TerminationHandler/signalEnd`` when a `SIGTERM` stopped the
    ///   prompt, and whatever the handshake, the session call or the prompt
    ///   throws.
    static func answer(
        of composed: AgentComposition.Composed,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter = .silent,
        interruptedBy install: InterruptHandler.Installer = InterruptHandler.unwatched,
        terminatedBy terminate: TerminationHandler.Installer = TerminationHandler.unwatched
    ) async throws -> RunPromptResult {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await composed.serve(over: agentEnd)
        let model = await ConnectionModel()
        let connection = await model.connect(over: clientEnd)
        // Swift has no asynchronous `defer`, and the wire must come down
        // on the failing path as well, so the outcome is held here and
        // rethrown after the teardown.
        let outcome: Result<RunPromptResult, any Error>
        do {
            try await handshake(over: connection)
            outcome = .success(
                try await send(
                    over: connection, in: session, prompt: prompt, into: writer,
                    reporting: events, interruptedBy: install, terminatedBy: terminate))
        } catch {
            outcome = .failure(error)
        }
        await connection.close()
        await agentConnection.close()
        clientEnd.close()
        agentEnd.close()
        // The run sends no `session/close`, so the agent closes the session
        // itself after the connection closed. The process must not exit
        // before that close wrote the history and stopped the MCP servers.
        await composed.waitForConnectionTeardown()
        return try outcome.get()
    }

    /// The client capabilities that the CLI gives at `initialize`: no
    /// elicitation. The CLI has no UI that can answer a question, so the
    /// agent opens headless sessions, and a tool that asks gets cancel at
    /// once with the reason "no user is present" (elicitation-plan task 6).
    /// ACPClient task 28 makes this an explicit setting of the client later;
    /// until then the CLI does not use `ACPClient.advertisedCapabilities`.
    static let headlessCapabilities = ClientCapabilities()

    /// Sends `initialize` over `connection`, which is the first step of
    /// every drive. It gives ``headlessCapabilities``.
    ///
    /// Out of process this call is also the wait for the agent's own
    /// construction: the spawned binary resolves its profile before it
    /// answers, so a model download stands inside this one `await`. That
    /// is why the handshake is a step of its own, and why
    /// ``OutOfProcessPrompt`` arms a watch around it.
    ///
    /// - Parameter connection: The client end of the wire.
    /// - Throws: Whatever the handshake throws.
    static func handshake(over connection: ClientSideConnection) async throws {
        _ = try await connection.initialize(
            InitializeRequest(
                info: Implementation(name: clientName, version: AgentComposition.version),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: headlessCapabilities))
    }

    /// Sends the prompt over an already handshaken `connection`: the
    /// session, the prompt request, and the updates until the prompt goes
    /// idle.
    ///
    /// - Parameters:
    ///   - connection: The client end of the wire.
    ///   - session: The session the prompt runs in.
    ///   - prompt: The text of the one prompt.
    ///   - writer: The writer each `agent_message_chunk` goes to.
    ///   - events: The writer each session event goes to, one line each.
    ///   - install: How the prompt gets its `Ctrl-C` watch.
    ///   - terminate: How the prompt gets its `SIGTERM` watch. The first
    ///     `SIGTERM` sends `session/cancel`, as the first `Ctrl-C` does.
    /// - Returns: The stop reason of the prompt.
    /// - Throws: ``TerminationHandler/signalEnd`` when a `SIGTERM` stopped
    ///   the prompt, and whatever the session call, the prompt or the writer
    ///   throws.
    static func send(
        over connection: ClientSideConnection,
        in session: RunSession,
        prompt: String,
        into writer: AnswerWriter,
        reporting events: EventLineWriter,
        interruptedBy install: InterruptHandler.Installer,
        terminatedBy terminate: TerminationHandler.Installer
    ) async throws -> RunPromptResult {
        let sessionId = try await open(session, over: connection)
        // Subscribe before the prompt, so the stream holds each update of
        // the prompt in order. The collector also learns the `messageId` of
        // the prompt from the response, on the same input.
        let stream = connection.subscribe(to: sessionId).updates
        let (inputs, input) = AsyncStream.makeStream(of: PromptCollectorInput.self)
        let forwarder = Task {
            for await case .update(let update) in stream {
                input.yield(.update(update))
            }
            input.finish()
        }
        let collector = Task {
            try await collect(from: inputs, into: writer, reporting: events)
        }
        // The watch is armed here, with a session open and the collector
        // reading: a `session/cancel` that reached the agent before the
        // prompt ran would find no active prompt and be ignored.
        let watch = install()
        let watching = Task {
            await react(to: watch.arrivals, cancelling: sessionId, over: connection)
        }
        let outcome: Result<CollectedPromptEnd, any Error>
        do {
            // The `SIGTERM` watch stands for the same span as the `Ctrl-C`
            // watch, for the same reason, and its first arrival sends the
            // same `session/cancel`.
            outcome = .success(
                try await TerminationHandler.run(
                    watchedBy: terminate,
                    stoppingWith: { await cancel(sessionId, over: connection) }
                ) {
                    try await awaitPrompt(
                        prompt, in: sessionId, over: connection, telling: input, collectedBy: collector)
                })
        } catch {
            outcome = .failure(error)
        }
        forwarder.cancel()
        watch.disarm()
        watching.cancel()
        let end = try outcome.get()
        return RunPromptResult(stopReason: end.stopReason, mailPause: end.mailPause)
    }

    /// Sends the prompt request, gives the `messageId` of the response to the
    /// collector, and waits for the collector to read the stop reason.
    ///
    /// - Parameters:
    ///   - prompt: The text of the one prompt.
    ///   - sessionId: The open session the prompt runs in.
    ///   - connection: The client end of the wire.
    ///   - input: The input of the collector.
    ///   - collector: The task that reads the update stream of the session.
    /// - Returns: How the collector ended: the stop reason, or `nil` when the
    ///   update stream ended before an idle update arrived, and the pause of
    ///   the mail delivery, if one came.
    /// - Throws: Whatever the prompt or the collector throws. A prompt
    ///   failure goes out in place of a write failure of the collector.
    private static func awaitPrompt(
        _ prompt: String,
        in sessionId: SessionId,
        over connection: ClientSideConnection,
        telling input: AsyncStream<PromptCollectorInput>.Continuation,
        collectedBy collector: Task<CollectedPromptEnd, any Error>
    ) async throws -> CollectedPromptEnd {
        do {
            let response = try await connection.prompt(
                PromptRequest(prompt: [.text(TextContent(text: prompt))], sessionId: sessionId))
            input.yield(.ownMessage(response.messageId))
            return try await collector.value
        } catch {
            collector.cancel()
            // The prompt failure is the one to report, so a write
            // failure the collector met on the way down goes with it.
            _ = try? await collector.value
            throw error
        }
    }

    /// Sends `session/cancel` for `sessionId`: the stop of the first
    /// `Ctrl-C` and of the first `SIGTERM`.
    ///
    /// Nothing is awaited for it: the notification carries no response, and
    /// the `cancelled` stop reason arrives on the update stream. A cancel
    /// that cannot be sent is dropped: the wire is already down, so the
    /// prompt is already ending, and a thrown error here would replace the
    /// prompt's own outcome with a teardown detail.
    ///
    /// - Parameters:
    ///   - sessionId: The session to cancel.
    ///   - connection: The client end of the wire.
    private static func cancel(_ sessionId: SessionId, over connection: ClientSideConnection) async {
        try? await connection.sessionCancel(CancelSessionNotification(sessionId: sessionId))
    }

    /// Reacts to each `Ctrl-C` of `arrivals` (cli-plan.md §5.9).
    ///
    /// The first arrival sends `session/cancel`. Nothing is awaited for
    /// it: the notification carries no response, and the `cancelled`
    /// stop reason arrives on the update stream, where the collector
    /// reads it and ends the prompt. So the text that already arrived is
    /// on the descriptor, and ``RunCommand`` exits 4.
    ///
    /// Every later arrival ends the process at once. A model whose
    /// generate loop never checks for cancellation runs to its end, and
    /// a person who pressed `Ctrl-C` twice is done waiting.
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
            await cancel(sessionId, over: connection)
        }
    }

    /// Opens the session the prompt runs in.
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
            // wins (cli-plan.md §5.4). So the run reads that directory off
            // the listing and sends it back: the agent refuses a resume
            // whose `cwd` does not equal the recorded one.
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
    /// state update after the `user_message` echo of its own prompt
    /// (elicitation-plan task 43, rule A). An idle means that the session
    /// is not busy any more: no prompt is open and Router has no work. Thus
    /// the own prompt ended, and the CLI also waits for the background runs
    /// that the prompt started. An idle before the own echo belongs to
    /// earlier work of the session.
    ///
    /// One stream feeds two writers. The answer text goes to `writer`, on
    /// stdout (§5.6), and the same update goes to `events`, which writes
    /// one line on stderr when `--verbose` asked for it (§5.7). The event
    /// line goes out first, so the update that ends the prompt is reported
    /// before the loop leaves.
    ///
    /// The collector learns the `messageId` of its own prompt from the
    /// response of the prompt, which can come before or after the echo
    /// (``PromptEndTracker``).
    ///
    /// A `_mail_delivery_paused` update between the own echo and the ending
    /// idle is a pause of the run (task ^t03jd5h): Router holds run results
    /// that no later message of this run carries.
    ///
    /// - Parameters:
    ///   - stream: The session's updates, subscribed before the prompt, and
    ///     the `messageId` of the own prompt.
    ///   - writer: The writer each chunk goes to.
    ///   - events: The writer each session event goes to, one line each.
    /// - Returns: How the collector ended: the stop reason, or `nil` when the
    ///   stream ended before an idle update arrived, and the pause, if one
    ///   came.
    /// - Throws: ``AnswerWriteError`` when a chunk cannot be written.
    private static func collect(
        from stream: AsyncStream<PromptCollectorInput>,
        into writer: AnswerWriter,
        reporting events: EventLineWriter
    ) async throws -> CollectedPromptEnd {
        var events = events
        var tracker = PromptEndTracker()
        for await input in stream {
            switch input {
            case .ownMessage(let messageId):
                tracker.learn(ownMessage: messageId)
            case .update(let update):
                events.receive(update)
                if case .agentMessageChunk(let chunk) = update, case .text(let content) = chunk.content {
                    try writer.receive(content.text)
                }
                tracker.receive(update)
            }
            if tracker.ended {
                return CollectedPromptEnd(stopReason: tracker.stopReason, mailPause: tracker.mailPause)
            }
        }
        return CollectedPromptEnd(stopReason: nil, mailPause: nil)
    }
}

/// One input of the collector of a headless prompt.
enum PromptCollectorInput: Sendable {
    /// One `session/update` of the session.
    case update(SessionUpdate)

    /// The `messageId` of the own prompt, from the `session/prompt` response.
    case ownMessage(MessageId)
}

/// Finds the end of the own prompt of a headless run in the updates of its
/// session (elicitation-plan task 43, rule A): the first `idle` after the
/// `user_message` echo that has the `messageId` of the own prompt.
///
/// The response gives the `messageId`, and the echo comes after the
/// response. The client can read the two in either order, so the tracker
/// keeps the order of the echoes and the idles, and it decides when it has
/// both facts.
struct PromptEndTracker {
    /// One fact of the update stream, in order.
    private enum Mark {
        /// A `user_message` echo with this id.
        case echo(MessageId)

        /// An `idle` with this stop reason.
        case idle(StopReason?)

        /// A `_mail_delivery_paused` update (task ^t03jd5h).
        case pause(HeldMailNotice)
    }

    /// The echoes, the idles and the pauses, in the order of the stream.
    private var marks: [Mark] = []

    /// The `messageId` of the own prompt, or `nil` before the response.
    private var ownMessageId: MessageId?

    /// Records the `messageId` of the own prompt.
    ///
    /// - Parameter messageId: The id that the prompt response gave.
    mutating func learn(ownMessage messageId: MessageId) {
        ownMessageId = messageId
    }

    /// Records one update. Only an echo, an idle and a pause change the
    /// result.
    ///
    /// - Parameter update: The update.
    mutating func receive(_ update: SessionUpdate) {
        switch update {
        case .userMessage(let echo):
            marks.append(.echo(echo.messageId))
        case .stateUpdate(.idle(let idle)):
            marks.append(.idle(idle.stopReason))
        default:
            if let pause = HeldMailNotice(update) {
                marks.append(.pause(pause))
            }
        }
    }

    /// The last pause between the own echo and the ending idle, or `nil`
    /// when none came or the own prompt did not end. A pause before the own
    /// echo belongs to earlier work of the session.
    var mailPause: HeldMailNotice? {
        guard let ownMessageId,
            let echo = marks.firstIndex(where: { if case .echo(ownMessageId) = $0 { true } else { false } })
        else {
            return nil
        }
        var pause: HeldMailNotice?
        for mark in marks[(echo + 1)...] {
            switch mark {
            case .idle:
                return pause
            case .pause(let notice):
                pause = notice
            case .echo:
                break
            }
        }
        return nil
    }

    /// Whether the own prompt ended.
    var ended: Bool {
        endingIdle != nil
    }

    /// The stop reason of the first idle after the own echo, or `nil` while
    /// the own prompt did not end. An idle with no stop reason ends the
    /// prompt too; ``ended`` tells it from a prompt that did not end.
    var stopReason: StopReason? {
        endingIdle ?? nil
    }

    /// The first idle after the own echo: `.some` with its stop reason when
    /// the prompt ended, else `nil`.
    private var endingIdle: StopReason?? {
        guard let ownMessageId,
            let echo = marks.firstIndex(where: { if case .echo(ownMessageId) = $0 { true } else { false } })
        else {
            return nil
        }
        for mark in marks[(echo + 1)...] {
            if case .idle(let stopReason) = mark {
                return .some(stopReason)
            }
        }
        return nil
    }
}
