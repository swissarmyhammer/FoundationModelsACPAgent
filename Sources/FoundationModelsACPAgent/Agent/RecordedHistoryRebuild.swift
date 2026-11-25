import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The rebuild of the retained history of one session from its Router journal.
///
/// A resume uses it when the history file of the session (``SessionHistoryFile``) is missing or
/// does not decode. The journal (`transcript.jsonl`) holds each entry of the session transcript.
/// A compaction does not remove an entry from the journal: it adds a `.prompt` entry that holds
/// the summary, and the journal keeps each entry that the compaction folded.
///
/// The rebuild gives each entry to the one projector of the live session
/// (``ACPEventTranslator/project(_:)``), as the live events that Router derives from it. Thus a
/// rebuilt update has the same shape as a live update. The rebuild keeps the order of the entries
/// in the journal. The rules for each entry:
///
/// - A `.prompt` entry or a `promptStarted` marker gives one user message for each user mail that
///   it delivers. The id of the message is the id of the mail, as for a live prompt. A mail that an
///   earlier entry gave already gives no second message. The text of a prompt that delivers no
///   user mail (a run message, a compaction summary) is no message of the client.
/// - The summary entry of a compaction (a `.prompt` entry with a `CompactionSegment`) gives the
///   completed compaction entry, with the id of the compaction and its summary, as the live
///   report of the compaction did (``CompactionReporter``). It gives no message, and each
///   message before it stays.
/// - A `.reasoning` entry gives a thought, and a `.response` entry gives an agent message. The
///   journal records the entries of one round in the order of the SDK: the response, then the
///   reasoning (FoundationModelsRouter 1173a869). The model thinks before it answers, so the
///   rebuild gives each `.reasoning` entry that follows a `.response` entry before that response.
///   The journal does not change, so the prompt of a restore does not change.
/// - In a copied external session (`readsUnmailedPrompts`), a `.prompt`
///   entry with no mail record and no compaction gives one user message: the import wrote the
///   prompt (``ImportedTranscript``). The id of the message is the id of the entry, so each
///   rebuild gives the same id.
/// - A `.toolCalls` entry gives one tool call for each call in it.
/// - A `toolCallStarted` marker joins the token of the run of its call to the id of the call.
/// - The end event of a run (an `OperationEvent` of the kind `completed`) gives the final status
///   of its call, as the settlement of the run does live. A run in the background (an event of
///   the run holds its pending envelope) that did not end in the journal keeps its call
///   `in_progress`: the process stopped while it ran, and a resume runs it again.
/// - A `.toolOutput` entry gives the `completed` status of the call that it answers, with its
///   output. An output that is the pending envelope of the run of the call keeps the call
///   `in_progress`, as live: the run goes on in the background. An output that holds the events of a run (`OperationEventSegment`) is a record of the
///   run, not the output of a call, and gives nothing.
/// - Each other kind gives nothing.
///
/// The id of an agent message or of a thought is a new id: the journal does not hold the ids
/// that the client saw live.
enum RecordedHistoryRebuild {
  /// The schema name of the segment that holds one record of a mail in a `.prompt` entry or in a
  /// `promptStarted` marker.
  static let mailRecordSchemaName = "FoundationModelsRouter.MailRecordSegment"

  /// The schema name of the segment that holds one event of a run in a `.toolOutput` entry.
  static let operationEventSchemaName = "FoundationModelsRouter.OperationEventSegment"

  /// The schema name of the segment that holds the checkpoint of a compaction in its summary
  /// entry. The id of the segment is the id of the compaction.
  static let compactionSchemaName = "FoundationModelsRouter.CompactionSegment"

  /// The end of the id of the text segment that holds the summary in the summary entry of a
  /// compaction: `<entry id>-text`.
  static let summaryTextSegmentIdSuffix = "-text"

