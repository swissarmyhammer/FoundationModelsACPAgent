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

  // MARK: - Fixtures

  /// The script of the suite: one answer for each prompt.
  ///
  /// - Parameter hold: The hold of the answer of turn 3.
  /// - Returns: The script.
  /// - Throws: The encode error of the tool call.
  private static func script(holding hold: ScriptedHold = ScriptedHold()) throws
    -> [ScriptedPassStep]
  {
    [
      .onPrompt(containing: firstPrompt, play: [.textDelta("First"), .endPass]),
      .onPrompt(containing: secondPrompt, play: [.textDelta("Second"), .endPass]),
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
  /// - Parameter fixture: The fixture.
  /// - Returns: The summaries of the forks.
  /// - Throws: The error of the query.
  private static func forks(in fixture: ScriptedPromptFixture) async throws -> [SessionSummary] {
    try await fixture.harness.agent.sessionDirectory.sessions(
      matching: SessionQuery(kind: .fork, includesRecorded: true))
  }

  /// Runs the prompt whose answer calls `fork session`, and gives the fork that the call made.
  ///
  /// - Parameter fixture: The fixture, after turn 1.
  /// - Returns: The summary of the fork.
  /// - Throws: Whatever the prompt or the query throws.
  private static func forkFromTheTool(on fixture: ScriptedPromptFixture) async throws
    -> SessionSummary
  {
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: forkPrompt, count: twoTurns)
    return try #require(try await forks(in: fixture).first)
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

  /// A history of three turns with a completed compaction after turn 2.
  private static var compactedHistory: SessionMergeEngine {
    let messages: [SessionUpdate] = [
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "u1"), content: .value([.text(TextContent(text: "1"))]))),
      .agentMessageChunk(
        ContentChunk(content: .text(TextContent(text: "a")), messageId: MessageId(rawValue: "a1"))),
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "u2"), content: .value([.text(TextContent(text: "2"))]))),
      .agentMessageChunk(
        ContentChunk(content: .text(TextContent(text: "b")), messageId: MessageId(rawValue: "a2"))),
      .compactionUpdate(
        CompactionUpdate(compactionId: CompactionId(rawValue: "c1"), status: .completed)),
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "u3"), content: .value([.text(TextContent(text: "3"))]))),
    ]
    return SessionMergeEngine(replaying: messages)
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
}
