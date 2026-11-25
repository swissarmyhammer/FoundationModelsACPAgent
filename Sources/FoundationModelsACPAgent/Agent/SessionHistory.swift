import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

// The retained history of a session (ACP schema-v2.0.0-alpha.7).
//
// `session/resume` replays the "retained history" of the session.
// A message that the agent keeps and replays must keep the id that the client saw live.
// The Router journal cannot give all of those ids.
// The agent makes the live id of each agent message and thought before Router records the entry.
// Thus the agent keeps its own history: one `SessionMergeEngine` for each session, in the session entry.
// Each `session/update` that the agent sends for the session goes into it.
// A compaction changes only the model context, never this history.
// The agent writes the history to a file beside the transcript, at the end of each recorded entry.
// So a new process can replay the same messages with the same ids.
// The Router journal serves the restore of the model context.
// It also serves two parts of the replay.
// One part is the plans of the session (task ^jwx92y8).
// A plan has its own id.
// Router writes each plan event to disk at once.
// So a resume merges the recorded plans into the history.
// The other part is the history of a session whose file is missing or does not decode.
// A resume then rebuilds the history from the journal (``RecordedHistoryRebuild``).
// A file that the resume reads is completed with the journal (``RecordedHistoryMerge``): the turns
// that it lacks, and the order of the model for a file of an earlier build.
// The journal keeps each entry that a compaction folded, so the rebuild gives each message.
// Only the ids of the agent messages and of the thoughts are new.
// A command that records nothing in Router (an action command) is not in the journal.

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

    /// Whether the history holds the records of the mail delivery (``MailDeliveryRecord``).
    /// This build writes `true`. A file of an earlier build has no member.
    let recordsMailDelivery: Bool?

    /// Whether the transcript holds each thought in the order of the model: thought, tool call,
    /// thought, message. This build writes `true`. A file of an earlier build has no member,
    /// and can hold the thoughts of a turn after its answer (``RecordedHistoryMerge``).
    let recordsModelOrder: Bool?

    /// Whether the transcript holds each call row at the place of its pass, also when the run
    /// events of the call come before the entries of the pass in the journal (the rebuild after
    /// this fix). This build writes `true`. A file with `recordsModelOrder` and no member was
    /// put in order by a build before the fix, and can hold each call row before the thoughts
    /// of its turn: it reads as a file that is not in the order of the model.
    let recordsRunOrder: Bool?
  }

  /// The history in a file, with the facts of the build that wrote it.
  struct Read {
    /// The retained history.
    let history: SessionMergeEngine

    /// True when the file holds the records of the mail delivery: the id of each user message
    /// of a user mail is the id of the mail.
    let recordsMailDelivery: Bool

    /// True when the transcript of the file is in the order of the model.
    let recordsModelOrder: Bool
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
    let contents = Contents(
      updates: history.transcriptUpdates + history.stateUpdates, recordsMailDelivery: true,
      recordsModelOrder: true, recordsRunOrder: true)
    let data = try JSONEncoder().encode(contents)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url(in: directory), options: .atomic)
  }

  /// The name of a file that did not decode, after ``keepAside(in:)`` moved it.
  static let unreadableFileName = fileName + ".unreadable"

  /// Moves the file in `directory` to a new name, so a new file can take its place and no byte of
  /// the old file is lost. The new name is ``unreadableFileName``. When a file has that name
  /// already, the new name adds a number: `session-history.json.unreadable.1`, then `.2`, and so
  /// on.
  ///
  /// - Parameter directory: The transcript directory of the session.
  /// - Returns: The URL of the moved file.
  /// - Throws: Whatever the move throws.
  @discardableResult
  static func keepAside(in directory: URL) throws -> URL {
    var target = directory.appendingPathComponent(unreadableFileName, isDirectory: false)
    var number = 0
    while FileManager.default.fileExists(atPath: target.path) {
      number += 1
      target = directory.appendingPathComponent(
        "\(unreadableFileName).\(number)", isDirectory: false)
    }
    try FileManager.default.moveItem(at: url(in: directory), to: target)
    return target
  }

  /// Whether `directory` holds the file.
  ///
  /// - Parameter directory: The transcript directory of the session.
  /// - Returns: `true` when the file is there.
  static func exists(in directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: url(in: directory).path)
  }

  /// Reads the history in the file in `directory`.
  ///
  /// A file of an earlier build holds no record of the mail delivery. The read gives its history
  /// the records that that build counted (``SessionMergeEngine/withEarlierBuildDeliveryRecords()``),
  /// so the fork map reads each history in the same way.
  ///
  /// - Parameter directory: The transcript directory of the session.
  /// - Returns: The retained history, or `nil` when the directory holds no
  ///   file. A session that an earlier build recorded has no file.
  /// - Throws: Whatever the read or the decode throws.
  static func read(from directory: URL) throws -> SessionMergeEngine? {
    try readFile(from: directory)?.history
  }

  /// Reads the history in the file in `directory`, with the facts of the build that wrote it.
  ///
  /// - Parameter directory: The transcript directory of the session.
  /// - Returns: The history and the facts, or `nil` when the directory holds no file.
  /// - Throws: Whatever the read or the decode throws.
  static func readFile(from directory: URL) throws -> Read? {
    let file = url(in: directory)
    guard FileManager.default.fileExists(atPath: file.path) else {
      return nil
    }
    let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
    let history = SessionMergeEngine(replaying: contents.updates.map(withoutRepeatedToolOutput))
    let recordsMailDelivery = contents.recordsMailDelivery == true
    return Read(
      history: recordsMailDelivery ? history : history.withEarlierBuildDeliveryRecords(),
      recordsMailDelivery: recordsMailDelivery,
      recordsModelOrder: contents.recordsModelOrder == true && contents.recordsRunOrder == true)
  }

  /// An update with the tool output one time. A build before ACPAgent 44850640 wrote the
  /// content of a tool call update as the summary of Router, then the output: the summary is the
  /// texts of the output, joined with a newline, so each output was in the file two times. A
  /// content whose first text is the texts of the rest, joined with a newline, loses that first
  /// text. Another update does not change.
  ///
  /// - Parameter update: The update of the file.
  /// - Returns: The update with the output one time.
  static func withoutRepeatedToolOutput(_ update: SessionUpdate) -> SessionUpdate {
    guard case .toolCallUpdate(var call) = update, case .value(let content) = call.content,
      content.count >= 2, let summary = text(of: content[0])
    else { return update }
    let texts = content.dropFirst().map(text(of:))
    guard texts.allSatisfy({ $0 != nil }), summary == texts.compactMap({ $0 }).joined(separator: "\n")
    else { return update }
    call.content = .value(Array(content.dropFirst()))
    return .toolCallUpdate(call)
  }

  /// The text of a text block of tool content, or `nil` for another kind.
  ///
  /// - Parameter content: The tool content.
  /// - Returns: The text, or `nil`.
  private static func text(of content: ToolCallContent) -> String? {
    guard case .content(let block) = content, case .text(let text) = block.content else {
      return nil
    }
    return text.text
  }

  /// The URL of the file in `directory`.
  ///
  /// - Parameter directory: The transcript directory of the session.
  /// - Returns: The file URL.
  static func url(in directory: URL) -> URL {
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

  /// The clock of the dates that the history records (``EntryDateRecord``).
  private let now: @Sendable () -> Date

  /// Makes the shared history over `history`.
  ///
  /// - Parameters:
  ///   - history: The first state of the history.
  ///   - now: The clock of the dates that the history records. The default is the system clock.
  init(
    _ history: SessionMergeEngine = SessionMergeEngine(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    engine = Mutex(history)
    self.now = now
  }

  /// A copy of the history as it is now.
  var snapshot: SessionMergeEngine {
    engine.withLock { $0 }
  }

  /// Merges one update into the history. When the update adds an entry that the history dates
  /// (``SessionEntry/isDatedInHistory``), the history also records the date of that entry
  /// (``EntryDateRecord``) in the same locked operation.
  ///
  /// - Parameter update: The update that the agent sends.
  func apply(_ update: SessionUpdate) {
    let now = now
    engine.withLock { history in
      let knownCount = history.entries.count
      _ = history.apply(update)
      let dated = history.entries.dropFirst(knownCount).filter(\.isDatedInHistory).map(\.id)
      for entry in dated {
        _ = history.apply(EntryDateRecord(entry: entry, date: now()).update)
      }
    }
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
  /// A recorded `_mail_delivery_paused` is not in the replay either. It records a past pause,
  /// and a later prompt can have lifted it. The pause in force goes out after the replay
  /// (``MailDeliveryPauseReport``).
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
      return replayedTranscriptUpdates + stateUpdates.filter { $0.isReplayedState }
    }
  }

  /// The transcript part of a replay from the start: each transcript entry as one whole update
  /// with its id, without a recorded `_mail_delivery_paused`, without a record of the mail
  /// delivery (``MailDeliveryRecord``) and without a record of the date of an entry
  /// (``EntryDateRecord``), which no client gets. The export of a session as Markdown renders the
  /// same updates (``RoutedACPAgent/transcriptMarkdown(of:includeThoughts:)``).
  ///
  /// A kept notice of a model change (``ModelChangeNoticeRecord``) goes out as the `notice` that
  /// it holds, at its place in the transcript.
  var replayedTranscriptUpdates: [SessionUpdate] {
    transcriptUpdates.filter {
      !$0.isMailDeliveryPause && !$0.isMailDeliveryRecord && !$0.isEntryDateRecord
    }.map { ModelChangeNoticeRecord.notice(in: $0).map(SessionUpdate.notice) ?? $0 }
  }
}