  /// The rebuilt history of one session.
  ///
  /// - Parameters:
  ///   - events: The recorded events of the session, in journal order. An event of another
  ///     session (a fork) must not be in it.
  ///   - sessionId: The session, for the translator and the logs.
  /// - Returns: The history, with a record of the delivery of each user mail
  ///   (``SessionMergeEngine/withEarlierBuildDeliveryRecords()``). It is empty when no event gives
  ///   an update.
  static func history(from events: [TranscriptEvent], sessionId: SessionId) async
    -> SessionMergeEngine
  {
    await rebuilt(from: events, sessionId: sessionId).history
  }

  /// The rebuilt history of one session, with the ids of its user messages that a user mail
  /// gave.
  ///
  /// - Parameters:
  ///   - events: The recorded events of the session, in journal order. An event of another
  ///     session (a fork) must not be in it.
  ///   - sessionId: The session, for the translator and the logs.
  ///   - readsUnmailedPrompts: True for a copied external session: each `.prompt` entry with no
  ///     mail record and no compaction gives a user message.
  /// - Returns: The history and the ids.
  static func rebuilt(
    from events: [TranscriptEvent], sessionId: SessionId, readsUnmailedPrompts: Bool = false
  ) async -> Rebuilt {
    let clock = Mutex(Date())
    let history = RetainedHistory(now: { clock.withLock { $0 } })
    let runCallJoins = RunCallJoinTable()
    var translator = ACPEventTranslator(
      sessionId: sessionId, parentSessionId: nil, send: { history.apply($0) }, modelName: "",
      runCallJoins: runCallJoins)
    var reader = EntryReader(readsUnmailedPrompts: readsUnmailedPrompts)
    // The responses that wait for the reasoning entries after them in their round.
    var heldResponses: [RecordedEntry] = []
    func give(_ recorded: RecordedEntry) async {
      if let date = recorded.date {
        clock.withLock { $0 = date }
      }
      for update in recorded.updates {
        history.apply(update)
      }
      for sessionEvent in recorded.events {
        await translator.project(sessionEvent)
      }
    }
    var runs = BackgroundRuns()
    // The id of each call that a `toolCalls` entry gave to the history.
    var givenCallIds: Set<String> = []
    // The ends of the runs whose call no `toolCalls` entry gave yet, by the id of the call. Router
    // writes the run events of a turn live, and the SDK entries of the passes can come later in
    // one batch: an end goes out after the entry of its call, so the call row is at the place of
    // its pass, after the thought of the pass.
    var heldEnds: [String: [OperationEvent]] = [:]
    for event in events {
      // The marker of a started call joins the token of its run to the id of the call, as the
      // live session does. Thus a call whose output is the pending envelope of its run stays
      // open (``ACPEventTranslator`` keeps it `in_progress`).
      for (callId, token) in Self.runJoins(in: event) {
        runCallJoins.record(toolCallID: callId, for: RunToken(token))
        runs.calls[token] = callId
      }
      // The end of a run gives the final status of its call, as the settlement does live.
      var ends: [OperationEvent] = []
      for end in runs.read(event.operationEvents) {
        if let callId = runs.calls[end.correlationID], !givenCallIds.contains(callId) {
          heldEnds[callId, default: []].append(end)
        } else {
          ends.append(end)
        }
      }
      if !ends.isEmpty {
        for held in heldResponses {
          await give(held)
        }
        heldResponses = []
        for end in ends {
          await translator.project(.runSettled(end))
        }
      }
      let recorded = reader.read(event)
      guard !recorded.updates.isEmpty || !recorded.events.isEmpty else {
        continue
      }
      switch event.kind {
      case .response:
        heldResponses.append(recorded)
      case .reasoning where !heldResponses.isEmpty:
        await give(recorded)
      default:
        for held in heldResponses {
          await give(held)
        }
        heldResponses = []
        await give(recorded)
      }
      if event.kind == .toolCalls {
        for call in EventFields(of: event)?.entry?.toolCalls ?? [] {
          givenCallIds.insert(call.id)
          for end in heldEnds.removeValue(forKey: call.id) ?? [] {
            await translator.project(.runSettled(end))
          }
        }
      }
    }
    for held in heldResponses {
      await give(held)
    }
    // The end of a run whose call no entry gave: the call row comes from the end, at the end.
    for callId in heldEnds.keys.sorted() {
      for end in heldEnds[callId] ?? [] {
        await translator.project(.runSettled(end))
      }
    }
    // A run in the background that did not end in the journal was still running when the
    // process stopped. Its call is open, as the live history keeps it: an SDK output that the
    // stop recorded (the text of a cancel by the shutdown) is not its end.
    for callId in runs.openCallIds {
      history.apply(
        .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: callId), status: .value(.inProgress))))
    }
    let snapshot = history.snapshot
    let mailMessageIds = Set(reader.deliveredMail.map { MessageId(rawValue: $0.description) })
    guard !snapshot.entries.isEmpty else {
      return Rebuilt(history: snapshot, mailMessageIds: mailMessageIds)
    }
    return Rebuilt(
      history: snapshot.withEarlierBuildDeliveryRecords(), mailMessageIds: mailMessageIds)
  }

  /// The runs in the background of a journal: the runs whose events hold a pending envelope, and
  /// the runs that ended.
  struct BackgroundRuns {
    /// The id of the call of each run, by the token of the run.
    var calls: [String: String] = [:]

    /// The token of each run that went to the background: an event of the run holds its
    /// pending envelope.
    private var detached: Set<String> = []

    /// The token of each run that ended.
    private var ended: Set<String> = []

    /// Reads the run events of one recorded event.
    ///
    /// - Parameter events: The run events, in order.
    /// - Returns: The end events of the runs, in order.
    mutating func read(_ events: [OperationEvent]) -> [OperationEvent] {
      var ends: [OperationEvent] = []
      for event in events {
        switch event.kind {
        case .completed:
          ended.insert(event.correlationID)
          ends.append(event)
        default:
          if PendingRunEnvelope.isRendered(text: event.detail) {
            detached.insert(event.correlationID)
          }
        }
      }
      return ends
    }

    /// The id of the call of each run that went to the background and did not end, sorted.
    var openCallIds: [String] {
      detached.subtracting(ended).compactMap { calls[$0] }.sorted()
    }
  }

  /// The joins of the runs that the `toolCallStarted` marker `event` records: the id of each
  /// started call, with the token of its run.
  ///
  /// - Parameter event: A recorded event.
  /// - Returns: The joins, or none for another kind of event or a call with no token.
  private static func runJoins(in event: TranscriptEvent) -> [(callId: String, token: String)] {
    guard event.kind == .toolCallStarted, let calls = EventFields(of: event)?.entry?.toolCalls
    else {
      return []
    }
    return calls.compactMap { call in call.correlationID.map { (callId: call.id, token: $0) } }
  }

  /// The rebuilt history of one session.
  struct Rebuilt {
    /// The history, with a record of the delivery of each user mail.
    let history: SessionMergeEngine

    /// The id of each user message that a user mail gave. A user message of a copied prompt or
    /// of a command exchange is not in it.
    let mailMessageIds: Set<MessageId>
  }
}

