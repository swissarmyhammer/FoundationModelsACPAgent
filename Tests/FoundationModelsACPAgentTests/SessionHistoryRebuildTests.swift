import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The rebuild of the retained history from the Router journal of a session
/// (``RecordedHistoryRebuild``), when the history file of the session is missing or does not
/// decode. A resume then replays the transcript of the session, and the agent writes the rebuilt
/// history as the new file.
@Suite(.closesHarnesses) struct SessionHistoryRebuildTests {
  // MARK: - The script

  /// The prefix of the folders of this suite.
  private static let label = "SessionHistoryRebuildTests"

  /// The prompt of the first turn.
  private static let firstPrompt = "Note the first label."

  /// The prompt of the second turn.
  private static let secondPrompt = "Note the second label."

  /// The thought of each turn.
  private static let thoughtText = "I note the label."

  /// The label of each call.
  private static let noteLabel = "noted label"

  /// The agent message at the end of each turn.
  private static let answerText = "The label is noted."

  /// The bytes of a history file that does not decode.
  private static let badBytes = Data("{ this is not a history".utf8)

  /// A tool that gives back its label.
  struct NoteTool: Tool {
    let name = "note"
    let description = "Note a label."

    func call(arguments: LabelArguments) async throws -> String {
      arguments.label
    }
  }

