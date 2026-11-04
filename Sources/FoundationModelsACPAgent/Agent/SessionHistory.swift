import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

// The retained history of a session (ACP schema-v2.0.0-alpha.7).
//
// `session/resume` replays the "retained history" of the session.
// A message that the agent keeps and replays must keep the id that the client saw live.
// The Router journal cannot give those ids.
// Router takes the prompt as a plain string and makes its own segment ids.
// The agent makes the live id of each agent message before Router records the entry.
// After a compaction the Router journal also holds a summary in place of the messages that it folded.
// Thus the agent keeps its own history: one `SessionMergeEngine` for each session, in the session entry.
// Each `session/update` that the agent sends for the session goes into it.
// A compaction changes only the model context, never this history.
// The agent writes the history to a file beside the transcript.
// So a new process can replay the same messages with the same ids.
// The Router journal serves the restore of the model context.
// It also serves one part of the replay: the plans of the session (task ^jwx92y8).
// A plan has its own id.
// Router writes each plan event to disk at once.
// So a resume merges the recorded plans into the history.

/// The file that keeps the retained history of one session, in the
/// transcript directory of the session (`<recording root>/<sessionId>/`).
///
/// The file holds the history as the session updates that rebuild it.
/// The updates cover the transcript and the session state.
/// There is one update for each entry or field, each with its id.
/// Router reads no file in that directory but its own journal.
/// `session/delete` removes the directory, thus the file goes with the session.
enum SessionHistoryFile {
  /// The name of the file in the transcript directory of the session.
  static let fileName = "session-history.json"

  /// The JSON shape of the file.
  private struct Contents: Codable {
    /// The updates that rebuild the history, in order: the transcript,
    /// then the session state.
    let updates: [SessionUpdate]
  }

  /// Writes `history` to the file in `directory`, and replaces the file that is there.
  /// The directory is made when it does not exist yet.
  /// An action command records nothing in Router, so Router did not make it.
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

/// The retained history of one session, which the session entry and the
/// `user_message` recorder of the connection share.
///
/// `AgentSideConnection.insertUserMessage(_:messageId:into:)` gives the echo
/// to a synchronous `@Sendable` closure.
/// The connection calls that closure on its own dispatch task.
/// It calls the closure after the success response and before the echo goes out.
/// That is after the prompt handler returned.
/// An actor cannot take a synchronous write from that closure, so a `Mutex` keeps the engine.
/// Each write is one locked operation.
/// A read, a change and a write back in two steps can lose an update.
/// The connection can write that update between the steps.
final class RetainedHistory: Sendable {
  /// The merged history, under the lock.
  private let engine: Mutex<SessionMergeEngine>

  /// Makes the shared history over `history`.
  ///
  /// - Parameter history: The first state of the history.
  init(_ history: SessionMergeEngine = SessionMergeEngine()) {
    engine = Mutex(history)
  }

  /// A copy of the history as it is now.
  var snapshot: SessionMergeEngine {
    engine.withLock { $0 }
  }

  /// Merges one update into the history.
  ///
  /// - Parameter update: The update that the agent sends.
  func apply(_ update: SessionUpdate) {
    engine.withLock { _ = $0.apply(update) }
  }

  /// Records the command list and the configuration options of a
  /// `session/new` response.
  ///
  /// - Parameter response: The response.
  func seed(from response: NewSessionResponse) {
    engine.withLock { _ = $0.seed(from: response) }
  }