extension SessionMergeEngine {
  /// The position in ``entries`` of the first message entry with an id (``SessionEntry/ID/messageId``).
  /// An entry keeps the place where it first appeared, so a message that came in chunks has one
  /// position.
  ///
  /// - Parameter messageId: The ACP message id.
  /// - Returns: The position, or `nil` when no message of the history has the id.
  func messagePosition(of messageId: MessageId) -> Int? {
    entries.firstIndex { $0.id.messageId == messageId }
  }
}

extension SessionEntry.ID {
  /// The ACP message id of a message entry: a user message, an agent message, an agent thought or
  /// a message between sessions. It is `nil` for an entry that is not a message.
  var messageId: MessageId? {
    switch self {
    case .userMessage(let id), .agentMessage(let id), .agentThought(let id),
      .sessionMessage(let id):
      return id
    case .toolCall, .terminal, .plan, .compaction, .unidentified:
      return nil
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
      return announced(child.sessionId).map { held in
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
  /// Merges one update into the retained history of a session, and keeps the pause in force of
  /// the session (``ActiveSession/record(_:)``). A session that the table does not hold any
  /// more (a `session/delete` removed it) keeps no history.
  ///
  /// - Parameters:
  ///   - update: The update that the agent sends.
  ///   - sessionId: The session the update belongs to.
  func recordInHistory(_ update: SessionUpdate, of sessionId: SessionId) {
    sessions[sessionId]?.record(update)
  }

  /// Clears the pause of the mail delivery in force of a session (``ActiveSession/mailDeliveryPause``).
  /// Router holds run mail only until the next user-type mail carries it. So the first mail that
  /// the session takes after a pause lifts the pause (``SessionProjector``), and a model prompt
  /// of the client lifts the pause of a root session when the agent accepts it. A session that
  /// the table does not hold any more keeps no pause.
  ///
  /// - Parameter sessionId: The session whose pause lifted.
  func liftMailDeliveryPause(of sessionId: SessionId) {
    sessions[sessionId]?.mailDeliveryPause = nil
  }

  /// Merges one update into the retained history of a session, and reads
  /// where the update goes, in one step of the actor.
  ///
  /// A hot resume takes the session and copies the history for its replay
  /// in one step of the actor too. So an update that this step records
  /// before the take is in the replay, and it goes to the old owner. When
  /// the old owner is the new owner, the send drops it
  /// (``deliver(_:in:along:)``). An update that it records after the take is
  /// not in the replay, and it goes to the new owner, through the hold of
  /// the resume. No update goes to the new owner both in the replay and live.
  ///
  /// - Parameters:
  ///   - update: The update that the agent sends.
  ///   - sessionId: The session the update belongs to.
  /// - Returns: The route of the update, or `nil` when the session has no
  ///   owner.
  func recordAndRoute(_ update: SessionUpdate, of sessionId: SessionId) -> SessionUpdateRoute? {
    recordInHistory(update, of: sessionId)
    return connections.route(forSession: sessionId)
  }

  /// The sink of the updates of one session.
  /// It merges each update into the retained history of the session.
  /// Then it sends the update through the connection of the session.
  /// It reads the route of the update when it records the update
  /// (``recordAndRoute(_:of:)``): the owner of the session then, and the
  /// hold of a hot resume, if one is there. The send reads the connection
  /// of that owner from the table when the update goes out
  /// (``ConnectionTable/path(of:)``).
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
    { [weak self] update in
      guard let self else {
        return
      }
      let route = await recordAndRoute(update, of: sessionId)
      await post(update, of: sessionId, through: gate) { route }
    }
  }

  /// The sink of a snapshot. It sends through the connection like ``historySink(for:gate:)``,
  /// with the same gate. It records nothing in the retained history. A snapshot of the current
  /// state is no event of the session, so it must not replace the retained state. The replay
  /// never holds such an update, so the sink reads its route when the send runs
  /// (``ConnectionTable/route(forSession:)``).
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
      guard let self else {
        return
      }
      let connections = connections
      await post(update, of: sessionId, through: gate) {
        connections.route(forSession: sessionId)
      }
    }
  }