  /// The script of each turn: a thought, a call of ``NoteTool``, and an agent message.
  private static let script: [ScriptedPassStep] = [
    .reasoning(thoughtText),
    .toolCall(name: "note", argumentsJSON: #"{"label":"\#(noteLabel)"}"#),
    .textDelta(answerText),
    .endPass,
  ]

  // MARK: - The readers

  /// The kind of one transcript update of a replay, for the order proofs.
  enum UpdateKind: Equatable {
    /// A user message.
    case user

    /// An agent thought.
    case thought

    /// A tool call.
    case toolCall

    /// An agent message.
    case agent
  }

  /// The kind of each message and tool call of `updates`, in order.
  ///
  /// - Parameter updates: The replayed updates.
  /// - Returns: The kinds.
  private static func kinds(of updates: [SessionUpdate]) -> [UpdateKind] {
    updates.compactMap { update in
      switch update {
      case .userMessage: .user
      case .agentThought: .thought
      case .toolCallUpdate: .toolCall
      case .agentMessage: .agent
      default: nil
      }
    }
  }

  /// The kind of the update that the rebuild makes of each entry of `events`, in journal order:
  /// a `.prompt` entry with a user mail is a user message, a `.reasoning` entry is a thought, a
  /// `.toolCalls` entry is a tool call, and a `.response` entry with text is an agent message.
  ///
  /// - Parameter events: The recorded events of one session.
  /// - Returns: The kinds.
  private static func kinds(of events: [TranscriptEvent]) -> [UpdateKind] {
    events.compactMap { event in
      switch event.kind {
      case .prompt:
        return event.mailRecords.isEmpty ? nil : .user
      case .reasoning:
        return .thought
      case .toolCalls:
        return .toolCall
      case .response:
        return (event.text ?? "").isEmpty ? nil : .agent
      default:
        return nil
      }
    }
  }

  /// The tool call updates of `updates` for the call `id`.
  ///
  /// - Parameters:
  ///   - id: The id of the call.
  ///   - updates: The replayed updates.
  /// - Returns: The updates.
  private static func toolCallUpdates(of id: String, in updates: [SessionUpdate])
    -> [ToolCallUpdate]
  {
    updates.compactMap { update in
      guard case .toolCallUpdate(let call) = update, call.toolCallId.rawValue == id else {
        return nil
      }
      return call
    }
  }

  /// The first content block of a compaction summary.
  ///
  /// - Parameter summary: The summary field, or `nil`.
  /// - Returns: The first block, or `nil` when the field has no block.
  private static func firstBlock(of summary: PatchField<[ContentBlock]>?) -> ContentBlock? {
    guard case .value(let blocks)? = summary else { return nil }
    return blocks.first
  }

  /// The URL of the history file of `sessionId` under the recording root of `cwd`.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - cwd: The working directory of the session.
  /// - Returns: The URL.
  /// - Throws: When the recording root cannot be resolved.
  private static func historyFile(of sessionId: SessionId, in cwd: URL) throws -> URL {
    try sessionDirectory(of: sessionId, in: cwd).appendingPathComponent(
      SessionHistoryFile.fileName, isDirectory: false)
  }

  /// The transcript directory of `sessionId` under the recording root of `cwd`.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - cwd: The working directory of the session.
  /// - Returns: The URL.
  /// - Throws: When the recording root cannot be resolved.
  private static func sessionDirectory(of sessionId: SessionId, in cwd: URL) throws -> URL {
    try ResumeSessionFixture.projectRecordingRoot(of: cwd).appendingPathComponent(
      sessionId.rawValue, isDirectory: true)
  }

  /// The session that a resume took.
  struct Resumed {
    /// The id of the session.
    let sessionId: SessionId

    /// The working directory of the session.
    let cwd: URL

    /// The transcript directory of the session.
    var directory: URL {
      get throws { try SessionHistoryRebuildTests.sessionDirectory(of: sessionId, in: cwd) }
    }
  }

  /// Runs `prompts` in a new agent in a new working directory, closes the session (which writes
  /// the history file), changes the history file with `damage`, and resumes the session in a
  /// second agent with a replay from the start. Each folder of the two agents is removed at the
  /// end.
  ///
  /// - Parameters:
  ///   - prompts: The prompts of the turns, in order.
  ///   - damage: What to do to the history file before the resume.
  ///   - read: What to read after the resume. It gets the resumed session, the replayed updates,
  ///     the response of each prompt and the recorded events of the session.
  /// - Returns: What `read` returned.
  /// - Throws: Whatever a wire call, a wait or `read` throws.
  private static func resumeAfterDamage<Reading>(
    prompts: [String], damage: (URL) throws -> Void,
    read: (Resumed, [SessionUpdate], [PromptResponse], [TranscriptEvent]) throws -> Reading
  ) async throws -> Reading {
    let folders = TestFolderLabel(label)
    defer { folders.removeFolders() }
    let cwd = makeResolvedDirectory(label: "\(folders.value)-repo")
    let first = try await ScriptedPromptFixture.make(
      script: script, label: folders.value, workingDirectory: cwd, hostTools: [NoteTool()])
    var responses: [PromptResponse] = []
    for (index, prompt) in prompts.enumerated() {
      responses.append(
        try await ScriptedPromptFixture.runPrompt(on: first, text: prompt, count: index + 1)
          .response)
    }
    let sessionId = first.sessionId
    let events = try ResumeSessionFixture.recordedEvents(
      under: try ResumeSessionFixture.projectRecordingRoot(of: cwd), sessionId: sessionId)
    return try await first.closeAndResume(
      makeSecond: { cwd in
        try damage(try historyFile(of: sessionId, in: cwd))
        return try await ScriptedPromptFixture.make(
          script: [.endPass], label: folders.value, workingDirectory: cwd,
          hostTools: [NoteTool()])
      },
      read: { second, countBefore in
        let replay = Array(await second.collector.updates.dropFirst(countBefore)).map(\.update)
        return try read(
          Resumed(sessionId: sessionId, cwd: second.cwd), replay, responses, events)
      })
  }

  /// Expects that `replay` holds the full turn of ``script`` for the prompt `prompt`: the user
  /// message with the id of the prompt response, the thought, the agent message, and the tool
  /// call one time with its output and the completed status.
  ///
  /// - Parameters:
  ///   - replay: The replayed updates.
  ///   - prompt: The prompt of the turn.
  ///   - response: The response of the prompt.
  private static func expectFullTurn(
    in replay: [SessionUpdate], prompt: String, response: PromptResponse,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let messages = ReplayedMessage.replayed(in: replay)
    let kinds: [ReplayedMessage.Kind] = messages.map(\.kind)
    #expect(kinds == [.user, .thought, .agent], "the replay holds \(messages)",
      sourceLocation: sourceLocation)
    #expect(messages.first?.id == response.messageId.rawValue, sourceLocation: sourceLocation)
    let texts: [String] = messages.map(\.text)
    #expect(texts == [prompt, thoughtText, answerText], sourceLocation: sourceLocation)
    let callId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"
    let calls = toolCallUpdates(of: callId, in: replay)
    #expect(calls.count == 1, "the replay holds \(calls)", sourceLocation: sourceLocation)
    #expect(calls.first?.status == .value(.completed), sourceLocation: sourceLocation)
    #expect(calls.first?.name == .value("note"), sourceLocation: sourceLocation)
    let output = calls.first.map { "\($0.rawOutput)\($0.content)" } ?? ""
    #expect(output.contains(noteLabel), "the call holds \(output)", sourceLocation: sourceLocation)
  }