  /// Records the command list and the configuration options of a
  /// `session/resume` response.
  ///
  /// - Parameter response: The response.
  func seed(from response: ResumeSessionResponse) {
    engine.withLock { _ = $0.seed(from: response) }
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

  /// The current session info that a `session/resume` sync sends. It is
  /// the info that the history folded from the live updates. When the
  /// history has no title, it takes the recorded title. A session that an
  /// earlier build recorded has only that title.
  ///
  /// - Parameter recordedTitle: The title in the Router record of the
  ///   session, or `nil`.
  /// - Returns: The session info update.
  func sessionInfoSyncUpdate(recordedTitle: String?) -> SessionInfoUpdate {
    var info = sessionInfo
    if case .unchanged = info.title, let recordedTitle {
      info.title = .value(recordedTitle)
    }
    return info
  }

  /// The announcements of the children that a `session/resume` replay sends. The history folded
  /// them from the live `subagent_update` updates of the session. A child state in a replay is
  /// history, so the announcement keeps the capabilities out: they are a current fact, and the
  /// current snapshot after the response gives them.
  ///
  /// - Returns: One announcement for each child, in the order of the first announcement.
  var replayAnnouncements: [SessionUpdate] {
    subagents.map { announced in
      var historical = announced
      historical.capabilities = .unchanged
      return .subagentUpdate(historical)
    }
  }

  /// The updates that a `session/resume` replay sends, at or after
  /// `cursor`: the retained history without the announcements of the children
  /// (``replayAnnouncements``). Each transcript entry goes as one whole update with its id,
  /// then each state field that has a value.
  ///
  /// The retained `state_update` is not in the replay. It records a past
  /// state, and a client that gets it would show that state as current
  /// activity. The current state goes out after the replay, from the
  /// ledger of the session (``SessionStateLedger/announceCurrentState()``).
  /// The retained `session_info_update` is not in the replay either. The current one follows
  /// the current state, and a replayed one would come before it.
  ///
  /// The replay goes out before the resume response.
  /// Thus the command list and the configuration options of the response come last.
  /// They replace the kept ones at the client.
  ///
  /// - Parameter cursor: Where the replay begins.
  /// - Returns: The updates, in transcript order.
  func replayUpdates(from cursor: ReplayCursor) -> [SessionUpdate] {
    switch cursor {
    case .start:
      return transcriptUpdates + stateUpdates.filter { $0.isReplayedState }
    }
  }
}

extension SessionMergeEngine {
  /// The update that holds the current state of a listed piece of work: the merged `tool_call`,
  /// `terminal` or `subagent` that the history holds for it.
  ///
  /// - Parameter work: The listed work.
  /// - Returns: The update, or `nil` when the history holds nothing for the work.
  func currentUpdate(of work: FoundationModelsACP.BackgroundWork) -> SessionUpdate? {
    switch work {
    case .toolCall(let call):
      return transcriptUpdates.first { update in
        guard case .toolCallUpdate(let held) = update else { return false }
        return held.toolCallId == call.toolCallId
      }
    case .terminal(let terminal):
      return transcriptUpdates.first { update in
        guard case .terminalUpdate(let held) = update else { return false }
        return held.terminalId == terminal.terminalId
      }
    case .subagent(let child):
      return subagents.first { $0.sessionId == child.sessionId }.map { held in
        // The update goes out before the response. The capabilities are a current fact, and
        // the snapshot after the response gives them.
        var historical = held
        historical.capabilities = .unchanged
        return .subagentUpdate(historical)
      }
    case .unknown:
      return nil
    }
  }
}

extension SessionUpdate {
  /// Whether this update is a `state_update`.
  var isStateUpdate: Bool {
    if case .stateUpdate = self {
      return true
    }
    return false
  }