// MARK: - The read of one recorded event

extension RecordedHistoryRebuild {
  /// What one recorded event gives to the rebuild.
  struct RecordedEntry {
    /// The instant that the recorder stamped on the event, or `nil` when it did not decode.
    var date: Date?

    /// The updates that go into the history as they are: the user messages.
    var updates: [SessionUpdate] = []

    /// The live events that the translator projects, in order.
    var events: [SessionEvent] = []
  }

  /// The reader of the recorded events of one session, in journal order. It keeps the state that
  /// spans events: the user mail that a message gave already, the tool calls of the open
  /// submission, and the calls that an output answered.
  struct EntryReader {
    /// The id of each user mail that gave a user message.
    private(set) var deliveredMail: Set<MailID> = []

    /// True when a `.prompt` entry with no mail record and no compaction gives a user message:
    /// the prompt of a copied external session.
    let readsUnmailedPrompts: Bool

    /// Makes a reader.
    ///
    /// - Parameter readsUnmailedPrompts: True for a copied external session.
    init(readsUnmailedPrompts: Bool = false) {
      self.readsUnmailedPrompts = readsUnmailedPrompts
    }

    /// The id of each recorded entry that the reader read.
    private var readEntryIds: Set<String> = []

    /// The ids of the tool calls since the last `.prompt` entry, in call order.
    private var dispatchedCallIds: [String] = []