  // MARK: - The proofs

  /// (a) A session whose history file is missing replays the full turn from its Router journal:
  /// the user message, the thought, the agent message, and the tool call one time with its output.
  /// The resume writes the rebuilt history as the new file.
  @Test func aMissingHistoryFileReplaysTheTurnFromTheTranscript() async throws {
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt],
      damage: { file in try FileManager.default.removeItem(at: file) },
      read: { resumed, replay, responses, _ in
        Self.expectFullTurn(in: replay, prompt: Self.firstPrompt, response: responses[0])
        let written = try #require(try SessionHistoryFile.read(from: resumed.directory))
        #expect(
          ReplayedMessage.replayed(in: written.replayUpdates(from: .start))
            == ReplayedMessage.replayed(in: replay))
      })
  }

  /// (b) A session whose history file does not decode replays the full turn from its Router
  /// journal. The bad file is kept aside with its bytes, and the rebuilt history is the new file.
  @Test func anUnreadableHistoryFileIsKeptAsideAndTheTurnReplaysFromTheTranscript() async throws {
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt],
      damage: { file in try Self.badBytes.write(to: file, options: .atomic) },
      read: { resumed, replay, responses, _ in
        Self.expectFullTurn(in: replay, prompt: Self.firstPrompt, response: responses[0])
        let aside = try resumed.directory.appendingPathComponent(
          SessionHistoryFile.unreadableFileName, isDirectory: false)
        #expect(try Data(contentsOf: aside) == Self.badBytes)
        let written = try #require(try SessionHistoryFile.read(from: resumed.directory))
        #expect(
          ReplayedMessage.replayed(in: written.replayUpdates(from: .start))
            == ReplayedMessage.replayed(in: replay))
      })
  }

  /// (c) The rebuilt updates come in the order of the entries in the Router journal, over two
  /// turns.
  @Test func theRebuiltUpdatesKeepTheOrderOfTheTranscriptEntries() async throws {
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt, Self.secondPrompt],
      damage: { file in try FileManager.default.removeItem(at: file) },
      read: { _, replay, responses, events in
        let expected = Self.kinds(of: events)
        #expect(
          expected == [.user, .thought, .toolCall, .agent, .user, .thought, .toolCall, .agent])
        #expect(Self.kinds(of: replay) == expected)
        let users = ReplayedMessage.replayed(in: replay).filter { $0.kind == .user }
        let userIds: [String] = users.map(\.id)
        let responseIds: [String] = responses.map(\.messageId.rawValue)
        #expect(userIds == responseIds)
      })
  }

  // MARK: - The rebuild of a journal

  /// The events of one journal, as Router writes them, for the rebuild proofs.
  struct JournalBuilder {
    /// The router of the events.
    let routerId = ULID.generate()

    /// The session of the events.
    let sessionId = ULID.generate()

    /// The events so far.
    private(set) var events: [TranscriptEvent] = []

    /// Adds the event of one SDK entry.
    ///
    /// - Parameters:
    ///   - entry: The entry.
    ///   - extraSegments: Segments that Router adds to the entry, for example the mail records of
    ///     a `.prompt` entry.
    mutating func add(_ entry: Transcript.Entry, adding extraSegments: [SegmentPayload] = []) {
      let mapped = TranscriptEntryMapper.event(from: entry)
      add(
        kind: mapped.kind, text: mapped.text,
        entry: mapped.payload.appendingSegments(extraSegments))
    }

    /// Adds one event.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - text: The text of the event.
    ///   - entry: The entry of the event.
    mutating func add(kind: TranscriptEvent.Kind, text: String?, entry: TranscriptEntryPayload) {
      events.append(
        TranscriptEvent(
          routerId: routerId, sessionId: sessionId, seq: events.count,
          ts: Date(timeIntervalSinceReferenceDate: Double(events.count)), kind: kind, text: text,
          entry: entry))
    }

    /// The mail record segment that delivers the user message `prompt` with the id `mail`.
    ///
    /// - Parameters:
    ///   - prompt: The text of the message.
    ///   - mail: The id of the mail.
    /// - Returns: The segment.
    static func delivery(of prompt: String, mail: MailID) -> SegmentPayload {
      let record = MailRecord.mailDelivered(
        Mail(
          id: mail, sender: .user,
          body: .userMessage(prompt: prompt, options: UserMessageOptions())))
      let segment = MailRecordSegment(content: record).transcriptSegment
      return TranscriptEntryMapper.event(from: .prompt(Transcript.Prompt(segments: [segment])))
        .payload.segments?.first ?? .text(id: "", content: "")
    }
  }

  /// (c) The rebuild keeps the order of the journal, also when a `.response` entry comes before
  /// the `.reasoning` entry of its pass, as a live MLX model records them. The summary entry of a
  /// compaction gives the compaction entry and no message. A `promptStarted` marker with no
  /// `.prompt` entry (a stop of the process during the turn) gives its user message, one time.
  @Test func theRebuildKeepsTheJournalOrderAndTheMessagesAroundACompaction() async throws {
    let firstMail = MailID()
    let secondMail = MailID()
    let callId = "call-1"
    let checkpointId = "checkpoint-1"
    var journal = JournalBuilder()
    journal.add(
      .prompt(
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Question one"))])),
      adding: [JournalBuilder.delivery(of: "Question one", mail: firstMail)])
    journal.add(
      .response(
        Transcript.Response(segments: [.text(Transcript.TextSegment(content: "Answer one."))])))
    journal.add(
      .reasoning(
        Transcript.Reasoning(
          id: UUID().uuidString, segments: [.text(Transcript.TextSegment(content: "Thought one."))],
          signature: nil)))
    journal.add(
      .toolCalls(
        Transcript.ToolCalls([
          Transcript.ToolCall(
            id: callId, toolName: "note", arguments: try GeneratedContent(json: #"{"label":"a"}"#))
        ])))
    journal.add(
      .toolOutput(
        Transcript.ToolOutput(
          id: callId, toolName: "note", segments: [.text(Transcript.TextSegment(content: "out"))])))
    journal.add(
      CompactionSegment.boundaryEntry(
        id: "compaction-summary-1", summaryText: "The summary.",
        content: CompactionSegment.Content(
          liveWindowEntryIds: [], compactedEntryIds: [], tokensBefore: 900, tokensAfter: 300,
          stagesApplied: [Summarization.stageName], promptName: "default"),
        checkpointId: checkpointId))
    let marker = JournalBuilder.delivery(of: "Question two", mail: secondMail)
    journal.add(
      kind: .promptStarted, text: "Question two",
      entry: TranscriptEntryPayload(entryId: "prompt-started-1", segments: [marker]))
    journal.add(
      .reasoning(
        Transcript.Reasoning(
          id: UUID().uuidString, segments: [.text(Transcript.TextSegment(content: "Thought two."))],
          signature: nil)))

    let history = await RecordedHistoryRebuild.history(
      from: journal.events, sessionId: SessionId(rawValue: journal.sessionId.description))
    let replay = history.replayUpdates(from: .start)

    let order: [String] = replay.compactMap { update in
      switch update {
      case .userMessage(let message): "user:\(message.messageId.rawValue)"
      case .agentMessage: "agent"
      case .agentThought: "thought"
      case .toolCallUpdate(let call): "tool:\(call.toolCallId.rawValue)"
      case .compactionUpdate(let compaction): "compaction:\(compaction.compactionId.rawValue)"
      default: nil
      }
    }
    #expect(
      order == [
        "user:\(firstMail.description)", "agent", "thought", "tool:\(callId)",
        "compaction:\(checkpointId)", "user:\(secondMail.description)", "thought",
      ])
    let texts: [String] = ReplayedMessage.replayed(in: replay).map(\.text)
    #expect(
      texts == ["Question one", "Answer one.", "Thought one.", "Question two", "Thought two."])
    let call = Self.toolCallUpdates(of: callId, in: replay)
    #expect(call.count == 1)
    #expect(call.first?.status == .value(.completed))
    let compaction = replay.compactMap { update -> CompactionUpdate? in
      guard case .compactionUpdate(let compaction) = update else { return nil }
      return compaction
    }.first
    #expect(compaction?.status == .completed)
    #expect(
      Self.firstBlock(of: compaction?.summary) == .text(TextContent(text: "The summary.")))
  }
}
