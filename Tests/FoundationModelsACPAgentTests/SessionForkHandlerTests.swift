import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The fork of `session/fork` through the session directory of the Router (D205): the copied
/// turns, the refusals of a cut, the replay of a fork, and the `fork session` operation of the
/// `sessions` tool.
@Suite(.closesHarnesses) struct SessionForkHandlerTests {
  // MARK: - Constants

  /// The prompt of turn 1.
  private static let firstPrompt = "Turn one"

  /// The prompt of turn 2.
  private static let secondPrompt = "Turn two"

  /// The prompt of turn 3, which holds until the test releases it.
  private static let thirdPrompt = "Turn three"

  /// The text of the first message of the session directory, which comes while turn 3 runs.
  private static let firstNote = "Note one"

  /// The text of the second message of the session directory, which comes while turn 3 runs.
  private static let secondNote = "Note two"

  /// The text of the answer to the batch of the two messages of the session directory.
  private static let notesReply = "Notes read"

  /// The client id of the user who sends the messages of the session directory.
  private static let noteClientID = "SessionForkHandlerTests-client"

  /// The action command that runs between two prompts.
  private static let helpCommand = "/help"

  /// The text of the agent message of turn 2.
  private static let secondText = "Second"

  /// The prompt whose answer starts the gated background run.
  private static let runPrompt = "Start a run"

  /// The text of the answer that starts the gated background run.
  private static let runStartedText = "Run started"

  /// The text of the answer to the result of the gated run. Router keeps back the text of an
  /// answer that only mail started, so the test waits for ``AnswerSignalTool`` and not for this
  /// text.
  private static let runAnswerPartialText = "Run answer partial"

  /// The prompts of the suite, in the order of a session that runs each one.
  private static let knownPrompts = [
    firstPrompt, secondPrompt, thirdPrompt, firstNote, secondNote, runPrompt,
  ]

  /// The prompt that runs a tool.
  private static let toolPrompt = "Run a tool"

  /// The prompt whose answer calls `fork session` with no id.
  private static let forkPrompt = "Fork here"

  /// The text that the answer of turn 3 sends before it holds.
  private static let thirdPartialText = "Third partial"

  /// The text that the answer of turn 3 sends after the release.
  private static let thirdFinalText = "Third final"

  /// The name of the `sessions` tool.
  private static let sessionsToolName = "sessions"

  /// The arguments of a `fork session` call with no id.
  private static let forkSessionArguments = #"{"op":"fork session"}"#

  /// The prompt whose answer calls `fork session` with no id and with a first prompt.
  private static let forkWithPromptPrompt = "Fork with a first prompt"

  /// The first prompt of the fork that ``forkWithPromptPrompt`` makes.
  private static let forkFirstPrompt = "Work in the fork"

  /// The text of the answer to the first prompt of the fork. It comes after the hold.
  private static let forkAnswerText = "Fork answer"

  /// The arguments of a `fork session` call with no id and with ``forkFirstPrompt``.
  private static let forkSessionWithPromptArguments =
    #"{"op":"fork session","message":"\#(forkFirstPrompt)"}"#

  /// The prompt whose answer sends ``heldText`` and then calls `fork session` with no id.
  private static let heldForkPrompt = "Fork after the held text"

  /// The text that the answer of ``heldForkPrompt`` sends before its `fork session` call. The
  /// agent end of the wire keeps the frame of this text, so the projector of the source waits in
  /// that send, and the record of the call that forks is late. The answer holds after the text
  /// until the wire keeps its frame: the Router can give the text to the projector after the
  /// event of a call that comes later.
  private static let heldText = "HELD-TEXT-BEFORE-THE-FORK"

  /// The time limit of the record of the calling tool call in a test where the record never
  /// comes.
  private static let shortRecordTimeLimit = Duration.milliseconds(300)

  /// The time between two looks at the recording folder of the source.
  private static let forkNodeLookInterval = Duration.milliseconds(10)

  /// The most looks at the recording folder of the source in one wait.
  private static let forkNodeLookLimit = 2_000

  /// The name of the record file of a session folder.
  private static let indexFileName = "index.md"

  /// The snippet that the tool prompt runs.
  private static let toolCode = "1 + 1"

  /// The label of the directories of this suite.
  private static let label = "SessionForkHandlerTests"

  /// The number of idle updates after two completed turns.
  private static let twoTurns = 2

  /// The number of idle updates after three completed turns.
  private static let threeTurns = 3

  /// A message id that no history holds.
  private static let unknownMessageId = MessageId(rawValue: "no-such-message")

  /// The session that the refusal tests name.
  private static let sampleSessionId = SessionId(rawValue: "SessionForkHandlerTests-sample")

  /// The index of turn 2 of the sample history with a compaction.
  private static let secondTurn = 1

  /// The index of turn 3 of the sample history with a compaction.
  private static let thirdTurn = 2

  /// A turn index that the sample history with a compaction does not have.
  private static let missingTurn = 9

  /// The MCP server of the client of the source. Its command is not an absolute path, so the
  /// server does not start, and the session still opens.
  private static let sourceServer = FoundationModelsACP.MCPServer.stdio(
    MCPServerStdio(command: AbsolutePath(rawValue: "fork-test-server"), name: "fork-test-server"))

  /// The MCP server of a `session/fork` request, which the source does not have.
  private static let requestServer = FoundationModelsACP.MCPServer.stdio(
    MCPServerStdio(
      command: AbsolutePath(rawValue: "fork-request-server"), name: "fork-request-server"))

  // MARK: - Fixtures

  /// The script of the suite: one answer for each prompt.
  ///
  /// - Parameter hold: The hold of the answer of turn 3, of the answer to the result of the gated
  ///   run, and of the answer to the first prompt of a tool fork.
  /// - Returns: The script.
  /// - Throws: The encode error of the tool call.
  private static func script(holding hold: ScriptedHold = ScriptedHold()) throws
    -> [ScriptedPassStep]
  {
    [
      .onPrompt(containing: firstPrompt, play: [.textDelta("First"), .endPass]),
      .onPrompt(containing: secondPrompt, play: [.textDelta(secondText), .endPass]),
      .onPrompt(
        containing: thirdPrompt,
        play: [
          .textDelta(thirdPartialText), .holdUntilReleased(hold), .textDelta(thirdFinalText),
          .endPass,
        ]),
      .onPrompt(
        containing: toolPrompt,
        play: [try ScriptedPromptFixture.makeRunCodeCall(code: toolCode), .endPass]),
      .onPrompt(
        containing: forkPrompt,
        play: [.toolCall(name: sessionsToolName, argumentsJSON: forkSessionArguments), .endPass]),
      .onPrompt(
        containing: forkWithPromptPrompt,
        play: [
          .toolCall(name: sessionsToolName, argumentsJSON: forkSessionWithPromptArguments),
          .endPass,
        ]),
      .onPrompt(
        containing: forkFirstPrompt,
        play: [.holdUntilReleased(hold), .textDelta(forkAnswerText), .endPass]),
      .onPrompt(
        containing: heldForkPrompt,
        play: [
          .textDelta(heldText), .holdUntilReleased(hold),
          .toolCall(name: sessionsToolName, argumentsJSON: forkSessionArguments), .endPass,
        ]),
      .onPrompt(containing: firstNote, play: [.textDelta(notesReply), .endPass]),
      .onPrompt(
        containing: runPrompt,
        play: [
          .toolCall(name: GatedRunTool.toolName, argumentsJSON: "{}"), .textDelta(runStartedText),
          .endPass,
        ]),
      .onPrompt(
        containing: GatedRunTool.toolName,
        play: [
          .textDelta(runAnswerPartialText),
          .toolCall(name: AnswerSignalTool.toolName, argumentsJSON: "{}"),
          .holdUntilReleased(hold), .endPass,
        ]),
      .endPass,
    ]
  }

  /// A fixture over the script of the suite.
  ///
  /// - Parameters:
  ///   - name: The name of the test, for the directories.
  ///   - hold: The hold of the answer of turn 3.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction throws.
  private static func makeFixture(_ name: String, holding hold: ScriptedHold = ScriptedHold())
    async throws -> ScriptedPromptFixture
  {
    try await ScriptedPromptFixture.make(
      script: try script(holding: hold), label: "\(label)-\(name)")
  }