  /// Posts one update through the connection of its session. A session with a gate gives the
  /// post to the gate, which keeps it until the client knows the session.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - sessionId: The session the update belongs to.
  ///   - gate: The gate of the session, or `nil` for a session that the client knows already.
  ///   - route: Gives the route of the update when the send runs.
  private nonisolated func post(
    _ update: SessionUpdate, of sessionId: SessionId, through gate: SessionAnnouncementGate?,
    along route: @escaping @Sendable () -> SessionUpdateRoute?
  ) async {
    let send: SessionAnnouncementGate.Send = { [weak self] in
      await self?.deliver(update, in: sessionId, along: route())
    }
    guard let gate else {
      await send()
      return
    }
    await gate.submit(send)
  }

  /// Sends one update to the owner of its route. A route with the hold of a hot resume gives the
  /// send to the hold, which keeps it until the resume is done.
  ///
  /// A route with no hold can be older than a take. The sink reads the route of a recorded update
  /// when it records the update, and the send can run after a later take. So the send reads the
  /// route again (``isTakenAgain(_:of:)``). When the same connection took the tree since, it drops
  /// the update. The client of that connection reads the update in the replay, or in the current
  /// state that the resume sends, so the update is not lost. A live send of it would come after
  /// the resume request and before the replay announces its session.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - sessionId: The session the update belongs to.
  ///   - route: The route of the update, or `nil` for a session with no owner. The update then
  ///     goes to no client.
  private nonisolated func deliver(
    _ update: SessionUpdate, in sessionId: SessionId, along route: SessionUpdateRoute?
  ) async {
    guard let route else {
      return
    }
    let connections = connections
    let send: SessionResumeHold.Send = {
      await connections.path(of: route.owner)?.connection.post(update, in: sessionId)
    }
    guard let hold = route.hold else {
      if !isTakenAgain(route, of: sessionId) {
        await send()
      }
      return
    }
    await hold.submit(send)
  }

