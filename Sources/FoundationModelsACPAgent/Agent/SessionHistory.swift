import Foundation
import FoundationModelsACP

// The retained history of a session (ACP schema-v2.0.0-alpha.7).
//
// `session/resume` replays the "retained history" of the session. A message
// that the agent keeps and replays must keep the id that the client saw
// live. The Router journal cannot give those ids: Router takes the prompt as
// a plain string and makes its own segment ids, and the agent makes the live
// id of each agent message before Router records the entry. After a
// compaction the Router journal also holds a summary in place of the
// messages that it folded. Thus the agent keeps its own history: one
// `SessionMergeEngine` for each session, in the session entry. Each
// `session/update` that the agent sends for the session goes into it, and a
// compaction changes only the model context, never this history. The agent
// writes the history to a file beside the transcript, so a new process can
// replay the same messages with the same ids. The Router journal serves
// only the restore of the model context.

/// The file that keeps the retained history of one session, in the
/// transcript directory of the session (`<recording root>/<sessionId>/`).
///
/// The file holds the history as the session updates that rebuild it: the
/// transcript and the session state, one update for each entry or field,
/// each with its id. Router reads no file in that directory but its own
/// journal, and `session/delete` removes the directory, thus the file goes
/// with the session.
enum SessionHistoryFile {
    /// The name of the file in the transcript directory of the session.
    static let fileName = "session-history.json"

    /// The JSON shape of the file.
    private struct Contents: Codable {
        /// The updates that rebuild the history, in order: the transcript,
        /// then the session state.
        let updates: [SessionUpdate]
    }

