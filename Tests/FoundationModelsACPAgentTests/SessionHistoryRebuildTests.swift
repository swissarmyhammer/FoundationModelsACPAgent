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

  /// An action command of the agent: it runs with no model call.
  private static let statusCommand = "/status"

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

  /// A command of the agent that runs with no model call, such as `/status`, is in the rebuilt
  /// history too: its user message with the id of its prompt response, and its reply. Router
  /// records the exchange in the journal (`commandExchange`).
  @Test func anActionCommandReplaysFromTheTranscript() async throws {
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt, Self.statusCommand],
      damage: { file in try FileManager.default.removeItem(at: file) },
      read: { _, replay, responses, _ in
        let messages = ReplayedMessage.replayed(in: replay)
        let kinds: [ReplayedMessage.Kind] = messages.map(\.kind)
        #expect(kinds == [.user, .thought, .agent, .user, .agent], "the replay holds \(messages)")
        let command = messages.dropFirst(3).first
        #expect(command?.text == Self.statusCommand)
        #expect(command?.id == responses[1].messageId.rawValue)
        #expect(messages.last?.text.isEmpty == false)
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

  /// (d) A history file of a build before ACPAgent 5f5af47a holds the thoughts of a turn after
  /// its tool call and its answer, and records no order of the model. The resume replays each
  /// thought in the order of the journal: thought, tool call, message (Testudo ^ras4xe9). Each
  /// thought keeps its id, and the resume writes the file again in the order of the model.
  @Test func anOldFormatFileReplaysEachThoughtBeforeItsToolCallAndItsAnswer() async throws {
    var thoughtIds: [String] = []
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt, Self.secondPrompt],
      damage: { file in
        try Self.writeOldFormat(of: file)
        let damaged = try #require(try SessionHistoryFile.read(from: file.deletingLastPathComponent()))
        let replayed = damaged.replayUpdates(from: .start)
        #expect(
          Self.kinds(of: replayed)
            == [.user, .toolCall, .agent, .thought, .user, .toolCall, .agent, .thought])
        thoughtIds = ReplayedMessage.replayed(in: replayed).filter { $0.kind == .thought }.map(\.id)
      },
      read: { resumed, replay, _, _ in
        #expect(
          Self.kinds(of: replay)
            == [.user, .thought, .toolCall, .agent, .user, .thought, .toolCall, .agent])
        let ids: [String] = ReplayedMessage.replayed(in: replay).filter { $0.kind == .thought }
          .map(\.id)
        #expect(ids == thoughtIds)
        let written = try #require(try SessionHistoryFile.readFile(from: resumed.directory))
        #expect(written.recordsModelOrder)
        #expect(Self.kinds(of: written.history.replayUpdates(from: .start)) == Self.kinds(of: replay))
      })
  }

  /// (e) A history file that holds fewer turns than the Router journal (a build before ACPAgent
  /// 44850640 wrote the file only at the end of a turn) replays each turn of the journal: the
  /// turn that the file lacks comes after the turns of the file (Testudo ^fgbds9q).
  @Test func aFileWithFewerTurnsReplaysEachTurnOfTheTranscript() async throws {
    try await Self.resumeAfterDamage(
      prompts: [Self.firstPrompt, Self.secondPrompt],
      damage: { file in
        let directory = file.deletingLastPathComponent()
        let full = try #require(try SessionHistoryFile.read(from: directory))
        let users = full.entries.indices.filter {
          if case .userMessage = full.entries[$0].kind { return true }
          return false
        }
        let cut = try #require(users.dropFirst().first)
        try SessionHistoryFile.write(
          SessionMergeEngine(replaying: full.transcriptUpdates.prefix(cut) + full.stateUpdates),
          in: directory)
      },
      read: { resumed, replay, responses, _ in
        let messages = ReplayedMessage.replayed(in: replay)
        let kinds: [ReplayedMessage.Kind] = messages.map(\.kind)
        #expect(kinds == [.user, .thought, .agent, .user, .thought, .agent], "the replay holds \(messages)")
        let texts: [String] = messages.map(\.text)
        #expect(
          texts == [
            Self.firstPrompt, Self.thoughtText, Self.answerText, Self.secondPrompt,
            Self.thoughtText, Self.answerText,
          ])
        let userIds: [String] = messages.filter { $0.kind == .user }.map(\.id)
        #expect(userIds == responses.map(\.messageId.rawValue))
        let written = try #require(try SessionHistoryFile.read(from: resumed.directory))
        #expect(
          ReplayedMessage.replayed(in: written.replayUpdates(from: .start))
            == ReplayedMessage.replayed(in: replay))
      })
  }

  /// Writes the history file `file` again as a build before ACPAgent 5f5af47a wrote it: with no
  /// `recordsModelOrder` member, and with each thought of a turn after the agent message of the
  /// turn.
  ///
  /// - Parameter file: The history file.
  /// - Throws: The error of the read or of the write.
  private static func writeOldFormat(of file: URL) throws {
    var contents = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    contents.removeValue(forKey: "recordsModelOrder")
    var updates = try #require(contents["updates"] as? [[String: Any]])
    var index = 0
    while index < updates.count {
      guard updates[index]["sessionUpdate"] as? String == "agent_thought",
        let message = updates[index...].firstIndex(where: {
          $0["sessionUpdate"] as? String == "agent_message"
        })
      else {
        index += 1
        continue
      }
      let thought = updates.remove(at: index)
      updates.insert(thought, at: message)
      index = message + 1
    }
    contents["updates"] = updates
    try JSONSerialization.data(withJSONObject: contents).write(to: file, options: .atomic)
  }

  /// A `.prompt` entry with no mail record (the prompt of a copied external session) gives a
  /// user message with the id of the entry, when the rebuild reads such prompts. Else it gives no
  /// message (Testudo ^fgbds9q).
  @Test func aCopiedPromptGivesAUserMessageWithTheIdOfItsEntry() async throws {
    var journal = JournalBuilder()
    journal.add(
      .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Fix the test."))])))
    journal.add(
      .response(
        Transcript.Response(segments: [.text(Transcript.TextSegment(content: "It passes."))])))
    let sessionId = SessionId(rawValue: journal.sessionId.description)
    let entryId = try #require(journal.events.first?.entry?.entryId)

    let copied = await RecordedHistoryRebuild.rebuilt(
      from: journal.events, sessionId: sessionId, readsUnmailedPrompts: true)
    let live = await RecordedHistoryRebuild.rebuilt(from: journal.events, sessionId: sessionId)

    let messages = ReplayedMessage.replayed(in: copied.history.replayUpdates(from: .start))
    let kinds: [ReplayedMessage.Kind] = messages.map(\.kind)
    #expect(kinds == [.user, .agent])
    #expect(messages.first?.id == entryId)
    #expect(messages.first?.text == "Fix the test.")
    #expect(copied.mailMessageIds.isEmpty)
    let liveKinds: [ReplayedMessage.Kind] =
      ReplayedMessage.replayed(in: live.history.replayUpdates(from: .start)).map(\.kind)
    #expect(liveKinds == [.agent])
  }

  /// The shape of the journal of the "jensen" session (Testudo ^ras4xe9): a user mail, then four
  /// steps of an empty response, a reasoning entry, a tool call and its output, then the answer
  /// and the last reasoning entry after it. A thought shows where it starts: before the text and
  /// the tool calls of its step. The rebuild gives this order, and an old-format file with each
  /// thought after the answer takes it too, with the same ids.
  @Test func theJournalOfTheJensenShapeReplaysEachThoughtWhereItStarts() async throws {
    let mail = MailID()
    var journal = JournalBuilder()
    journal.add(
      .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Tell me."))])),
      adding: [JournalBuilder.delivery(of: "Tell me.", mail: mail)])
    func reasoning(_ text: String) -> Transcript.Entry {
      .reasoning(
        Transcript.Reasoning(
          id: UUID().uuidString, segments: [.text(Transcript.TextSegment(content: text))],
          signature: nil))
    }
    var expected = ["user:\(mail.description)"]
    for step in 1...4 {
      journal.add(.response(Transcript.Response(segments: [])))
      journal.add(reasoning("Thought \(step)."))
      journal.add(
        .toolCalls(
          Transcript.ToolCalls([
            Transcript.ToolCall(
              id: "call-\(step)", toolName: "note",
              arguments: try GeneratedContent(json: #"{"label":"a"}"#))
          ])))
      journal.add(
        .toolOutput(
          Transcript.ToolOutput(
            id: "call-\(step)", toolName: "note",
            segments: [.text(Transcript.TextSegment(content: "out \(step)"))])))
      expected += ["thought:Thought \(step).", "tool:call-\(step)"]
    }
    journal.add(
      .response(
        Transcript.Response(segments: [.text(Transcript.TextSegment(content: "The answer."))])))
    journal.add(reasoning("Thought 5."))
    expected += ["thought:Thought 5.", "agent:The answer."]
    func order(of history: SessionMergeEngine) -> [String] {
      history.replayUpdates(from: .start).compactMap { update in
        switch update {
        case .userMessage(let message): "user:\(message.messageId.rawValue)"
        case .agentThought, .agentMessage:
          ReplayedMessage.replayed(in: [update]).first.map {
            "\($0.kind == .thought ? "thought" : "agent"):\($0.text)"
          }
        case .toolCallUpdate(let call): "tool:\(call.toolCallId.rawValue)"
        default: nil
        }
      }
    }

    let rebuilt = await RecordedHistoryRebuild.rebuilt(
      from: journal.events, sessionId: SessionId(rawValue: journal.sessionId.description))
    #expect(order(of: rebuilt.history) == expected)

    let updates = rebuilt.history.transcriptUpdates
    let isThought: (SessionUpdate) -> Bool = {
      if case .agentThought = $0 { return true }
      return false
    }
    let isAnswer: (SessionUpdate) -> Bool = {
      if case .agentMessage = $0 { return true }
      return false
    }
    var oldFormat = updates.filter { !isThought($0) }
    let movedAnswer = try #require(oldFormat.firstIndex(where: isAnswer))
    oldFormat.insert(contentsOf: updates.filter(isThought), at: movedAnswer + 1)
    let file = SessionMergeEngine(replaying: oldFormat + rebuilt.history.stateUpdates)
    #expect(order(of: file) != expected)

    let merged = RecordedHistoryMerge.merged(
      SessionHistoryFile.Read(history: file, recordsMailDelivery: true, recordsModelOrder: false),
      with: rebuilt)
    #expect(order(of: merged) == expected)
    #expect(Set(merged.entries.map(\.id)) == Set(file.entries.map(\.id)))
  }

  /// The rendered pending envelope of a run, as the tool returns it.
  ///
  /// - Parameter token: The completion token of the run.
  /// - Returns: The rendered envelope.
  /// - Throws: The error of the encode.
  private static func renderedEnvelope(token: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let next = try #require(
      String(
        data: try encoder.encode(
          PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: token)),
        encoding: .utf8))
    let envelope = #"{"pending":true,"completionToken":"\#(token)","next":\#(next)}"#
    #expect(PendingRunEnvelope.isRendered(text: envelope))
    return envelope
  }

  /// The journal of a background call of the `agent` tool: the prompt, the marker of the start
  /// of the call with the token of its run, the run event that holds the pending envelope, the
  /// call, and the SDK output of the call.
  ///
  /// - Parameters:
  ///   - callId: The id of the call.
  ///   - token: The token of the run.
  ///   - output: The text of the SDK output of the call.
  ///   - end: The outcome of the end event of the run, or `nil` for a run with no end.
  /// - Returns: The journal.
  /// - Throws: The error of the arguments of the call.
  private static func backgroundCallJournal(
    callId: String, token: String, output: String, end: OperationOutcome?
  ) throws -> JournalBuilder {
    var journal = JournalBuilder()
    journal.add(
      .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Run it."))])),
      adding: [JournalBuilder.delivery(of: "Run it.", mail: MailID())])
    journal.add(
      kind: .toolCallStarted, text: nil,
      entry: TranscriptEntryPayload(
        entryId: "started-call-\(callId)",
        toolCalls: [
          ToolCallPayload(id: callId, toolName: "agent", argumentsJSON: "{}", correlationID: token)
        ]))
    journal.addRunEvent(
      OperationEvent(
        tool: "agent", op: "run agent", correlationID: token, kind: .progress,
        detail: try renderedEnvelope(token: token)))
    journal.add(
      .toolCalls(
        Transcript.ToolCalls([
          Transcript.ToolCall(id: callId, toolName: "agent", arguments: try GeneratedContent(json: "{}"))
        ])))
    journal.add(
      .toolOutput(
        Transcript.ToolOutput(
          id: callId, toolName: "agent", segments: [.text(Transcript.TextSegment(content: output))])))
    if let end {
      journal.addRunEvent(
        OperationEvent(
          tool: "agent", op: "run agent", correlationID: token, kind: .completed, detail: "Done.",
          outcome: end))
    }
    return journal
  }

  /// The status of the call `callId` in the rebuild of `journal`.
  ///
  /// - Parameters:
  ///   - callId: The id of the call.
  ///   - journal: The journal.
  /// - Returns: The status of the one entry of the call, or `nil` when the history has no entry.
  private static func rebuiltStatus(of callId: String, in journal: JournalBuilder) async
    -> PatchField<FoundationModelsACP.ToolCallStatus>?
  {
    let rebuilt = await RecordedHistoryRebuild.rebuilt(
      from: journal.events, sessionId: SessionId(rawValue: journal.sessionId.description))
    return rebuilt.history.entries.compactMap { entry -> ToolCallUpdate? in
      guard case .toolCall(let call) = entry.kind, call.toolCallId.rawValue == callId else {
        return nil
      }
      return call
    }.first?.status
  }

  /// A background call whose run did not end in the journal stays open in the rebuild, as it
  /// does live. The stop of the process can record an SDK output of the call before the stop:
  /// the pending envelope, or the text of the cancel of the call by the shutdown. The replay of
  /// a resume must then still give the open call (Testudo ^e664zq).
  @Test(arguments: ["envelope", "Agent worker was cancelled."])
  func aBackgroundCallWhoseRunDidNotEndStaysOpen(output: String) async throws {
    let token = ULID.generate().description
    let text = output == "envelope" ? try Self.renderedEnvelope(token: token) : output
    let journal = try Self.backgroundCallJournal(
      callId: "call-1", token: token, output: text, end: nil)

    #expect(await Self.rebuiltStatus(of: "call-1", in: journal) == .value(.inProgress))
  }

  /// A background call whose run ended in the journal gets the status of the end of the run, as
  /// it does live.
  @Test func aBackgroundCallWhoseRunEndedGetsTheStatusOfTheEnd() async throws {
    let token = ULID.generate().description
    let succeeded = try Self.backgroundCallJournal(
      callId: "call-1", token: token, output: try Self.renderedEnvelope(token: token),
      end: .succeeded)
    let failed = try Self.backgroundCallJournal(
      callId: "call-1", token: token, output: try Self.renderedEnvelope(token: token),
      end: .failed)

    #expect(await Self.rebuiltStatus(of: "call-1", in: succeeded) == .value(.completed))
    #expect(await Self.rebuiltStatus(of: "call-1", in: failed) == .value(.failed))
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

    /// Adds the `.toolOutput` entry that records one event of a run, as Router writes it.
    ///
    /// - Parameter event: The event of the run.
    mutating func addRunEvent(_ event: OperationEvent) {
      let segment = OperationEventSegment(content: event).transcriptSegment
      add(
        .toolOutput(
          Transcript.ToolOutput(id: ULID.generate().description, toolName: event.tool, segments: [segment])))
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

  /// (c) The rebuild keeps the order of the journal, but a `.reasoning` entry that follows a
  /// `.response` entry of its round (the order that a live MLX model records) comes before the
  /// response: the model thinks before it answers (Testudo ^ras4xe9). The summary entry of a
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
        "user:\(firstMail.description)", "thought", "agent", "tool:\(callId)",
        "compaction:\(checkpointId)", "user:\(secondMail.description)", "thought",
      ])
    let texts: [String] = ReplayedMessage.replayed(in: replay).map(\.text)
    #expect(
      texts == ["Question one", "Thought one.", "Answer one.", "Question two", "Thought two."])
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