  /// Whether a replay sends this state update. A replay sends no announcement
  /// (``SessionMergeEngine/replayAnnouncements``), no `state_update` and no
  /// `session_info_update`.
  var isReplayedState: Bool {
    switch self {
    case .stateUpdate, .subagentUpdate, .sessionInfoUpdate:
      return false
    case .userMessageChunk, .userMessage, .agentMessageChunk, .agentMessage, .agentThoughtChunk,
      .agentThought, .toolCallContentChunk, .toolCallUpdate, .terminalUpdate,
      .terminalOutputChunk, .planUpdate, .availableCommandsUpdate, .configOptionUpdate,
      .usageUpdate, .notice, .compactionUpdate, .compactionSummaryChunk, .sessionMessage,
      .sessionMessageChunk, .unknown:
      return true
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
    sessions[sessionId]?.retainedHistory.apply(update)
  }

  /// The sink of the updates of one session.
  /// It merges each update into the retained history of the session.
  /// Then it sends the update through the connection of the session.
  /// It reads the connection from the table when the update goes out
  /// (``ConnectionTable/path(forSession:)``).
  /// Each `session/update` that the agent sends for a session goes through one such sink.
  /// There are two exceptions.
  /// One is the replay of the history itself.
  /// The other is the `_mcp_server_status` report of the MCP servers
  /// (``MCPServerStatusReport``).
  /// That report is a live status and not part of the session history.
  /// So the retained history and a replay never hold it.
  ///
  /// An update can go out while the session has no connection with an outbound path.
  /// It still goes into the history, so a later
  /// `session/resume` replays it.
  /// The update goes to no client, because no client is there to see it.
  ///
  /// The sink keeps the agent weakly.
  /// The table keeps each connection weakly, as the agent keeps the connection (task `^173qn8n`).
  /// The prompt-state owner keeps the sink in the session entry.
  /// A long-lived task, such as the terminal projection, keeps it for the
  /// life of the session.
  /// The sink sends through the connection that it read from the table for this update, strongly for the send.
  ///
  /// A session with a gate (``SessionAnnouncementGate``) keeps each update
  /// in its history, and gives the send to the gate.
  /// The gate sends it when it is open.
  /// An update that goes out before the gate opens waits in the gate.
  /// It goes out in order when the gate opens.
  ///
  /// - Parameters:
  ///   - sessionId: The session the updates belong to.
  ///   - gate: The gate of the session, or `nil` for a session that the
  ///     client knows already.
  /// - Returns: The sink.
  nonisolated func historySink(for sessionId: SessionId, gate: SessionAnnouncementGate? = nil)
    -> SessionUpdateSink
  {
    let posting = unrecordedSink(for: sessionId, gate: gate)
    return { [weak self] update in
      guard let self else {
        return
      }
      await recordInHistory(update, of: sessionId)
      await posting(update)
    }
  }

  /// The sink of a snapshot. It sends through the connection like ``historySink(for:gate:)``,
  /// with the same gate. It records nothing in the retained history. A snapshot of the current
  /// state is no event of the session, so it must not replace the retained state.
  ///
  /// - Parameters:
  ///   - sessionId: The session the updates belong to.
  ///   - gate: The gate of the session, or `nil` for a session that the
  ///     client knows already.
  /// - Returns: The sink.
  nonisolated func unrecordedSink(for sessionId: SessionId, gate: SessionAnnouncementGate? = nil)
    -> SessionUpdateSink
  {
    { [weak self] update in
      await self?.post(update, of: sessionId, through: gate)
    }
  }

  /// Posts one update through the connection of its session. A session with a gate gives the
  /// post to the gate, which keeps it until the client knows the session.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - sessionId: The session the update belongs to.
  ///   - gate: The gate of the session, or `nil` for a session that the client knows already.
  private nonisolated func post(
    _ update: SessionUpdate, of sessionId: SessionId, through gate: SessionAnnouncementGate?
  ) async {
    let send: SessionAnnouncementGate.Send = { [weak self] in
      await self?.connections.path(forSession: sessionId)?.connection.post(update, in: sessionId)
    }
    guard let gate else {
      await send()
      return
    }
    await gate.submit(send)
  }

  /// Inserts the prompt of `params` as the user message of its session
  /// (ACP schema-v2.0.0-alpha.7).
  /// The connection gives the `user_message` echo to the retained history after the success response to the current request.
  /// Then it sends the echo.
  /// After an error response the history and the client get nothing.
  ///
  /// Call it in the handler of the `session/prompt` request.
  /// Call it after each check that can refuse the prompt.
  /// Call it before the prompt defers its work, so the echo goes out before the `running` state.
  ///
  /// - Parameters:
  ///   - params: The prompt request.
  ///   - messageId: The id of the user message.
  ///     It is the description of the `MailID` of a model prompt, or `nil` for a new id.
  ///   - connection: The bound connection that sends the echo.
  /// - Returns: The id of the user message, for the prompt response.
  func insertUserMessage(
    _ params: PromptRequest, messageId: MessageId? = nil, through connection: AgentSideConnection
  ) -> MessageId {
    if let messageId = sessions[params.sessionId]?.insertUserMessage(
      params, messageId: messageId, through: connection)
    {
      return messageId
    }
    // A `session/delete` can remove the entry while a `.rendered`
    // command renders. The prompt still gets its echo and its id.
    ACPAgentTelemetry.logger(.promptExecution).notice(
      "The session left the table before its prompt was accepted. The user message has no retained history.",
      metadata: ACPAgentTelemetry.sessionMetadata(params.sessionId))
    return connection.insertUserMessage(params, messageId: messageId)
  }

  /// Writes the retained history of a session to its file
  /// (``SessionHistoryFile``), so a new process can replay it.
  /// A history with no transcript entry writes nothing, so a session with no prompt leaves no directory.
  /// A replay-only session writes nothing either.
  /// It ran no prompt, so its file stays as the session that ran left it.
  /// A failed write is logged.
  /// The history in the table stays, and the next write tries again.
  ///
  /// - Parameter sessionId: The session whose history to write.
  func writeHistory(of sessionId: SessionId) {
    guard let entry = sessions[sessionId], !entry.isReplayOnly, !entry.history.entries.isEmpty
    else {
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

  /// The retained history of a session that `session/resume` restores.
  /// It is the history in the table when this process ran the session.
  /// Else it is the history in the file of an earlier process.
  /// Else it is an empty history.
  /// The Router journal is never a source of a message.
  /// Its messages have no ACP ids.
  /// After a compaction it holds a summary in place of the messages that it folded.
  /// Its plans are a source, and
  /// ``resumedHistory(kept:directory:rootId:sessionId:)`` adds them.
  /// A file that does not read is logged, and the history starts empty.
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

  /// The history that `session/resume` restores.
  /// It is the retained history (``retainedHistory(kept:directory:sessionId:)``).
  /// It also holds each plan that the Router journal of the session recorded (task ^jwx92y8).
  ///
  /// The plans are the one part of the history that the Router journal gives.
  /// Router writes each plan event to disk at once.
  /// But the agent writes the history file only at the end of a prompt and at `session/close`.
  /// So a process that stopped during a prompt can leave a plan in the journal.
  /// The history file may not hold that plan.
  /// The history merges each recorded plan in post order, as the live projection did
  /// (``ACPEventTranslator/planUpdate(for:)``).
  /// Thus it holds the last plan of each plan id.
  /// A plan that the history holds already does not change.
  ///
  /// - Parameters:
  ///   - kept: The history in the table, or `nil`.
  ///   - directory: The transcript directory of the session.
  ///   - rootId: The recorded id of the session, which selects its events.
  ///   - sessionId: The session, for the log.
  /// - Returns: The history to replay.
  func resumedHistory(
    kept: SessionMergeEngine?, directory: URL, rootId: ULID, sessionId: SessionId
  ) -> SessionMergeEngine {
    var history = retainedHistory(kept: kept, directory: directory, sessionId: sessionId)
    for plan in recordedPlans(of: rootId, in: directory, sessionId: sessionId) {
      history.apply(.planUpdate(ACPEventTranslator.planUpdate(for: plan)))
    }
    return history
  }

  /// Each plan that the Router journal of one session recorded, in post
  /// order.
  ///
  /// The read keeps only the events of the session itself.
  /// The transcript directory of a session also holds the journals of its forks.
  /// The client must not get a plan of a session that did not make it.
  /// A journal that does not read is logged, and the resume replays no recorded plan.
  /// The history file can still hold the plans.
  ///
  /// - Parameters:
  ///   - rootId: The recorded id of the session.
  ///   - directory: The transcript directory of the session.
  ///   - sessionId: The session, for the log.
  /// - Returns: The plans, in post order.
  private func recordedPlans(of rootId: ULID, in directory: URL, sessionId: SessionId)
    -> [PlanSnapshot]
  {
    do {
      return try TranscriptEvent.merged(under: directory)
        .filter { $0.sessionId == rootId }
        .flatMap(\.operationEvents)
        .compactMap(\.plan)
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The Router journal of a session did not read. The resume replays no recorded plan.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
      return []
    }
  }
}