    /// The ids of the calls in ``dispatchedCallIds`` that an output answered.
    private var completedCallIds: Set<String> = []

    /// What `event` gives to the rebuild.
    ///
    /// - Parameter event: The next recorded event of the session.
    /// - Returns: The updates and the live events of the event. Both are empty for an event that
    ///   gives nothing.
    mutating func read(_ event: TranscriptEvent) -> RecordedEntry {
      if let exchange = event.commandExchange {
        return Self.commandExchange(exchange, date: EventFields(of: event)?.ts)
      }
      guard event.kind == .promptStarted || event.mirrorsTranscriptEntry,
        let fields = EventFields(of: event)
      else {
        return RecordedEntry()
      }
      var recorded = RecordedEntry(date: fields.ts)
      if event.kind != .promptStarted {
        guard let entryId = fields.entry?.entryId, readEntryIds.insert(entryId).inserted else {
          return RecordedEntry()
        }
      }
      switch event.kind {
      case .prompt, .promptStarted:
        if event.kind == .prompt {
          dispatchedCallIds = []
          completedCallIds = []
        }
        recorded.updates = userMessages(in: event)
        if let compaction = Self.compaction(in: event, entryId: fields.entry?.entryId) {
          recorded.events = [.compaction(compaction)]
        } else if event.kind == .prompt, readsUnmailedPrompts, let entryId = fields.entry?.entryId,
          let copied = Self.copiedPrompt(event, entryId: entryId)
        {
          recorded.updates = [copied]
        }
      case .reasoning:
        let text = Self.text(of: event)
        guard !text.isEmpty else { return RecordedEntry() }
        recorded.events = [
          .reasoningDelta(text),
          .entryRecorded(id: fields.entry?.entryId ?? "", kind: .reasoning),
        ]
      case .response:
        let text = Self.text(of: event)
        guard !text.isEmpty else { return RecordedEntry() }
        recorded.events = [
          .textDelta(text), .entryRecorded(id: fields.entry?.entryId ?? "", kind: .response),
        ]
      case .toolCalls:
        let calls = (fields.entry?.toolCalls ?? []).filter { !dispatchedCallIds.contains($0.id) }
        guard !calls.isEmpty else { return RecordedEntry() }
        dispatchedCallIds += calls.map(\.id)
        recorded.events =
          calls.map { .toolCall(id: $0.id, name: $0.toolName, argumentsJSON: $0.argumentsJSON) }
          + [.entryRecorded(id: fields.entry?.entryId ?? "", kind: .toolCalls)]
      case .toolOutput:
        guard !Self.holdsRunEvents(event), let entryId = fields.entry?.entryId else {
          return RecordedEntry()
        }
        let callId = completedCallId(forOutputEntryId: entryId)
        completedCallIds.insert(callId)
        recorded.events = [
          .toolStatus(
            id: callId, status: .completed, summary: event.text, output: event.entry?.segments)
        ]
      default:
        return RecordedEntry()
      }
      return recorded
    }

    /// The user message and the reply of a command of the agent that ran with no model call,
    /// for example `/compact` (FoundationModelsRouter `commandExchange`). The user message keeps
    /// the id that the client saw. The reply gets a new message id, as each rebuilt agent
    /// message does.
    ///
    /// - Parameters:
    ///   - exchange: The user message, its id and the reply.
    ///   - date: The time of the record.
    /// - Returns: The user message, and the reply when it has text.
    private static func commandExchange(
      _ exchange: (prompt: String, messageID: String, reply: String), date: Date?
    ) -> RecordedEntry {
      var recorded = RecordedEntry(date: date)
      recorded.updates = [
        .userMessage(
          UserMessage(
            messageId: MessageId(rawValue: exchange.messageID),
            content: .value([.text(TextContent(text: exchange.prompt))])))
      ]
      if !exchange.reply.isEmpty {
        recorded.updates.append(
          .agentMessageChunk(
            ContentChunk(
              content: .text(TextContent(text: exchange.reply)),
              messageId: ACPEventTranslator.makeMessageId())))
      }
      return recorded
    }