  /// Runs turn 1 and turn 2 in the session of `fixture`.
  ///
  /// - Parameter fixture: The fixture.
  /// - Throws: Whatever a prompt throws.
  private static func runTwoTurns(on fixture: ScriptedPromptFixture) async throws {
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: firstPrompt)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: secondPrompt, count: twoTurns)
  }

  /// Runs turns 1 to 3, and sends two messages through the session directory while turn 3 runs.
  /// The session gets the two messages in one batch when turn 3 ends.
  ///
  /// - Parameters:
  ///   - fixture: The fixture.
  ///   - hold: The hold of the answer of turn 3.
  /// - Throws: Whatever a prompt, a send or a wait throws.
  private static func runBatch(on fixture: ScriptedPromptFixture, holding hold: ScriptedHold)
    async throws
  {
    try await runTwoTurns(on: fixture)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: thirdPrompt))
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the partial answer of turn 3"
    ) { ScriptedPromptFixture.agentChunkTexts(in: $0).contains(thirdPartialText) }
    let target = try #require(ULID(ulidString: fixture.sessionId.rawValue))
    for note in [firstNote, secondNote] {
      _ = try await fixture.harness.agent.sessionDirectory.send(
        OutgoingSessionMessage(
          from: .user(clientID: noteClientID), to: .session(target), text: note))
    }
    hold.release()
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the answer of the batch and the view of each message"
    ) { updates in
      ScriptedPromptFixture.agentChunkTexts(in: updates).contains(notesReply)
        && sessionMessageTexts(of: updates.map(\.update)).contains(secondNote)
    }
  }

  /// The text of each message between sessions of a sequence of updates, in order.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The texts.
  private static func sessionMessageTexts(of updates: [SessionUpdate]) -> [String] {
    sessionMessageTexts(of: SessionMergeEngine(replaying: updates))
  }

  /// The text of each message between sessions of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The texts.
  private static func sessionMessageTexts(of history: SessionMergeEngine) -> [String] {
    history.entries.compactMap { entry in
      guard case .sessionMessage(let message) = entry.kind else { return nil }
      return text(of: message.content)
    }
  }

  /// The id of the incoming view of the message of the session directory with a text.
  ///
  /// - Parameters:
  ///   - text: The text of the message.
  ///   - history: The history.
  /// - Returns: The id.
  /// - Throws: A failed requirement when the history has no such message.
  private static func sessionMessageId(_ text: String, in history: SessionMergeEngine) throws
    -> MessageId
  {
    try #require(
      history.entries.lazy.compactMap { entry -> MessageId? in
        guard case .sessionMessage(let message) = entry.kind, Self.text(of: message.content) == text
        else { return nil }
        return message.messageId
      }.first)
  }

  /// Runs the prompt that starts the gated background run, opens the gate of the run, and waits
  /// until the answer to the result of the run holds.
  ///
  /// - Parameters:
  ///   - name: The name of the test, for the directories.
  ///   - hold: The hold of the answer to the result of the run.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction, the prompt or a wait throws.
  private static func runResultAnswerRuns(_ name: String, holding hold: ScriptedHold)
    async throws -> ScriptedPromptFixture
  {
    let run = GatedRunTool()
    let signal = AnswerSignalTool()
    let fixture = try await ScriptedPromptFixture.make(
      script: try script(holding: hold), label: "\(label)-\(name)", hostTools: [run, signal],
      inlineSettleGrace: 0)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: runPrompt))
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the answer that started the run"
    ) { ScriptedPromptFixture.agentChunkTexts(in: $0).contains(runStartedText) }
    await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
    run.gate.update { $0 = true }
    _ = try await signal.reached.wait(for: "the answer to the run result") { $0 }
    return fixture
  }

  /// The user messages and the agent text of a fork.
  private struct ForkMessages: Equatable {
    /// The prompts of the suite that the fork holds, in order.
    let prompts: [String]

    /// The text of the agent, joined in order.
    let agentText: String
  }

  /// The messages of the ACP history that the agent copied for a fork: each user message and each
  /// message between sessions that is a prompt of the suite, and the agent messages.
  ///
  /// - Parameters:
  ///   - forkId: The fork.
  ///   - fixture: The fixture.
  /// - Returns: The messages.
  /// - Throws: A failed requirement when the table does not hold the fork.
  private static func copiedMessages(of forkId: SessionId, in fixture: ScriptedPromptFixture)
    async throws -> ForkMessages
  {
    let history = try await history(of: forkId, in: fixture)
    let agentText = history.entries.compactMap { entry -> String? in
      guard case .agentMessage(let message) = entry.kind else { return nil }
      return text(of: message.content)
    }.joined()
    let prompts = history.entries.compactMap { entry -> String? in
      switch entry.kind {
      case .userMessage(let message):
        return text(of: message.content)
      case .sessionMessage(let message):
        return text(of: message.content)
      default:
        return nil
      }
    }
    return ForkMessages(prompts: prompts.filter(knownPrompts.contains), agentText: agentText)
  }

  /// The messages of the Router journal of a fork: the prompts of the suite that each `.prompt`
  /// entry delivers, and the text of the `.response` entries.
  ///
  /// - Parameters:
  ///   - forkId: The fork.
  ///   - fixture: The fixture.
  /// - Returns: The messages.
  /// - Throws: A failed requirement when the table does not hold the fork.
  private static func routerMessages(of forkId: SessionId, in fixture: ScriptedPromptFixture)
    async throws -> ForkMessages
  {
    let session = try #require(await fixture.harness.agent.sessions[forkId]?.session)
    let transcript = Array(await session.transcript)
    let prompts = transcript.flatMap { entry -> [String] in
      guard case .prompt(let prompt) = entry else { return [] }
      let delivered = segmentText(of: prompt.segments)
      return knownPrompts.filter(delivered.contains)
    }
    let agentText = transcript.compactMap { entry -> String? in
      guard case .response(let response) = entry else { return nil }
      return segmentText(of: response.segments)
    }.joined()
    return ForkMessages(prompts: prompts, agentText: agentText)
  }

  /// The text segments of a transcript entry, joined.
  ///
  /// - Parameter segments: The segments.
  /// - Returns: The text.
  private static func segmentText(of segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined()
  }

  /// The id of the agent message with a text.
  ///
  /// - Parameters:
  ///   - text: The text of the message.
  ///   - history: The history.
  /// - Returns: The id.
  /// - Throws: A failed requirement when the history has no such message.
  private static func agentMessageId(_ text: String, in history: SessionMergeEngine) throws
    -> MessageId
  {
    try #require(
      history.entries.lazy.compactMap { entry -> MessageId? in
        guard case .agentMessage(let message) = entry.kind, Self.text(of: message.content) == text
        else { return nil }
        return message.messageId
      }.first)
  }

  /// Sends `session/fork` for the session of `fixture`.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the source session.
  ///   - cut: The message at the cut and its side, or `nil` for no cut.
  /// - Returns: The response.
  /// - Throws: The error of the request.
  private static func fork(
    _ fixture: ScriptedPromptFixture, cutting cut: (MessageId, SAH.ForkCut.Side)? = nil
  ) async throws -> ForkSessionResponse {
    let meta = try cut.map { try SAH.ForkCut(messageId: $0.0, side: $0.1).inject(into: nil) }
    return try await fixture.harness.connection.forkSession(
      ForkSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId, meta: meta))
  }

  /// Sends `session/fork` for the session of `fixture` with the MCP servers, the additional
  /// directories and the `cwd` of a request, and gives the table entry of the fork.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the source session.
  ///   - cwd: The `cwd` of the request, or `nil` for the folder of the source.
  ///   - mcpServers: The MCP servers of the request, or `nil` for none.
  ///   - additionalDirectories: The additional directories of the request, or `nil` for none.
  /// - Returns: The entry of the fork.
  /// - Throws: The error of the request, or a failed requirement when the table does not hold
  ///   the fork.
  private static func forkEntry(
    of fixture: ScriptedPromptFixture, cwd: URL? = nil,
    mcpServers: [FoundationModelsACP.MCPServer]? = nil,
    additionalDirectories: [AbsolutePath]? = nil
  ) async throws -> ActiveSession {
    let response = try await fixture.harness.connection.forkSession(
      ForkSessionRequest(
        cwd: AbsolutePath(rawValue: (cwd ?? fixture.cwd).path), sessionId: fixture.sessionId,
        additionalDirectories: additionalDirectories, mcpServers: mcpServers))
    return try #require(await fixture.harness.agent.sessions[response.sessionId])
  }

  /// Forks the session of `fixture` through the session directory with no cut, as a client does
  /// through the `sessions` endpoint, and gives the table entry of the fork.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the source session.
  ///   - client: The client that asks for the fork.
  /// - Returns: The entry of the fork.
  /// - Throws: The refusal of the session directory, or a failed requirement when the table does
  ///   not hold the fork.
  private static func directoryForkEntry(of fixture: ScriptedPromptFixture, client: ConnectionId)
    async throws -> ActiveSession
  {
    let summary = try await fixture.harness.agent.sessionDirectory.fork(
      SessionForkRequest(
        sourceID: try #require(ULID(ulidString: fixture.sessionId.rawValue)),
        cut: .lastCompletedTurn, requestedByClient: client.rawValue,
        forker: .user(clientID: client.rawValue)))
    return try #require(
      await fixture.harness.agent.sessions[SessionId(rawValue: summary.id.description)])
  }

  /// Runs `body` while a `session/fork` request of `client` for the session of `fixture`, with
  /// the MCP servers ``requestServer``, waits for its launcher.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the source session.
  ///   - client: The connection of the waiting request.
  ///   - body: The work to run while the request waits.
  /// - Returns: The result of `body`.
  /// - Throws: Whatever `body` throws.
  private static func whileForkRequestWaits<Result: Sendable>(
    in fixture: ScriptedPromptFixture, client: ConnectionId,
    _ body: @Sendable () async throws -> Result
  ) async throws -> Result {
    let requested = RequestedFork(
      placement: SessionPlacement(
        workingDirectory: fixture.cwd, additionalRoots: [], userPresence: .interactive,
        clientMCPServers: [requestServer]),
      copiedHistory: SessionMergeEngine(), caller: client)
    return try await fixture.harness.agent.whileForkRequestWaits(requested, body).result
  }

  /// The retained history of a session of the agent of `fixture`.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - fixture: The fixture.
  /// - Returns: The history.
  /// - Throws: A failed requirement when the table does not hold the session.
  private static func history(of sessionId: SessionId, in fixture: ScriptedPromptFixture)
    async throws -> SessionMergeEngine
  {
    try #require(await fixture.harness.agent.sessions[sessionId]?.history)
  }

  /// The text of each user message of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The texts.
  private static func userTexts(of history: SessionMergeEngine) -> [String] {
    history.entries.compactMap { entry in
      guard case .userMessage(let message) = entry.kind else { return nil }
      return text(of: message.content)
    }
  }

  /// The text of each user message of a sequence of updates, in order.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The texts.
  private static func userTexts(of updates: [SessionUpdate]) -> [String] {
    userTexts(of: SessionMergeEngine(replaying: updates))
  }

  /// The text blocks of a content list, joined.
  ///
  /// - Parameter content: The content.
  /// - Returns: The text.
  private static func text(of content: [ContentBlock]) -> String {
    content.compactMap { block in
      guard case .text(let text) = block else { return nil }
      return text.text
    }.joined()
  }

  /// The id of the first agent message of a history.
  ///
  /// - Parameter history: The history.
  /// - Returns: The id.
  /// - Throws: A failed requirement when the history has no agent message.
  private static func firstAgentMessageId(of history: SessionMergeEngine) throws -> MessageId {
    try #require(
      history.entries.lazy.compactMap { entry -> MessageId? in
        guard case .agentMessage(let message) = entry.kind else { return nil }
        return message.messageId
      }.first)
  }

  /// The id of the user message with a text.
  ///
  /// - Parameters:
  ///   - text: The text of the message.
  ///   - history: The history.
  /// - Returns: The id.
  /// - Throws: A failed requirement when the history has no such message.
  private static func userMessageId(_ text: String, in history: SessionMergeEngine) throws
    -> MessageId
  {
    try #require(
      history.entries.lazy.compactMap { entry -> MessageId? in
        guard case .userMessage(let message) = entry.kind, Self.text(of: message.content) == text
        else { return nil }
        return message.messageId
      }.first)
  }

  /// The forks that the session directory of the agent of `fixture` holds.
  ///
  /// - Parameters:
  ///   - fixture: The fixture.
  ///   - includesRecorded: `true` (the default) for the live and the recorded forks, `false` for
  ///     the live forks only.
  /// - Returns: The summaries of the forks.
  /// - Throws: The error of the query.
  private static func forks(
    in fixture: ScriptedPromptFixture, includesRecorded: Bool = true
  ) async throws -> [SessionSummary] {
    try await fixture.harness.agent.sessionDirectory.sessions(
      matching: SessionQuery(kind: .fork, includesRecorded: includesRecorded))
  }

  /// Runs a prompt whose answer calls `fork session`, and gives the fork that the call made.
  ///
  /// - Parameters:
  ///   - fixture: The fixture, after turn 1.
  ///   - prompt: The prompt whose answer calls `fork session`: ``forkPrompt`` by default.
  /// - Returns: The summary of the fork.
  /// - Throws: Whatever the prompt or the query throws.
  private static func forkFromTheTool(
    on fixture: ScriptedPromptFixture, prompt: String = forkPrompt
  ) async throws -> SessionSummary {
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: prompt, count: twoTurns)
    return try #require(try await forks(in: fixture).first)
  }

  /// A fixture over the script of the suite whose source session has one additional directory.
  ///
  /// - Parameters:
  ///   - directory: The additional directory of the source.
  ///   - name: The name of the test, for the directories.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction throws.
  private static func makeFixtureWithDirectory(_ directory: URL, name: String) async throws
    -> ScriptedPromptFixture
  {
    try await ScriptedPromptFixture.make(
      script: try script(), label: "\(label)-\(name)",
      additionalDirectories: [AbsolutePath(rawValue: directory.path)])
  }

  /// Runs turn 1, then the prompt whose answer calls `fork session`, and gives the id of the
  /// fork that the call made.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The id of the fork.
  /// - Throws: Whatever a prompt or the query throws.
  private static func toolForkAfterTurnOne(on fixture: ScriptedPromptFixture) async throws -> ULID
  {
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: firstPrompt)
    return try await forkFromTheTool(on: fixture).id
  }

  /// The recording folder of the source session of `fixture`, which holds the folder of each of
  /// its forks.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The folder.
  /// - Throws: A failed requirement when the table does not hold the source.
  private static func recordingFolder(of fixture: ScriptedPromptFixture) async throws -> URL {
    try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.transcriptDirectory)
  }

  /// The paths of the additional directories that the `index.md` record of a fork holds, as the
  /// file on disk holds them now.
  ///
  /// - Parameters:
  ///   - fork: The id of the fork.
  ///   - folder: The recording folder of the source of the fork.
  /// - Returns: The paths, in order.
  /// - Throws: The read error of a record, or a failed requirement when the folder holds no
  ///   record of the fork.
  private static func recordedDirectories(of fork: ULID, in folder: URL) throws -> [String] {
    let records = try RouterSessionDirectory.recordedSessions(in: folder)
    let record = try #require(records.first { $0.sessionId == fork })
    return record.additionalDirectories.map(\.path)
  }

  /// A source session whose agent end of the wire keeps the frame of ``heldText``.
  private struct HeldRecordSource {
    /// The fixture of the source, after turn 1.
    let fixture: ScriptedPromptFixture

    /// The agent end of the wire, which keeps the frame of ``heldText``.
    let holder: FrameHoldingTransport

    /// The hold of the answer of ``heldForkPrompt`` between ``heldText`` and the call.
    let hold: ScriptedHold

    /// The recording folder of the source, where the fork node of a tool fork is.
    let recordingFolder: URL
  }

  /// Makes a source session whose agent end of the wire keeps the frame of ``heldText``, and runs
  /// turn 1 in it.
  ///
  /// - Parameters:
  ///   - name: The name of the test, for the directories.
  ///   - recordTimeLimit: The time limit of the record of the calling tool call of a tool fork,
  ///     or `nil` for the limit of the agent.
  /// - Returns: The source.
  /// - Throws: Whatever the construction or the prompt throws, or a failed requirement when the
  ///   table does not hold the source.
  private static func makeHeldRecordSource(_ name: String, recordTimeLimit: Duration? = nil)
    async throws -> HeldRecordSource
  {
    let wire = HarnessWire.makeInMemory()
    let holder = FrameHoldingTransport(
      wrapping: wire.agentEnd, holdingFirstFrameContaining: heldText)
    let hold = ScriptedHold()
    let fixture = try await ScriptedPromptFixture.make(
      script: try script(holding: hold), label: "\(label)-\(name)",
      wire: wire.replacingAgentEnd(with: holder))
    if let recordTimeLimit {
      await fixture.harness.agent.useForkCallRecordTimeLimit(recordTimeLimit)
    }
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: firstPrompt)
    let folder = try #require(
      await fixture.harness.agent.sessions[fixture.sessionId]?.transcriptDirectory)
    return HeldRecordSource(
      fixture: fixture, holder: holder, hold: hold, recordingFolder: folder)
  }

  /// Runs ``heldForkPrompt`` in `source`: waits until the wire keeps the frame of ``heldText``,
  /// lets the answer go on to its call, runs `whileHeld`, lets the frame go, and waits until the
  /// prompt ends.
  ///
  /// - Parameters:
  ///   - source: The source.
  ///   - whileHeld: The work of the test while the wire keeps the frame.
  /// - Throws: Whatever the prompt, `whileHeld` or a wait throws.
  private static func runHeldForkPrompt(
    on source: HeldRecordSource, whileHeld: () async throws -> Void
  ) async throws {
    try await ScriptedPromptFixture.runPrompt(
      on: source.fixture, text: heldForkPrompt, count: twoTurns
    ) {
      defer {
        source.hold.release()
        source.holder.release()
      }
      await source.holder.waitUntilHolding()
      source.hold.release()
      try await whileHeld()
    }
  }

  /// Whether a recording folder holds a fork node: a folder with a record file.
  ///
  /// - Parameter folder: The recording folder of the source.
  /// - Returns: `true` when a fork node is there. A folder that does not exist holds no node.
  /// - Throws: The error of the listing of a folder that exists.
  private static func holdsForkNode(_ folder: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: folder.path) else {
      return false
    }
    let children = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    return children.contains { child in
      FileManager.default.fileExists(atPath: child.appendingPathComponent(indexFileName).path)
    }
  }

  /// Waits until the recording folder of the source holds a fork node or not, with a limit on
  /// the number of looks.
  ///
  /// - Parameters:
  ///   - folder: The recording folder of the source.
  ///   - present: `true` to wait for a fork node, `false` to wait until none is there.
  /// - Throws: The cancel of the wait, or the error of a listing of the folder.
  private static func waitForForkNode(in folder: URL, present: Bool) async throws {
    try await pollUntil(limit: forkNodeLookLimit, interval: forkNodeLookInterval) {
      try holdsForkNode(folder) == present
    }
  }

  /// The JSON text of each tool call of a history, in order: the merged update of the call, with
  /// its output.
  ///
  /// - Parameter history: The history.
  /// - Returns: The texts.
  /// - Throws: The error of an encode.
  private static func toolCallTexts(of history: SessionMergeEngine) throws -> [String] {
    try history.entries.compactMap { entry -> String? in
      guard case .toolCall(let call) = entry.kind else { return nil }
      return String(decoding: try JSONEncoder().encode(call), as: UTF8.self)
    }
  }

  /// Runs ``heldForkPrompt`` in a source whose record of the calling tool call never comes before
  /// the time limit: the wire keeps the frame of ``heldText`` until the session directory
  /// removed the refused fork node.
  ///
  /// - Parameter name: The name of the test, for the directories.
  /// - Returns: The source, after the prompt.
  /// - Throws: Whatever the source, the prompt or a wait throws.
  private static func runForkWithNoCallRecord(_ name: String) async throws -> HeldRecordSource {
    let source = try await makeHeldRecordSource(name, recordTimeLimit: shortRecordTimeLimit)
    try await runHeldForkPrompt(on: source) {
      try await waitForForkNode(in: source.recordingFolder, present: true)
      try await waitForForkNode(in: source.recordingFolder, present: false)
    }
    return source
  }

  /// The agent text of the updates of one session.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - updates: The updates that the client got.
  /// - Returns: The text of the agent message chunks of the session, in order.
  private static func agentChunkTexts(
    of sessionId: SessionId, in updates: [UpdateSessionNotification]
  ) -> [String] {
    ScriptedPromptFixture.agentChunkTexts(in: updates.filter { $0.sessionId == sessionId })
  }

  /// Resumes a session of the agent of `fixture` over the connection of `fixture`, with the
  /// replay from the start.
  ///
  /// - Parameters:
  ///   - sessionId: The session to resume.
  ///   - fixture: The fixture.
  /// - Returns: The updates of the session that the client got after the request, in order.
  /// - Throws: The error of the resume.
  private static func resume(_ sessionId: SessionId, in fixture: ScriptedPromptFixture)
    async throws -> [SessionUpdate]
  {
    let countBefore = await fixture.collector.updates.count
    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: sessionId,
        replayFrom: .start(ReplayFromStart())))
    return await fixture.collector.updates.dropFirst(countBefore)
      .filter { $0.sessionId == sessionId }.map(\.update)
  }

  /// The mails of the three turns of the sample history with a compaction.
  private static let compactedTurnMails = [MailID(), MailID(), MailID()]

  /// A history of three turns with a completed compaction after turn 2. The answer of turn 3 has
  /// no end, so it runs when the state of the source says so.
  private static var compactedHistory: SessionMergeEngine {
    let mails = compactedTurnMails
    func turn(_ index: Int, answer: String?) -> [SessionUpdate] {
      let mail = mails[index]
      let prompt = SessionUpdate.userMessage(
        UserMessage(
          messageId: MessageId(rawValue: mail.description),
          content: .value([.text(TextContent(text: "\(index)"))])))
      let delivered = MailDeliveryRecord.delivered(mail: mail, batch: mail, answer: mail).update
      guard let answer else { return [prompt, delivered] }
      return [
        prompt, delivered,
        .agentMessageChunk(
          ContentChunk(
            content: .text(TextContent(text: answer)), messageId: MessageId(rawValue: answer))),
        MailDeliveryRecord.answerEnded(answer: mail).update,
      ]
    }
    let compaction = SessionUpdate.compactionUpdate(
      CompactionUpdate(compactionId: CompactionId(rawValue: "c1"), status: .completed))
    return SessionMergeEngine(
      replaying: turn(0, answer: "a") + turn(1, answer: "b") + [compaction]
        + turn(2, answer: nil))
  }

  /// The refusal of a cut that the session directory found out of range, in the sample history
  /// with a compaction.
  ///
  /// - Parameters:
  ///   - point: The point of the cut.
  ///   - runsTurn: Whether the source runs a turn.
  /// - Returns: The text of the refusal.
  private static func outOfRangeText(of point: SessionForkPoint, runsTurn: Bool = false)
    -> String
  {
    RequestError.forkCutOutOfRange(
      point,
      in: ForkSourceHistory(
        history: compactedHistory, recipients: [sampleSessionId], runsTurn: runsTurn),
      id: sampleSessionId
    ).message
  }

  // MARK: - The capability

  /// `initialize` announces `fork` with `_meta.sah.forkCut = true`.
  @Test func initializeAnnouncesForkWithTheCutFlag() {
    #expect(
      SAH.ForkCut.isAdvertised(by: RoutedACPAgent.advertisedCapabilities(in: .open).session?.fork))
  }

  // MARK: - The cut

  /// With no cut, a fork of a session with two completed turns and one running turn has the two
  /// completed turns.
  @Test(.timeLimit(.minutes(1))) func noCutForksTheTwoCompletedTurns() async throws {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture("no-cut", holding: hold)
    defer { hold.release() }
    try await Self.runTwoTurns(on: fixture)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.thirdPrompt))
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the partial answer of turn 3"
    ) { ScriptedPromptFixture.agentChunkTexts(in: $0).contains(Self.thirdPartialText) }

    let fork = try await Self.fork(fixture)

    #expect(
      Self.userTexts(of: try await Self.history(of: fork.sessionId, in: fixture))
        == [Self.firstPrompt, Self.secondPrompt])
  }

  /// The running turn of the source goes on after a fork with no cut.
  @Test(.timeLimit(.minutes(1))) func theRunningTurnContinuesInTheSource() async throws {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture("running", holding: hold)
    try await Self.runTwoTurns(on: fixture)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.thirdPrompt))
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the partial answer of turn 3"
    ) { ScriptedPromptFixture.agentChunkTexts(in: $0).contains(Self.thirdPartialText) }
    _ = try await Self.fork(fixture)

    hold.release()
    let updates = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the final answer of turn 3"
    ) { ScriptedPromptFixture.agentChunkTexts(in: $0).contains(Self.thirdFinalText) }

    #expect(
      updates.contains { notification in
        guard notification.sessionId == fixture.sessionId,
          case .agentMessageChunk(let chunk) = notification.update,
          case .text(let text) = chunk.content
        else { return false }
        return text.text == Self.thirdFinalText
      })
  }

  /// A cut after the agent message of turn 1 forks turn 1 only.
  @Test(.timeLimit(.minutes(1))) func aCutAfterTheAgentMessageOfTurnOneForksTurnOne()
    async throws
  {
    let fixture = try await Self.makeFixture("after")
    try await Self.runTwoTurns(on: fixture)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)

    let fork = try await Self.fork(
      fixture, cutting: (try Self.firstAgentMessageId(of: source), .after))

    #expect(
      Self.userTexts(of: try await Self.history(of: fork.sessionId, in: fixture))
        == [Self.firstPrompt])
  }

  /// A cut before the user message of turn 2 forks turn 1 only.
  @Test(.timeLimit(.minutes(1))) func aCutBeforeTheUserMessageOfTurnTwoForksTurnOne()
    async throws
  {
    let fixture = try await Self.makeFixture("before")
    try await Self.runTwoTurns(on: fixture)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)
    let messageId = try Self.userMessageId(Self.secondPrompt, in: source)

    let fork = try await Self.fork(fixture, cutting: (messageId, .before))

    #expect(
      Self.userTexts(of: try await Self.history(of: fork.sessionId, in: fixture))
        == [Self.firstPrompt])
  }

  /// A cut on a message id that the source does not hold makes no fork.
  @Test(.timeLimit(.minutes(1))) func anUnknownMessageIdMakesNoFork() async throws {
    let fixture = try await Self.makeFixture("unknown")
    try await Self.runTwoTurns(on: fixture)

    _ = await #expect(throws: RequestError.self) {
      _ = try await Self.fork(fixture, cutting: (Self.unknownMessageId, .after))
    }

    #expect(try await Self.forks(in: fixture).isEmpty)
  }

  /// A cut in the turns that a compaction folded gets the text of a compacted part.
  @Test func aCutInTheCompactedTurnsGetsTheCompactedText() {
    #expect(
      Self.outOfRangeText(of: .beforeTurn(Self.secondTurn))
        == RequestError.compactedForkCutText)
  }

  /// A cut on a turn that does not exist gets a text that is not the text of a compacted part.
  @Test func aCutOnAMissingTurnGetsTheMissingTurnText() {
    #expect(
      Self.outOfRangeText(of: .afterTurn(Self.missingTurn)) == RequestError.missingForkTurnText)
  }

  /// A cut after the turn that runs gets the text of a running turn.
  @Test func aCutAfterTheRunningTurnGetsTheRunningTurnText() {
    #expect(
      Self.outOfRangeText(of: .afterTurn(Self.thirdTurn), runsTurn: true)
        == RequestError.runningForkTurnText)
  }

  // MARK: - The turn count of the session directory

  /// An action command between two prompts is no turn: a cut after the answer to the second
  /// prompt forks both prompts and the action command, as the session directory counts two turns.
  @Test(.timeLimit(.minutes(1))) func anActionCommandBetweenTwoPromptsIsNoTurnOfTheFork()
    async throws
  {
    let fixture = try await Self.makeFixture("action")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.helpCommand, count: 2)
    try await ScriptedPromptFixture.runPrompt(
      on: fixture, text: Self.secondPrompt, count: Self.threeTurns)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)

    let fork = try await Self.fork(
      fixture, cutting: (try Self.agentMessageId(Self.secondText, in: source), .after))

    #expect(
      Self.userTexts(of: try await Self.history(of: fork.sessionId, in: fixture))
        == [Self.firstPrompt, Self.helpCommand, Self.secondPrompt])
  }

  /// A cut before the second message of a batch of the session directory forks the same
  /// messages in the ACP copy and in the Router journal of the fork: the turns before the batch.
  @Test(.timeLimit(.minutes(1))) func aCutOnTheSecondMessageOfABatchCopiesTheRouterFork()
    async throws
  {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture("batch", holding: hold)
    defer { hold.release() }
    try await Self.runBatch(on: fixture, holding: hold)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)

    let fork = try await Self.fork(
      fixture, cutting: (try Self.sessionMessageId(Self.secondNote, in: source), .before))

    let copied = try await Self.copiedMessages(of: fork.sessionId, in: fixture)
    let forked = try await Self.routerMessages(of: fork.sessionId, in: fixture)

    #expect(copied == forked)
  }

  /// A cut before the second message of a batch of the session directory keeps no message of the
  /// batch.
  @Test(.timeLimit(.minutes(1))) func aCutOnTheSecondMessageOfABatchKeepsNoMessageOfTheBatch()
    async throws
  {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture("batch-turns", holding: hold)
    defer { hold.release() }
    try await Self.runBatch(on: fixture, holding: hold)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)

    let fork = try await Self.fork(
      fixture, cutting: (try Self.sessionMessageId(Self.secondNote, in: source), .before))

    let copied = try await Self.copiedMessages(of: fork.sessionId, in: fixture)

    #expect(copied.prompts == [Self.firstPrompt, Self.secondPrompt, Self.thirdPrompt])
  }

  /// With no cut, a fork while the answer to the result of a background run runs has the last
  /// completed turn, in the ACP copy and in the Router journal of the fork.
  @Test(.timeLimit(.minutes(1))) func noCutWhileARunResultRunsForksTheLastCompletedTurn()
    async throws
  {
    let hold = ScriptedHold()
    defer { hold.release() }
    let fixture = try await Self.runResultAnswerRuns("run-result", holding: hold)

    let fork = try await Self.fork(fixture)
    let copied = try await Self.copiedMessages(of: fork.sessionId, in: fixture)

    #expect(copied == ForkMessages(prompts: [Self.runPrompt], agentText: Self.runStartedText))
  }

  /// With no cut, a fork while the answer to the result of a background run runs has the same
  /// messages in the ACP copy and in the Router journal of the fork.
  @Test(.timeLimit(.minutes(1))) func noCutWhileARunResultRunsCopiesTheRouterFork()
    async throws
  {
    let hold = ScriptedHold()
    defer { hold.release() }
    let fixture = try await Self.runResultAnswerRuns("run-result-router", holding: hold)

    let fork = try await Self.fork(fixture)
    let copied = try await Self.copiedMessages(of: fork.sessionId, in: fixture)
    let forked = try await Self.routerMessages(of: fork.sessionId, in: fixture)

    #expect(copied == forked)
  }

  // MARK: - The fork

  /// A tool that ran in the source runs in the fork, and the client gets no permission request.
  @Test(.timeLimit(.minutes(1))) func aToolOfTheSourceRunsInTheForkWithNoPermissionRequest()
    async throws
  {
    let fixture = try await Self.makeFixture("tool")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.toolPrompt)
    let fork = try await Self.fork(fixture)

    try await ScriptedPromptFixture.runPrompt(
      AgentClientHarness.makePromptRequest(sessionId: fork.sessionId, text: Self.toolPrompt),
      through: fixture.harness, count: Self.twoTurns)

    let recorder = try #require(fixture.harness.elicitations)
    #expect(await recorder.permissions.isEmpty)
  }

  /// A `session/resume` of a fork replays the copied turns.
  @Test(.timeLimit(.minutes(1))) func aResumeOfTheForkReplaysTheCopiedTurns() async throws {
    let fixture = try await Self.makeFixture("resume")
    try await Self.runTwoTurns(on: fixture)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)
    let fork = try await Self.fork(
      fixture, cutting: (try Self.firstAgentMessageId(of: source), .after))

    let replayed = try await Self.resume(fork.sessionId, in: fixture)

    #expect(Self.userTexts(of: replayed) == [Self.firstPrompt])
  }

  /// A `session/resume` of a fork with a cut before the first user message replays no
  /// message of the source: the fork copied no turn.
  @Test(.timeLimit(.minutes(1))) func aResumeOfAForkBeforeTheFirstTurnReplaysNoTurn()
    async throws
  {
    let fixture = try await Self.makeFixture("resume-empty")
    try await Self.runTwoTurns(on: fixture)
    let source = try await Self.history(of: fixture.sessionId, in: fixture)
    let fork = try await Self.fork(
      fixture, cutting: (try Self.userMessageId(Self.firstPrompt, in: source), .before))

    let replayed = try await Self.resume(fork.sessionId, in: fixture)

    #expect(Self.userTexts(of: replayed).isEmpty)
  }

  /// With no history file, the agent cannot find the cut of a fork whose source left out no
  /// tool call, so it copies no entry of the source: the fork never shows the whole source.
  @Test func aForkThatLeftOutNoToolCallHasNoKnownEnd() {
    #expect(Self.compactedHistory.forkEnd(keepingToolCalls: []) == nil)
  }

  /// A model slot switch of a source moves the fork that the agent holds onto the new slot. The
  /// restore of the source does not move a live fork, so the agent restores the fork by its id.
  @Test(.timeLimit(.minutes(1))) func aModelSlotSwitchOfTheSourceMovesItsFork() async throws {
    let fixture = try await Self.makeFixture("source-slot")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let fork = try await Self.fork(fixture)

    _ = try await fixture.harness.connection.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.modelOptionId, sessionId: fixture.sessionId,
        value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))

    #expect(await fixture.harness.agent.sessions[fork.sessionId]?.selectedSlot == .flash)
  }

  /// A model slot switch of a fork restores the fork from the recording root, and the fork
  /// works on the new slot.
  @Test(.timeLimit(.minutes(1))) func aModelSlotSwitchOfTheForkSelectsTheNewSlot() async throws {
    let fixture = try await Self.makeFixture("slot")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let fork = try await Self.fork(fixture)

    _ = try await fixture.harness.connection.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.modelOptionId, sessionId: fork.sessionId,
        value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))

    #expect(await fixture.harness.agent.sessions[fork.sessionId]?.selectedSlot == .flash)
  }

  /// A fork request with no MCP servers gives the fork no MCP servers of a client, also when
  /// the source has some (ACP: omitted and `[]` mean none).
  @Test(.timeLimit(.minutes(1))) func aForkWithNoMCPServersGetsNoServers() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.script(), label: "\(Self.label)-source-servers",
      mcpServers: [Self.sourceServer])

    let fork = try await Self.forkEntry(of: fixture)

    #expect(fork.clientMCPServers.isEmpty)
  }

  /// A fork request with MCP servers gives the fork the MCP servers of the request.
  @Test(.timeLimit(.minutes(1))) func aForkWithMCPServersGetsTheServersOfTheRequest()
    async throws
  {
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.script(), label: "\(Self.label)-request-servers")

    let fork = try await Self.forkEntry(of: fixture, mcpServers: [Self.sourceServer])

    #expect(fork.clientMCPServers == [Self.sourceServer])
  }

  /// A fork request with no additional directories gives the fork no additional directories,
  /// also when the source has some (ACP: omitted or empty activates no additional roots).
  @Test(.timeLimit(.minutes(1))) func aForkWithNoDirectoriesGetsNoDirectories() async throws {
    let directory = makeResolvedDirectory(label: "\(Self.label)-source-root")
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.script(), label: "\(Self.label)-source-roots",
      additionalDirectories: [AbsolutePath(rawValue: directory.path)])

    let fork = try await Self.forkEntry(of: fixture)

    #expect(fork.additionalRoots.isEmpty)
  }

  /// A fork request with additional directories gives the fork the directories of the request.
  @Test(.timeLimit(.minutes(1))) func aForkWithDirectoriesGetsTheDirectoriesOfTheRequest()
    async throws
  {
    let sourceDirectory = makeResolvedDirectory(label: "\(Self.label)-source-root")
    let requestDirectory = makeResolvedDirectory(label: "\(Self.label)-request-root")
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.script(), label: "\(Self.label)-request-roots",
      additionalDirectories: [AbsolutePath(rawValue: sourceDirectory.path)])

    let fork = try await Self.forkEntry(
      of: fixture, additionalDirectories: [AbsolutePath(rawValue: requestDirectory.path)])

    #expect(fork.additionalRoots.map(\.path) == [requestDirectory.path])
  }

  /// A `session/fork` request that waits for its launcher, and a fork that the same client asks
  /// for through the `sessions` endpoint of the same source at the same time, each get their own
  /// surface: the request its MCP servers, and the endpoint fork the MCP servers of the source.
  @Test(.timeLimit(.minutes(1))) func aSessionForkAndAnEndpointForkOfOneClientGetTheirOwnSurfaces()
    async throws
  {
    let fixture = try await ScriptedPromptFixture.make(
      script: try Self.script(), label: "\(Self.label)-endpoint-fork",
      mcpServers: [Self.sourceServer])
    let client = ConnectionId.direct

    let servers = try await Self.whileForkRequestWaits(in: fixture, client: client) {
      // The endpoint fork runs in a task of its own, as a request of the `sessions` endpoint does.
      let endpointFork = try await Task.detached {
        try await Self.directoryForkEntry(of: fixture, client: client)
      }.value
      let requestedFork = try await Self.directoryForkEntry(of: fixture, client: client)
      return [endpointFork.clientMCPServers, requestedFork.clientMCPServers]
    }

    #expect(servers == [[Self.sourceServer], [Self.requestServer]])
  }

  /// A fork request with a `cwd` that is not the folder of the source is invalid params.
  @Test(.timeLimit(.minutes(1))) func aForkInAnotherFolderIsInvalidParams() async throws {
    let fixture = try await Self.makeFixture("other-folder")
    let other = makeResolvedDirectory(label: "\(Self.label)-other-folder")

    let refusal = await #expect(throws: RequestError.self) {
      _ = try await Self.forkEntry(of: fixture, cwd: other)
    }

    #expect(refusal?.code == .invalidParams)
  }

  // MARK: - The tool

  /// `fork session` with no id from a session of the agent gives a fork with the history up to
  /// the call: the prompt of the call, and no tool call.
  @Test(.timeLimit(.minutes(1))) func forkSessionFromTheToolForksTheHistoryUpToTheCall()
    async throws
  {
    let fixture = try await Self.makeFixture("tool-fork")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let summary = try await Self.forkFromTheTool(on: fixture)
    let live = try #require(fixture.harness.agent.sessionDirectory.session(id: summary.id))

    let transcript = Array(await live.transcript)

    #expect(
      transcript.contains { entry in
        guard case .prompt(let prompt) = entry else { return false }
        return prompt.segments.contains { segment in
          guard case .text(let text) = segment else { return false }
          return text.content.contains(Self.forkPrompt)
        }
      }
        && !transcript.contains { entry in
          guard case .toolCalls = entry else { return false }
          return true
        })
  }

  /// A `session/resume` of a fork that `fork session` made replays the user messages up to the
  /// call.
  @Test(.timeLimit(.minutes(1))) func aResumeOfAToolForkReplaysTheTurnsUpToTheCall()
    async throws
  {
    let fixture = try await Self.makeFixture("tool-resume")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let summary = try await Self.forkFromTheTool(on: fixture)

    let replayed = try await Self.resume(SessionId(rawValue: summary.id.description), in: fixture)

    #expect(Self.userTexts(of: replayed) == [Self.firstPrompt, Self.forkPrompt])
  }

  /// The first prompt of a fork that `fork session` made runs on the surface that the agent gave
  /// the fork, and the agent holds the fork from its start. Thus a `session/resume` of the fork
  /// while the prompt runs takes the live fork, and the prompt ends with its answer.
  @Test(.timeLimit(.minutes(1))) func theFirstPromptOfAToolForkEndsAfterAResumeOfTheFork()
    async throws
  {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture("tool-first-prompt", holding: hold)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let summary = try await Self.forkFromTheTool(on: fixture, prompt: Self.forkWithPromptPrompt)
    let forkId = SessionId(rawValue: summary.id.description)

    _ = try await Self.resume(forkId, in: fixture)
    hold.release()
    _ = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "the answer to the first prompt of the fork"
    ) { Self.agentChunkTexts(of: forkId, in: $0).contains(Self.forkAnswerText) }

    #expect(
      try await Self.history(of: forkId, in: fixture).entries.contains { entry in
        guard case .agentMessage(let message) = entry.kind else { return false }
        return Self.text(of: message.content) == Self.forkAnswerText
      })
  }

  /// A cold `session/resume` of the source of a fork that `fork session` made does not make a
  /// second live fork: the fork that the agent holds stays the live fork of the session
  /// directory.
  @Test(.timeLimit(.minutes(1))) func aColdResumeOfTheSourceKeepsTheHeldToolFork() async throws {
    let fixture = try await Self.makeFixture("tool-cold-source")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    let summary = try await Self.forkFromTheTool(on: fixture)
    _ = try await fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: fixture.sessionId))

    _ = try await Self.resume(fixture.sessionId, in: fixture)
    let held = try #require(
      await fixture.harness.agent.sessions[SessionId(rawValue: summary.id.description)]?.session)
    let live = try #require(fixture.harness.agent.sessionDirectory.session(id: summary.id))

    #expect((held as AnyObject) === (live as AnyObject))
  }

  // MARK: - The additional directories of the record of a fork

  /// The `index.md` record of a fork that `fork session` made holds the additional directories
  /// of its source.
  @Test(.timeLimit(.minutes(1))) func theRecordOfAToolForkHasTheDirectoriesOfTheSource()
    async throws
  {
    let directory = makeResolvedDirectory(label: "\(Self.label)-tool-record-root")
    let fixture = try await Self.makeFixtureWithDirectory(directory, name: "tool-record")
    let fork = try await Self.toolForkAfterTurnOne(on: fixture)

    let recorded = try await Self.recordedDirectories(
      of: fork, in: Self.recordingFolder(of: fixture))

    #expect(recorded == [directory.path])
  }

  /// The `index.md` record of a fork that a client asks for through the `sessions` endpoint
  /// holds the additional directories of its source.
  @Test(.timeLimit(.minutes(1))) func theRecordOfAnEndpointForkHasTheDirectoriesOfTheSource()
    async throws
  {
    let directory = makeResolvedDirectory(label: "\(Self.label)-endpoint-record-root")
    let fixture = try await Self.makeFixtureWithDirectory(directory, name: "endpoint-record")
    let fork = try await Self.directoryForkEntry(of: fixture, client: .direct)

    let recorded = try await Self.recordedDirectories(
      of: fork.session.id, in: Self.recordingFolder(of: fixture))

    #expect(recorded == [directory.path])
  }

  /// The `index.md` record of a `session/fork` fork holds the additional directories of the
  /// request, not those of the source.
  @Test(.timeLimit(.minutes(1))) func theRecordOfASessionForkHasTheDirectoriesOfTheRequest()
    async throws
  {
    let sourceDirectory = makeResolvedDirectory(label: "\(Self.label)-record-source-root")
    let requestDirectory = makeResolvedDirectory(label: "\(Self.label)-record-request-root")
    let fixture = try await Self.makeFixtureWithDirectory(sourceDirectory, name: "request-record")
    let fork = try await Self.forkEntry(
      of: fixture, additionalDirectories: [AbsolutePath(rawValue: requestDirectory.path)])

    let recorded = try await Self.recordedDirectories(
      of: fork.session.id, in: Self.recordingFolder(of: fixture))

    #expect(recorded == [requestDirectory.path])
  }

  /// The `index.md` record of a `session/fork` fork whose request omits the additional
  /// directories holds none, also when the source has some (ACP: omitted gives none).
  @Test(.timeLimit(.minutes(1))) func theRecordOfASessionForkWithNoDirectoriesHasNone()
    async throws
  {
    let directory = makeResolvedDirectory(label: "\(Self.label)-omitted-record-root")
    let fixture = try await Self.makeFixtureWithDirectory(directory, name: "omitted-record")
    let fork = try await Self.forkEntry(of: fixture)

    let recorded = try await Self.recordedDirectories(
      of: fork.session.id, in: Self.recordingFolder(of: fixture))

    #expect(recorded.isEmpty)
  }

  /// The `index.md` record of a fork that `fork session` made keeps the additional directories
  /// of its source after a restart: the first agent closes, and a second agent over the same
  /// folder resumes the source cold.
  @Test(.timeLimit(.minutes(1))) func theRecordOfAToolForkKeepsTheDirectoriesAfterARestart()
    async throws
  {
    let directory = makeResolvedDirectory(label: "\(Self.label)-restart-record-root")
    let fixture = try await Self.makeFixtureWithDirectory(directory, name: "restart-record")
    let fork = try await Self.toolForkAfterTurnOne(on: fixture)
    let folder = try await Self.recordingFolder(of: fixture)

    let recorded = try await fixture.closeAndResume { cwd in
      try await ScriptedPromptFixture.make(
        script: try Self.script(), label: "\(Self.label)-restart-record-second",
        workingDirectory: cwd, additionalDirectories: [AbsolutePath(rawValue: directory.path)])
    } read: { _, _ in
      try Self.recordedDirectories(of: fork, in: folder)
    }

    #expect(recorded == [directory.path])
  }

  // MARK: - The late record of the calling tool call

  /// A fork that `fork session` made while the record of its calling tool call was late copies
  /// the turns before the call. The wire keeps the frame of the text before the call until the
  /// launcher built the fork node, so the projector of the source records the call only then.
  @Test(.timeLimit(.minutes(1))) func aToolForkWhoseCallRecordIsLateCopiesTheTurnsBeforeTheCall()
    async throws
  {
    let source = try await Self.makeHeldRecordSource("tool-late-record")
    try await Self.runHeldForkPrompt(on: source) {
      try await Self.waitForForkNode(in: source.recordingFolder, present: true)
    }
    let fork = try #require(try await Self.forks(in: source.fixture).first)

    let history = try await Self.history(
      of: SessionId(rawValue: fork.id.description), in: source.fixture)

    #expect(Self.userTexts(of: history) == [Self.firstPrompt, Self.heldForkPrompt])
  }

  /// When the record of the calling tool call does not come in the time limit, the `fork
  /// session` call gives the error of the missing record to the model.
  @Test(.timeLimit(.minutes(1))) func aToolForkWithNoCallRecordFailsWithTheMissingRecordError()
    async throws
  {
    let source = try await Self.runForkWithNoCallRecord("tool-no-record-error")
    let expected = ToolForkHistoryError.callingToolCallNotRecorded(
      source: source.fixture.sessionId, timeLimit: Self.shortRecordTimeLimit
    ).description

    let calls = try Self.toolCallTexts(
      of: try await Self.history(of: source.fixture.sessionId, in: source.fixture))

    #expect(calls.contains { $0.contains(expected) })
  }

  /// When the record of the calling tool call does not come in the time limit, the session
  /// directory registers no fork.
  @Test(.timeLimit(.minutes(1))) func aToolForkWithNoCallRecordRegistersNoFork() async throws {
    let source = try await Self.runForkWithNoCallRecord("tool-no-record-fork")

    let forks = try await Self.forks(in: source.fixture)

    #expect(forks.isEmpty)
  }

  // MARK: - A fork that the agent cannot open

  /// A `session/fork` request whose project file save fails gets the internal error of the
  /// failed save.
  @Test(.timeLimit(.minutes(1))) func aForkWhoseProjectSaveFailsGetsTheSaveError() async throws {
    let fixture = try await Self.makeFixture("project-save-error")
    try Self.blockProjectStore(of: fixture)

    try await Self.expectProjectSaveError(on: fixture)
  }

  /// A `session/fork` request whose project file save fails leaves no fork in the session table.
  @Test(.timeLimit(.minutes(1))) func aForkWhoseProjectSaveFailsLeavesNoForkInTheTable()
    async throws
  {
    let fixture = try await Self.makeFixture("project-save-table")
    try Self.blockProjectStore(of: fixture)

    try await Self.expectProjectSaveError(on: fixture)

    #expect(await Self.tableSessionIds(of: fixture) == [fixture.sessionId])
  }

  /// A `session/fork` request whose project file save fails leaves no live fork in the session
  /// directory.
  @Test(.timeLimit(.minutes(1))) func aForkWhoseProjectSaveFailsLeavesNoLiveForkInTheDirectory()
    async throws
  {
    let fixture = try await Self.makeFixture("project-save-directory")
    try Self.blockProjectStore(of: fixture)

    try await Self.expectProjectSaveError(on: fixture)

    #expect(try await Self.forks(in: fixture, includesRecorded: false).isEmpty)
  }

  /// A `session/fork` request whose fork the launcher did not mount for the request gets the
  /// internal error of a fork that the agent cannot open, with the id of the fork.
  @Test(.timeLimit(.minutes(1))) func anUnmountedForkGetsTheUnopenedForkError() async throws {
    let fixture = try await Self.makeFixture("unmounted-error")
    await Self.useUnopenedForkLauncher(.agentWithNoRequest, in: fixture)

    try await Self.expectUnopenedForkError(on: fixture)
  }

  /// A `session/fork` request whose fork the launcher did not mount for the request leaves no
  /// fork in the session table.
  @Test(.timeLimit(.minutes(1))) func anUnmountedForkLeavesNoForkInTheTable() async throws {
    let fixture = try await Self.makeFixture("unmounted-table")
    await Self.useUnopenedForkLauncher(.agentWithNoRequest, in: fixture)

    try await Self.expectUnopenedForkError(on: fixture)

    #expect(await Self.tableSessionIds(of: fixture) == [fixture.sessionId])
  }

  /// A `session/fork` request whose fork the launcher did not mount for the request leaves no
  /// live fork in the session directory.
  @Test(.timeLimit(.minutes(1))) func anUnmountedForkLeavesNoLiveForkInTheDirectory()
    async throws
  {
    let fixture = try await Self.makeFixture("unmounted-directory")
    await Self.useUnopenedForkLauncher(.agentWithNoRequest, in: fixture)

    try await Self.expectUnopenedForkError(on: fixture)

    #expect(try await Self.forks(in: fixture, includesRecorded: false).isEmpty)
  }

  /// A `session/fork` request whose fork a launcher built with no surface of the agent leaves no
  /// live fork in the session directory.
  @Test(.timeLimit(.minutes(1))) func aForkWithNoAgentSurfaceLeavesNoLiveForkInTheDirectory()
    async throws
  {
    let fixture = try await Self.makeFixture("no-surface-directory")
    await Self.useUnopenedForkLauncher(.sourceTools, in: fixture)

    try await Self.expectUnopenedForkError(on: fixture)

    #expect(try await Self.forks(in: fixture, includesRecorded: false).isEmpty)
  }

  // MARK: - Fixtures of a fork that the agent cannot open

  /// Puts a file where the project store of the agent of `fixture` keeps its folder, so each
  /// later save of a project file fails.
  ///
  /// - Parameter fixture: The fixture.
  /// - Throws: The error of the remove of the folder or of the write of the file.
  private static func blockProjectStore(of fixture: ScriptedPromptFixture) throws {
    let folder = fixture.harness.agent.home.projectsDirectory
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
    try Data().write(to: folder)
  }

  /// Gives the session directory of the agent of `fixture` a launcher that builds a fork that
  /// the `session/fork` request cannot open (``UnopenedForkLauncher``).
  ///
  /// - Parameters:
  ///   - build: How the launcher builds the fork.
  ///   - fixture: The fixture.
  private static func useUnopenedForkLauncher(
    _ build: UnopenedForkLauncher.Build, in fixture: ScriptedPromptFixture
  ) async {
    await fixture.harness.agent.sessionDirectory.use(
      launcher: UnopenedForkLauncher(build: build, agent: fixture.harness.agent))
  }

  /// The ids of the sessions that the session table of the agent of `fixture` holds.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The ids.
  private static func tableSessionIds(of fixture: ScriptedPromptFixture) async -> Set<SessionId> {
    Set(await fixture.harness.agent.sessions.keys)
  }

  /// Sends `session/fork` for the session of `fixture`, and checks that the request gets the
  /// internal error of the failed project file save (after ``blockProjectStore(of:)``).
  ///
  /// The test makes the same save in the project store of the agent before the request, and the
  /// agent gives the description of that save error in `data`. The description of a save error
  /// holds the address of its underlying error, which is different for each error. Thus the check
  /// compares the two descriptions with no address (``withoutAddresses(_:)``).
  ///
  /// - Parameter fixture: The fixture, with a blocked project store.
  /// - Throws: A failed requirement when the save of the test does not fail, the request does
  ///   not fail, or the table holds no source.
  private static func expectProjectSaveError(on fixture: ScriptedPromptFixture) async throws {
    let source = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    let saveError = try #require(
      #expect(throws: CocoaError.self) {
        try ProjectStore(directory: fixture.harness.agent.home.projectsDirectory).register(
          workingDirectory: source.workingDirectory)
      })
    let expected = RequestError.internalError(detail: String(describing: saveError as NSError))

    let error = try #require(
      await #expect(throws: RequestError.self) {
        _ = try await Self.fork(fixture)
      })

    #expect(
      withoutAddresses(String(describing: error))
        == withoutAddresses(String(describing: expected)))
  }

  /// A description with each hexadecimal pointer address (`0x` and its digits) replaced by `0x`.
  ///
  /// - Parameter description: The description.
  /// - Returns: The description with no address.
  private static func withoutAddresses(_ description: String) -> String {
    description.replacing(/0x[0-9a-fA-F]+/, with: "0x")
  }

  /// Sends `session/fork` for the session of `fixture`, and checks that the request gets the
  /// internal error of a fork that the agent cannot open
  /// (``RequestError/unopenedFork(_:)``), with the id of the fork that the directory recorded.
  ///
  /// - Parameter fixture: The fixture, with an ``UnopenedForkLauncher``.
  /// - Throws: A failed requirement when the directory recorded no fork, or the error of the
  ///   query.
  private static func expectUnopenedForkError(on fixture: ScriptedPromptFixture) async throws {
    let error = await #expect(throws: RequestError.self) {
      _ = try await Self.fork(fixture)
    }
    let fork = try #require(try await forks(in: fixture).first)

    #expect(error == RequestError.unopenedFork(SessionId(rawValue: fork.id.description)))
  }
}