  /// Whether the owner of a route with no hold took the session again with a hot resume since the
  /// route was read: the session now has a hold, and its owner is the same connection.
  ///
  /// - Parameters:
  ///   - route: The route that the sink read, with no hold.
  ///   - sessionId: The session the update belongs to.
  /// - Returns: `true` when the same connection took the session again.
  private nonisolated func isTakenAgain(_ route: SessionUpdateRoute, of sessionId: SessionId)
    -> Bool
  {
    guard let current = connections.route(forSession: sessionId), current.hold != nil else {
      return false
    }
    return current.owner == route.owner
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
  /// The end of a prompt writes it (``promptFinished(_:sessionId:)``), and `session/close` writes it.
  /// The end of a turn that a mail started writes it too (``SessionProjector``), so a resume after
  /// a hard stop keeps that turn. Each write is one step of this actor, with no suspension, so two
  /// writes do not overlap, and the last write has the newest history.
  /// A history with no transcript entry writes nothing, so a session with no prompt leaves no directory.
  /// A replay-only session writes nothing either.
  /// It ran no prompt, so its file stays as the session that ran left it.
  /// A failed write is logged.
  /// The history in the table stays, and the next write tries again.
  /// After a write, the history goes to the transcript search index, off the turn
  /// (``TranscriptSearchUpdates/indexHistory(_:of:)``).
  ///
  /// The end of each transcript entry that Router recorded writes the file too, with no index
  /// of the search (``ACPEventTranslator/entryRecorded``). Thus a stop of the process during a
  /// turn keeps each update of the turn up to the last recorded entry.
  ///
  /// - Parameters:
  ///   - sessionId: The session whose history to write.
  ///   - indexesSearch: True when the written history also goes to the search index. The write
  ///     at the end of an entry gives false, so the search indexes each turn one time.
  func writeHistory(of sessionId: SessionId, indexesSearch: Bool = true) {
    guard let entry = sessions[sessionId], !entry.isReplayOnly, !entry.history.entries.isEmpty
    else {
      return
    }
    let history = entry.history
    do {
      try SessionHistoryFile.write(history, in: entry.transcriptDirectory)
      if indexesSearch {
        transcriptSearchUpdates.indexHistory(history, of: sessionId)
      }
    } catch {
      ACPAgentTelemetry.logger(.session).error(
        "The retained history of a session was not written.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
  }

  /// The retained history of a session that `session/resume` restores.
  /// It is the history in the table when this process ran the session.
  /// Else it is the history in the file of an earlier process, completed with the Router journal
  /// (``completedHistory(_:directory:sessionId:writes:)``): the turns that the file lacks, and
  /// the order of the model for a file of an earlier build.
  /// Else it is the history that the Router journal of the session gives
  /// (``rebuiltHistory(directory:sessionId:)``). Thus a resume never lacks the history that the
  /// journal holds: the file is missing after a stop of the process before the first write, and
  /// for a session that an earlier build recorded.
  /// The journal keeps each entry that a compaction folded. A compaction adds a `.prompt` entry
  /// that holds the summary, and the rebuild makes the compaction entry of it, not a message. So
  /// the rebuild gives each user message and each agent message of the transcript, and the
  /// summary does not take their place.
  /// The journal does not hold the live ids of the agent messages and of the thoughts, so a rebuilt
  /// history gives them new ids.
  /// The plans of the journal are a source of each history, and
  /// ``resumedHistory(kept:directory:rootId:sessionId:)`` adds them.
  /// A file that does not read is logged and kept aside (``SessionHistoryFile/keepAside(in:)``),
  /// and the journal gives the history.
  ///
  /// - Parameters:
  ///   - kept: The history in the table, or `nil`.
  ///   - directory: The transcript directory of the session.
  ///   - sessionId: The session. Its raw value is the recorded id of the session.
  /// - Returns: The retained history.
  func retainedHistory(
    kept: SessionMergeEngine?, directory: URL, sessionId: SessionId
  ) async -> SessionMergeEngine {
    if let kept {
      return kept
    }
    do {
      if let read = try SessionHistoryFile.readFile(from: directory) {
        return await completedHistory(read, directory: directory, sessionId: sessionId)
      }
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The retained history of a session did not read. The resume rebuilds it from the transcript.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
      do {
        try SessionHistoryFile.keepAside(in: directory)
      } catch {
        ACPAgentTelemetry.logger(.sessionResume).error(
          "The unreadable history file of a session did not move aside. The resume does not write a rebuilt history.",
          metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
        return await RecordedHistoryRebuild.rebuilt(
          from: recordedEvents(in: directory, sessionId: sessionId), sessionId: sessionId,
          readsUnmailedPrompts: await isCopiedExternalSession(sessionId)
        ).history
      }
    }
    return await rebuiltHistory(directory: directory, sessionId: sessionId)
  }

  /// The history of a history file, completed with the Router journal of the session
  /// (``RecordedHistoryMerge``): the turns of the journal after the last turn of the file, and,
  /// for a file of an earlier build, the order of the model. A history that changed goes to the
  /// file, so the next read gives it.
  ///
  /// - Parameters:
  ///   - read: The history in the file, with the facts of its build.
  ///   - directory: The transcript directory of the session.
  ///   - sessionId: The session. Its raw value is the recorded id of the session.
  ///   - writes: False when the completed history does not go to the file (an export).
  /// - Returns: The completed history.
  func completedHistory(
    _ read: SessionHistoryFile.Read, directory: URL, sessionId: SessionId, writes: Bool = true
  ) async -> SessionMergeEngine {
    let rebuilt = await RecordedHistoryRebuild.rebuilt(
      from: recordedEvents(in: directory, sessionId: sessionId), sessionId: sessionId)
    let completed = RecordedHistoryMerge.merged(read, with: rebuilt)
    guard writes, completed != read.history || !read.recordsModelOrder else {
      return completed
    }
    var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
    metadata[ACPAgentTelemetry.LogMetadataKey.entryCount] = "\(completed.entries.count)"
    ACPAgentTelemetry.logger(.sessionResume).info(
      "The retained history of a session was completed from the transcript.", metadata: metadata)
    do {
      try SessionHistoryFile.write(completed, in: directory)
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The completed history of a session was not written.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
    return completed
  }

  /// Whether a session is a copy of an external session: its origin is `import`.
  ///
  /// - Parameter sessionId: The session.
  /// - Returns: True for a copy. A session that the directory does not know is no copy.
  private func isCopiedExternalSession(_ sessionId: SessionId) async -> Bool {
    guard let id = ULID(ulidString: sessionId.rawValue),
      let summary = try? await sessionDirectory.summary(of: id)
    else {
      return false
    }
    return summary.origin == .import
  }

  /// The history that the Router journal of a session gives (``RecordedHistoryRebuild``). A
  /// history with an entry goes to the history file of the session in one atomic write, so the
  /// next resume reads the file. The rebuild is logged.
  ///
  /// - Parameters:
  ///   - directory: The transcript directory of the session.
  ///   - sessionId: The session. Its raw value is the recorded id of the session.
  /// - Returns: The rebuilt history. It is empty when the journal holds no entry of the session.
  private func rebuiltHistory(directory: URL, sessionId: SessionId) async -> SessionMergeEngine {
    let events = recordedEvents(in: directory, sessionId: sessionId)
    let history = await RecordedHistoryRebuild.rebuilt(
      from: events, sessionId: sessionId,
      readsUnmailedPrompts: await isCopiedExternalSession(sessionId)
    ).history
    guard !history.entries.isEmpty else {
      return history
    }
    var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
    metadata[ACPAgentTelemetry.LogMetadataKey.entryCount] = "\(history.entries.count)"
    ACPAgentTelemetry.logger(.sessionResume).info(
      "The retained history of a session was rebuilt from the transcript.", metadata: metadata)
    do {
      try SessionHistoryFile.write(history, in: directory)
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The rebuilt history of a session was not written.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
    return history
  }

  /// The recorded events of one session in its transcript directory, in journal order. The read
  /// keeps only the events of the session itself, not the events of its forks.
  /// A journal that does not read is logged, and the read gives no event.
  ///
  /// - Parameters:
  ///   - directory: The transcript directory of the session.
  ///   - sessionId: The session. Its raw value is the recorded id of the session.
  /// - Returns: The events.
  private func recordedEvents(in directory: URL, sessionId: SessionId) -> [TranscriptEvent] {
    guard let rootId = ULID(ulidString: sessionId.rawValue) else {
      return []
    }
    do {
      return try TranscriptEvent.merged(under: directory).filter { $0.sessionId == rootId }
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The Router journal of a session did not read. The resume rebuilds no history.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
      return []
    }
  }

  /// The history that `session/resume` restores.
  /// It is the retained history (``retainedHistory(kept:directory:sessionId:)``).
  /// It also holds each plan that the Router journal of the session recorded (task ^jwx92y8).
  ///
  /// Router writes each plan event to disk at once.
  /// But the agent writes the history file only at the end of each recorded entry, of a prompt
  /// and at `session/close`. So a process that stopped during a prompt can leave a plan in the
  /// journal.
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
  ) async -> SessionMergeEngine {
    var history = await retainedHistory(kept: kept, directory: directory, sessionId: sessionId)
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

/// The record of a notice of a model change in the retained history.
///
/// A `notice` is not history in ACP: the merge engine does not keep it. A model change is a fact
/// of the session, so the history keeps its notice as an entry of a private update type, at its
/// place in the transcript. The replay sends the `notice` that the entry holds
/// (``SessionMergeEngine/replayedTranscriptUpdates``). No client gets the private type.
enum ModelChangeNoticeRecord {
  /// The update type of the entry.
  static let updateType = "_model_change_notice"

  /// The entry that keeps `notice`.
  ///
  /// - Parameter notice: The notice.
  /// - Returns: The update of the entry, or `nil` when the notice does not encode.
  static func record(of notice: Notice) -> SessionUpdate? {
    guard let data = try? JSONEncoder().encode(notice),
      let payload = try? JSONDecoder().decode(FoundationModelsACP.JSONValue.self, from: data)
    else { return nil }
    return .unknown(updateType, payload)
  }

  /// The notice that an entry keeps.
  ///
  /// - Parameter update: An update of the history.
  /// - Returns: The notice, or `nil` for another update.
  static func notice(in update: SessionUpdate) -> Notice? {
    guard case .unknown(updateType, let payload) = update,
      let data = try? JSONEncoder().encode(payload)
    else { return nil }
    return try? JSONDecoder().decode(Notice.self, from: data)
  }
}