    /// The user message of each user mail that `event` delivers and that no earlier event gave.
    ///
    /// - Parameter event: A `.prompt` entry or a `promptStarted` marker.
    /// - Returns: One `user_message` for each such mail, in delivery order.
    private mutating func userMessages(in event: TranscriptEvent) -> [SessionUpdate] {
      var messages: [SessionUpdate] = []
      for mail in Self.deliveredUserMail(in: event) where deliveredMail.insert(mail.id).inserted {
        guard case .userMessage(let prompt, _) = mail.body else { continue }
        messages.append(
          .userMessage(
            UserMessage(
              messageId: MessageId(rawValue: mail.id.description),
              content: .value([.text(TextContent(text: prompt))]))))
      }
      return messages
    }

    /// The user message of the `.prompt` entry of a copied external session: the text of its
    /// text segments, with the id of the entry.
    ///
    /// - Parameters:
    ///   - event: A `.prompt` entry with no compaction.
    ///   - entryId: The id of the entry.
    /// - Returns: The message, or `nil` when the entry holds a mail record or no text.
    private static func copiedPrompt(_ event: TranscriptEvent, entryId: String) -> SessionUpdate? {
      let segments = event.entry?.segments ?? []
      let holdsMail = segments.contains { segment in
        guard case .structure(_, let schemaName, _) = segment else { return false }
        return schemaName == RecordedHistoryRebuild.mailRecordSchemaName
      }
      let text = text(of: event)
      guard !holdsMail, !text.isEmpty else { return nil }
      return .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: entryId), content: .value([.text(TextContent(text: text))])))
    }

    /// The id of the call that a `.toolOutput` entry answers. It is the rule of Router: the id of
    /// the entry when a call of the submission has it, else the oldest call of the submission that
    /// no output answered, else the id of the entry.
    ///
    /// - Parameter entryId: The id of the `.toolOutput` entry.
    /// - Returns: The id of the call.
    private func completedCallId(forOutputEntryId entryId: String) -> String {
      guard !dispatchedCallIds.contains(entryId) else { return entryId }
      return dispatchedCallIds.first { !completedCallIds.contains($0) } ?? entryId
    }

    /// The text of the text segments of the entry of `event`, joined.
    ///
    /// - Parameter event: A `.reasoning`, `.response` or `.prompt` entry.
    /// - Returns: The text, empty when the entry has no text segment.
    private static func text(of event: TranscriptEvent) -> String {
      (event.entry?.segments ?? []).compactMap { segment -> String? in
        guard case .text(_, let content) = segment else { return nil }
        return content
      }.joined()
    }

    /// The compaction whose summary entry is `event`.
    ///
    /// - Parameters:
    ///   - event: A `.prompt` entry.
    ///   - entryId: The id of the entry.
    /// - Returns: The result of the compaction, or `nil` when the entry holds no checkpoint that
    ///   decodes.
    private static func compaction(in event: TranscriptEvent, entryId: String?)
      -> CompactionResult?
    {
      let segments = event.entry?.segments ?? []
      for segment in segments {
        guard case .structure(let id, let schemaName, let contentJSON) = segment,
          schemaName == RecordedHistoryRebuild.compactionSchemaName,
          let checkpoint = try? JSONDecoder().decode(
            CompactionCheckpoint.self, from: Data(contentJSON.utf8))
        else {
          continue
        }
        let summary = segments.compactMap { segment -> String? in
          guard case .text(let textId, let content) = segment,
            textId.hasSuffix(RecordedHistoryRebuild.summaryTextSegmentIdSuffix)
          else {
            return nil
          }
          return content
        }.joined()
        return CompactionResult(
          id: id, summary: summary.isEmpty ? nil : summary, summaryEntryId: entryId,
          tokensBefore: checkpoint.tokensBefore, tokensAfter: checkpoint.tokensAfter,
          stagesApplied: checkpoint.stagesApplied)
      }
      return nil
    }

    /// Whether the entry of `event` holds the events of a run.
    ///
    /// - Parameter event: A `.toolOutput` entry.
    /// - Returns: `true` when a segment of the entry holds a run event.
    private static func holdsRunEvents(_ event: TranscriptEvent) -> Bool {
      (event.entry?.segments ?? []).contains { segment in
        guard case .structure(_, let schemaName, _) = segment else { return false }
        return schemaName == RecordedHistoryRebuild.operationEventSchemaName
      }
    }

    /// The user mail that the mail records of `event` deliver, in segment order. A record that
    /// does not decode is passed over.
    ///
    /// - Parameter event: A `.prompt` entry or a `promptStarted` marker.
    /// - Returns: The mail whose sender is the user.
    private static func deliveredUserMail(in event: TranscriptEvent) -> [Mail] {
      (event.entry?.segments ?? []).compactMap { segment -> Mail? in
        guard case .structure(_, let schemaName, let contentJSON) = segment,
          schemaName == RecordedHistoryRebuild.mailRecordSchemaName,
          let record = try? JSONDecoder().decode(
            DeliveredMailRecord.self, from: Data(contentJSON.utf8)),
          let mail = record.mailDelivered?.mail, mail.sender == .user
        else {
          return nil
        }
        return mail
      }
    }
  }
}