    /// Writes `history` to the file in `directory`, and replaces the file
    /// that is there. The directory is made when it does not exist yet: an
    /// action command records nothing in Router, so Router did not make it.
    ///
    /// - Parameters:
    ///   - history: The retained history of the session.
    ///   - directory: The transcript directory of the session.
    /// - Throws: Whatever the encode, the directory or the write throws.
    static func write(_ history: SessionMergeEngine, in directory: URL) throws {
        let contents = Contents(updates: history.transcriptUpdates + history.stateUpdates)
        let data = try JSONEncoder().encode(contents)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(in: directory), options: .atomic)
    }

    /// Reads the history in the file in `directory`.
    ///
    /// - Parameter directory: The transcript directory of the session.
    /// - Returns: The retained history, or `nil` when the directory holds no
    ///   file. A session that an earlier build recorded has no file.
    /// - Throws: Whatever the read or the decode throws.
    static func read(from directory: URL) throws -> SessionMergeEngine? {
        let file = url(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
        return SessionMergeEngine(replaying: contents.updates)
    }

    /// The URL of the file in `directory`.
    ///
    /// - Parameter directory: The transcript directory of the session.
    /// - Returns: The file URL.
    private static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

extension SessionMergeEngine {
    /// Makes the history that `updates` give, in order.
    ///
    /// - Parameter updates: The session updates to merge.
    init(replaying updates: [SessionUpdate]) {
        self.init()
        for update in updates {
            apply(update)
        }
    }

    /// The updates that a `session/resume` replay sends, at or after
    /// `cursor` (plan.md §7.4): the full retained history. Each transcript
    /// entry goes as one whole update with its id, then each state field
    /// that has a value.
    ///
    /// The replay goes out before the resume response. Thus the command
    /// list and the configuration options of the response come last, and
    /// they replace the kept ones at the client.
    ///
    /// - Parameter cursor: Where the replay begins.
    /// - Returns: The updates, in transcript order.
    func replayUpdates(from cursor: ReplayCursor) -> [SessionUpdate] {
        switch cursor {
        case .start:
            return transcriptUpdates + stateUpdates
        }
    }
}

extension RoutedACPAgent {
    /// Merges one update into the retained history of a session. A session
    /// that the table does not hold any more (a `session/delete` removed
    /// it) keeps no history.
    ///
    /// - Parameters:
    ///   - update: The update that the agent sends.
    ///   - sessionId: The session the update belongs to.
    func recordInHistory(_ update: SessionUpdate, of sessionId: SessionId) {
        sessions[sessionId]?.history.apply(update)
    }

    /// The sink of the updates of one session: it merges each update into
    /// the retained history of the session, then sends it through
    /// `connection`. Each `session/update` that the agent sends for a
    /// session goes through one such sink, except the replay of the history
    /// itself.
    ///
    /// The sink keeps the agent and the connection weakly, as the agent
    /// keeps the connection (task `^173qn8n`): the prompt-state owner keeps
    /// the sink in the session entry, and a long-lived task, such as the
    /// terminal projection, keeps it for the life of the session.
    ///
    /// - Parameters:
    ///   - sessionId: The session the updates belong to.
    ///   - connection: The bound connection that sends the updates.
    /// - Returns: The sink.
    nonisolated func historySink(
        for sessionId: SessionId, connection: AgentSideConnection
    ) -> SessionUpdateSink {
        { [weak self, weak connection] update in
            await self?.recordInHistory(update, of: sessionId)
            await connection?.post(update, in: sessionId)
        }
    }

    /// Inserts the prompt of `params` as the user message of its session
    /// (ACP schema-v2.0.0-alpha.7): the retained history gets the
    /// `user_message` echo at once, and the connection sends the echo after
    /// the response to the current request.
    ///
    /// Call it in the handler of the `session/prompt` request, after each
    /// check that can refuse the prompt and before the prompt defers its
    /// work, so the echo goes out before the `running` state.
    ///
    /// - Parameters:
    ///   - params: The prompt request.
    ///   - connection: The bound connection that sends the echo.
    /// - Returns: The id of the user message, for the prompt response.
    func insertUserMessage(_ params: PromptRequest, through connection: AgentSideConnection) -> MessageId {
        if let messageId = sessions[params.sessionId]?.insertUserMessage(params, through: connection) {
            return messageId
        }
        // A `session/delete` can remove the entry while a `.rendered`
        // command renders. The prompt still gets its echo and its id.
        ACPAgentTelemetry.logger(.promptExecution).notice(
            "The session left the table before its prompt was accepted. The user message has no retained history.",
            metadata: ACPAgentTelemetry.sessionMetadata(params.sessionId))
        return connection.insertUserMessage(params)
    }

    /// Writes the retained history of a session to its file
    /// (``SessionHistoryFile``), so a new process can replay it. A history
    /// with no transcript entry writes nothing, so a session with no prompt
    /// leaves no directory. A failed write is logged: the history in the
    /// table stays, and the next write tries again.
    ///
    /// - Parameter sessionId: The session whose history to write.
    func writeHistory(of sessionId: SessionId) {
        guard let entry = sessions[sessionId], !entry.history.entries.isEmpty else {
            return
        }
        do {
            try SessionHistoryFile.write(entry.history, in: entry.transcriptDirectory)
        } catch {
            ACPAgentTelemetry.logger(.session).error(
                "The retained history of a session was not written.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
        }
    }

    /// The retained history of a session that `session/resume` restores:
    /// the history in the table when this process ran the session, else
    /// the history in the file of an earlier process, else an empty
    /// history. The Router journal is never a source: its messages have no
    /// ACP ids, and after a compaction it holds a summary in place of the
    /// messages that it folded. A file that does not read is logged, and
    /// the history starts empty.
    ///
    /// - Parameters:
    ///   - kept: The history in the table, or `nil`.
    ///   - directory: The transcript directory of the session.
    ///   - sessionId: The session, for the log.
    /// - Returns: The retained history.
    func retainedHistory(
        kept: SessionMergeEngine?, directory: URL, sessionId: SessionId
    ) -> SessionMergeEngine {
        if let kept {
            return kept
        }
        do {
            return try SessionHistoryFile.read(from: directory) ?? SessionMergeEngine()
        } catch {
            ACPAgentTelemetry.logger(.sessionResume).error(
                "The retained history of a session did not read. The resume replays no message.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
            return SessionMergeEngine()
        }
    }
}