/// A launcher whose fork a `session/fork` request of the agent cannot open: the agent did not
/// mount the fork for the request.
private final class UnopenedForkLauncher: SessionLauncher, Sendable {
  /// How the launcher builds a fork.
  enum Build: Sendable {
    /// The agent builds and mounts the fork as a fork that no request of the agent asked for.
    /// The session table holds the fork, and the request gets no activation.
    case agentWithNoRequest

    /// The request builds the fork with the tools of the source. The session table does not
    /// hold the fork.
    case sourceTools
  }

  /// How the launcher builds a fork.
  private let build: Build

  /// The agent of the session directory. Weak, to break the cycle agent → directory →
  /// launcher → agent. A `weak let` is set one time, in the initializer, and the agent is an
  /// actor. Thus the class is `Sendable` with no unchecked conformance.
  private weak let agent: RoutedACPAgent?

  /// Makes the launcher.
  ///
  /// - Parameters:
  ///   - build: How the launcher builds a fork.
  ///   - agent: The agent of the session directory.
  init(build: Build, agent: RoutedACPAgent) {
    self.build = build
    self.agent = agent
  }

  /// Not available.
  ///
  /// - Parameter request: The start request.
  /// - Returns: Never.
  /// - Throws: `SessionDirectoryError.noLauncher`, always.
  func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
    throw SessionDirectoryError.noLauncher
  }

  /// Not available.
  ///
  /// - Parameter id: The id of the recorded session.
  /// - Returns: Never.
  /// - Throws: `SessionDirectoryError.noLauncher`, always.
  func restoreSession(id: ULID) async throws -> any RoutedSession {
    throw SessionDirectoryError.noLauncher
  }

  /// Builds the fork of `request` as ``build`` tells.
  ///
  /// - Parameter request: The fork request of the session directory.
  /// - Returns: The fork.
  /// - Throws: `SessionDirectoryError.noLauncher` when the agent is gone, or the error of the
  ///   build.
  func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
    switch build {
    case .agentWithNoRequest:
      guard let agent else {
        throw SessionDirectoryError.noLauncher
      }
      return try await agent.launchFork(request, for: nil)
    case .sourceTools:
      return try await request.makeFork()
    }
  }
}