// MARK: - The fields that Router does not make public

extension RecordedHistoryRebuild {
  /// The `mailDelivered` record of one mail record segment, in the JSON form that Router writes:
  /// `{"mailDelivered": {"_0": <Mail>}}`. A record of another case decodes with no mail.
  struct DeliveredMailRecord: Decodable {
    /// The body of a `mailDelivered` record.
    struct Delivered: Decodable {
      /// The delivered mail.
      let mail: Mail

      /// The JSON keys of the body.
      private enum CodingKeys: String, CodingKey {
        case mail = "_0"
      }
    }

    /// The body of the record, or `nil` for a record of another case.
    let mailDelivered: Delivered?
  }

  /// The sizes and the stages of the checkpoint of a compaction, in the JSON form that Router
  /// writes in its `CompactionSegment`.
  struct CompactionCheckpoint: Decodable {
    /// The size of the context before the compaction, in tokens.
    let tokensBefore: Int

    /// The size of the context after the compaction, in tokens.
    let tokensAfter: Int

    /// The stages that the compaction applied, in order.
    let stagesApplied: [String]
  }

  /// The fields of one recorded event that Router does not make public: the instant of the
  /// event, the id of its entry, and the calls of a `.toolCalls` entry. The read encodes the event
  /// with its own `Codable` form and decodes these fields of it, as
  /// ``TranscriptEntryMapping`` reads an event.
  struct EventFields: Decodable {
    /// The fields of the entry of the event.
    struct Entry: Decodable {
      /// The id of the entry.
      let entryId: String

      /// The calls of a `.toolCalls` entry, or `nil`.
      let toolCalls: [Call]?
    }

    /// One call of a `.toolCalls` entry.
    struct Call: Decodable {
      /// The id of the call.
      let id: String

      /// The name of the called tool.
      let toolName: String

      /// The arguments of the call, as JSON text.
      let argumentsJSON: String

      /// The token of the run of the call, in a `toolCallStarted` marker, or `nil`.
      let correlationID: String?
    }

    /// The instant that the recorder stamped on the event, or `nil`.
    let ts: Date?

    /// The fields of the entry, or `nil` for an event with no entry.
    let entry: Entry?

    /// Reads the fields of `event`.
    ///
    /// - Parameter event: The recorded event.
    /// - Returns: The fields, or `nil` when the encode or the decode fails.
    init?(of event: TranscriptEvent) {
      guard let data = try? JSONEncoder().encode(event),
        let fields = try? JSONDecoder().decode(EventFields.self, from: data)
      else {
        return nil
      }
      self = fields
    }
  }
}
