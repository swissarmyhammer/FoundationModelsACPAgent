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
struct RunTurnResult {
    /// The agent text of the turn, chunks joined in arrival order.
    let answer: String

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

    /// What one turn collected off the update stream.
    private struct CollectedAnswer {
        /// The agent text so far, chunks joined in arrival order.
        var text = ""

        /// The stop reason of the idle update, or `nil` until one
        /// arrives.
        var stopReason: StopReason?
    }

    /// Runs one turn against `composed`, and gives back what it said.
    ///
    /// The drive is the protocol's own: `initialize`, then `session/new`
    /// or `session/load`, then `session/prompt`, then the notifications
    /// until a stop reason arrives.
    ///
    /// - Parameters:
    ///   - composed: The composition whose agent serves the agent end.
    ///   - session: The session the turn runs in.
    ///   - prompt: The text of the one turn.
    /// - Returns: The answer text, and the stop reason of the turn.
    /// - Throws: ``UnknownResumedSessionError`` when a resumed id is in no
    ///   listing, and whatever the handshake, the session call or the
    ///   prompt throws.
    static func answer(
        of composed: AgentComposition.Composed, in session: RunSession, prompt: String
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
            outcome = .success(try await drive(connection, in: session, prompt: prompt))
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
    /// - Returns: The answer text, and the stop reason of the turn.
    /// - Throws: Whatever the handshake, the session call or the prompt
    ///   throws.
    private static func drive(
        _ connection: ClientSideConnection, in session: RunSession, prompt: String
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
        let collector = Task { await collect(from: updates) }
        do {
            _ = try await connection.prompt(
                PromptRequest(prompt: [.text(TextContent(text: prompt))], sessionId: sessionId))
        } catch {
            collector.cancel()
            _ = await collector.value
            throw error
        }
        let collected = await collector.value
        return RunTurnResult(answer: collected.text, stopReason: collected.stopReason)
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

    /// Consumes the session's update stream: joins the text of each agent
    /// message chunk, and stops at the first idle state update.
    ///
    /// - Parameter updates: The session's update stream, subscribed
    ///   before the prompt.
    /// - Returns: The text, and the stop reason, or no stop reason when
    ///   the stream ended before an idle update arrived.
    private static func collect(from updates: AsyncStream<SessionUpdate>) async -> CollectedAnswer {
        var collected = CollectedAnswer()
        for await update in updates {
            switch update {
            case .agentMessageChunk(let chunk):
                guard case .text(let content) = chunk.content else { break }
                collected.text += content.text
            case .stateUpdate(.idle(let idle)):
                collected.stopReason = idle.stopReason
                return collected
            default:
                break
            }
        }
        return collected
    }
}