/// A background tool whose run ends when the test opens its gate. Its result is mail to the
/// session, and that mail starts an answer of its own, which is no turn.
private struct GatedRunTool: FoundationModels.Tool, BackgroundTool {
  /// The wire arguments; the tool reads nothing from them.
  @Generable
  struct Arguments {}

  /// The name of the tool.
  static let toolName = "gated_run"

  /// The result of the run.
  static let resultText = "GATED-RUN-RESULT"

  let name = Self.toolName

  let description = "a scripted run that ends when the test opens its gate"

  var mount: ToolMount? { ToolMount(mode: .background) }

  var inlineSettleGrace: TimeInterval { 0 }

  /// The gate of the run. The test opens it.
  let gate = WatchedValue(false)

  func call(arguments: Arguments) async throws -> String {
    _ = try await gate.wait(for: "the gate of the gated run") { $0 }
    return Self.resultText
  }
}

/// An inline tool that the answer to the result of the gated run calls before it holds, so the
/// test knows that the answer runs.
private struct AnswerSignalTool: FoundationModels.Tool {
  /// The wire arguments; the tool reads nothing from them.
  @Generable
  struct Arguments {}

  /// The name of the tool.
  static let toolName = "answer_signal"

  let name = Self.toolName

  let description = "a scripted tool that tells the test that an answer runs"

  /// Whether an answer called the tool.
  let reached = WatchedValue(false)

  func call(arguments: Arguments) async throws -> String {
    reached.update { $0 = true }
    return Self.toolName
  }
}
