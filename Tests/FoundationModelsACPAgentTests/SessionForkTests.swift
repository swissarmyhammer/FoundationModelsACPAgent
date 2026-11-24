import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The `session/fork` method (D205): the `fork` capability with the cut flag, the cut in
/// `_meta.sah.forkCut`, and the map from an ACP message id to the index of the turn that holds the
/// message in the retained history of the source.
@Suite(.closesHarnesses) struct SessionForkTests {
  // MARK: - Constants

  /// The mail of the user message of turn 1 in the sample history.
  private static let firstMail = MailID()

  /// The mail of the user message of turn 2 in the sample history.
  private static let secondMail = MailID()

  /// The mail of a message from another session in a sample history.
  private static let sessionMail = MailID()

  /// The mail of a user message that waits in the queue while a turn runs.
  private static let queuedMail = MailID()

  /// The mail of the result of a background run: it starts an answer, and it is no turn.
  private static let runMail = MailID()

  /// The id of the user message of turn 1 in the sample history.
  private static let firstUserMessageId = MessageId(rawValue: firstMail.description)

  /// The id of the agent message of turn 1 in the sample history.
  private static let firstAgentMessageId = MessageId(rawValue: "agent-message-1")

  /// The id of the user message of turn 2 in the sample history.
  private static let secondUserMessageId = MessageId(rawValue: secondMail.description)

  /// The id of the agent message of turn 2 in the sample history.
  private static let secondAgentMessageId = MessageId(rawValue: "agent-message-2")

  /// The id of the user message that waits in the queue.
  private static let queuedUserMessageId = MessageId(rawValue: queuedMail.description)

  /// The id of the echo of an action command: an action command sends no mail.
  private static let actionMessageId = MessageId(rawValue: "action-command-1")

  /// A message id that no history holds.
  private static let unknownMessageId = MessageId(rawValue: "no-such-message")

  /// A side that the agent does not know.
  private static let unknownSide = SAH.ForkCut.Side(rawValue: "middle")

  /// The index of turn 1 of the sample history.
  private static let firstTurn = 0

  /// The index of turn 2 of the sample history.
  private static let secondTurn = 1

  /// The index of the turn after a user message, a message from another session and a second
  /// user message: the message from the other session is a turn of its own.
  private static let turnAfterIncomingMessage = 2

  /// The index of the queued user message: the session got it after the message from another
  /// session, so it is the third turn.
  private static let queuedTurn = 2

  /// The text of the queued user message.
  private static let queuedText = "Queued"

  /// The text of the action command.
  private static let actionText = "/help"

  /// The id of the incoming view of the message from another session.
  private static let sessionMessageId = MessageId.incomingView(of: sessionMail.description)

  /// The id of the outgoing view of a message to another session.
  private static let outgoingMessageId = MessageId(rawValue: "out-\(sessionMail.description)")

  /// Another session, which sends a message to the sample session or gets one from it.
  private static let otherSessionId = SessionId(rawValue: "SessionForkTests-other")

  /// The session that the map tests name in their refusals.
  private static let sampleSessionId = SessionId(rawValue: "SessionForkTests-sample")

  // MARK: - Fixtures

  /// A user message with a text.
  ///
  /// - Parameters:
  ///   - id: The id of the message.
  ///   - text: The text.
  /// - Returns: The update.
  private static func userMessage(_ id: MessageId, _ text: String) -> SessionUpdate {
    .userMessage(UserMessage(messageId: id, content: .value([.text(TextContent(text: text))])))
  }

  /// An agent message with a text.
  ///
  /// - Parameters:
  ///   - id: The id of the message.
  ///   - text: The text.
  /// - Returns: The update.
  private static func agentMessage(_ id: MessageId, _ text: String) -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text)), messageId: id))
  }

  /// The record of a delivered mail that starts an answer of its own, in a batch of its own.
  ///
  /// - Parameter mail: The mail.
  /// - Returns: The update of the record.
  private static func delivered(_ mail: MailID) -> SessionUpdate {
    MailDeliveryRecord.delivered(mail: mail, batch: mail, answer: mail).update
  }

  /// The record of the end of the answer that a mail started.
  ///
  /// - Parameter answer: The first mail of the answer.
  /// - Returns: The update of the record.
  private static func answerEnded(_ answer: MailID) -> SessionUpdate {
    MailDeliveryRecord.answerEnded(answer: answer).update
  }

  /// The sample history: two turns, each with one user message, its delivery, one agent message
  /// and the end of the answer.
  private static var twoTurnHistory: SessionMergeEngine {
    SessionMergeEngine(replaying: [
      userMessage(firstUserMessageId, "One"), delivered(firstMail),
      agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      userMessage(secondUserMessageId, "Two"), delivered(secondMail),
      agentMessage(secondAgentMessageId, "Second"), answerEnded(secondMail),
    ])
  }

  /// A history with a user message, a message between the sample session and another session,
  /// and a second user message. The sample session got an incoming message as mail; an outgoing
  /// message went to the other session, so the history holds no delivery of it.
  ///
  /// - Parameter recipient: The session that gets the message between the sessions.
  /// - Returns: The history.
  private static func historyWithSessionMessage(to recipient: SessionId) -> SessionMergeEngine {
    let isIncoming = recipient != otherSessionId
    let message = SessionUpdate.sessionMessage(
      FoundationModelsACP.SessionMessage(
        messageId: isIncoming ? sessionMessageId : outgoingMessageId,
        content: .value([.text(TextContent(text: "Note"))]),
        recipientSessionId: .value(recipient),
        senderSessionId: .value(isIncoming ? otherSessionId : sampleSessionId)))
    let sessionTurn = isIncoming ? [delivered(sessionMail), message, answerEnded(sessionMail)] : [message]
    return SessionMergeEngine(
      replaying: [
        userMessage(firstUserMessageId, "One"), delivered(firstMail),
        agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      ] + sessionTurn + [userMessage(secondUserMessageId, "Two"), delivered(secondMail)])
  }

  /// A history with an action command between two prompts: the action command echoes a user
  /// message and streams an agent message, and it delivers no mail.
  private static var historyWithActionCommand: SessionMergeEngine {
    SessionMergeEngine(replaying: [
      userMessage(firstUserMessageId, "One"), delivered(firstMail),
      agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      userMessage(actionMessageId, actionText), agentMessage(MessageId(rawValue: "help"), "Help"),
      userMessage(secondUserMessageId, "Two"), delivered(secondMail),
      agentMessage(secondAgentMessageId, "Second"), answerEnded(secondMail),
    ])
  }

  /// A history where the client sent a user message while turn 1 ran, and a message from another
  /// session came in before the session took the user message: the echo of the user message comes
  /// first, and the session got the message from the other session first.
  private static var historyWithQueuedPrompt: SessionMergeEngine {
    let incoming = SessionUpdate.sessionMessage(
      FoundationModelsACP.SessionMessage(
        messageId: sessionMessageId, content: .value([.text(TextContent(text: "Note"))]),
        recipientSessionId: .value(sampleSessionId), senderSessionId: .value(otherSessionId)))
    return SessionMergeEngine(replaying: [
      userMessage(firstUserMessageId, "One"), delivered(firstMail),
      userMessage(queuedUserMessageId, queuedText),
      agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      delivered(sessionMail), incoming, answerEnded(sessionMail),
      delivered(queuedMail), agentMessage(secondAgentMessageId, "Second"),
      answerEnded(queuedMail),
    ])
  }

  /// A history where the client sent two user messages while turn 1 ran, and the session got
  /// both in one batch.
  private static var historyWithBatch: SessionMergeEngine {
    SessionMergeEngine(replaying: [
      userMessage(firstUserMessageId, "One"), delivered(firstMail),
      userMessage(secondUserMessageId, "Two"), userMessage(queuedUserMessageId, queuedText),
      agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      MailDeliveryRecord.delivered(mail: secondMail, batch: secondMail, answer: secondMail).update,
      MailDeliveryRecord.delivered(mail: queuedMail, batch: secondMail, answer: secondMail).update,
      agentMessage(secondAgentMessageId, "Second"), answerEnded(secondMail),
    ])
  }

  /// A history where turn 1 completed, and the answer to the result of a background run runs
  /// now. The mail of the result matches no message of the history, so it is no turn.
  private static var historyWithRunningRunAnswer: SessionMergeEngine {
    SessionMergeEngine(replaying: [
      userMessage(firstUserMessageId, "One"), delivered(firstMail),
      agentMessage(firstAgentMessageId, "First"), answerEnded(firstMail),
      delivered(runMail), agentMessage(secondAgentMessageId, "Run result"),
      .stateUpdate(.running(RunningStateUpdate())),
    ])
  }

  /// The text of each user message of a history, in order.
  ///
  /// - Parameter history: The history.
  /// - Returns: The texts.
  private static func userTexts(of history: SessionMergeEngine) -> [String] {
    history.entries.compactMap { entry in
      guard case .userMessage(let message) = entry.kind else { return nil }
      return message.content.compactMap { block in
        guard case .text(let text) = block else { return nil }
        return text.text
      }.joined()
    }
  }

  /// The history that a fork at the point of a cut copies from a source.
  ///
  /// - Parameters:
  ///   - messageId: The message at the cut.
  ///   - side: The side of the message where the cut is.
  ///   - history: The history to cut.
  /// - Returns: The copied history.
  /// - Throws: The refusal of the cut, or a failed requirement when the history has no turn at
  ///   the point.
  private static func copy(
    cutting messageId: MessageId, on side: SAH.ForkCut.Side, in history: SessionMergeEngine
  ) throws -> SessionMergeEngine {
    let source = sampleSource(history)
    let point = try forkPoint(cutting: messageId, on: side, in: history)
    return source.copiedHistory(endingAt: try #require(source.end(of: point)))
  }

  /// The `_meta` of a request with one cut.
  ///
  /// - Parameters:
  ///   - messageId: The message at the cut.
  ///   - side: The side of the message where the cut is.
  /// - Returns: The `_meta` value.
  /// - Throws: Whatever the encode of the cut throws.
  private static func meta(cutting messageId: MessageId, on side: SAH.ForkCut.Side) throws
    -> JSONValue
  {
    try SAH.ForkCut(messageId: messageId, side: side).inject(into: nil)
  }

  /// The fork point of one cut in the sample history.
  ///
  /// - Parameters:
  ///   - messageId: The message at the cut.
  ///   - side: The side of the message where the cut is.
  ///   - history: The history to cut.
  /// - Returns: The fork point.
  /// - Throws: The refusal of the cut.
  private static func forkPoint(
    cutting messageId: MessageId, on side: SAH.ForkCut.Side,
    in history: SessionMergeEngine = twoTurnHistory
  ) throws -> SessionForkPoint {
    try RoutedACPAgent.forkPoint(
      of: try meta(cutting: messageId, on: side), in: sampleSource(history),
      sessionId: sampleSessionId)
  }

  /// A history of the sample session as the source of a fork. The sample session is no fork, so
  /// it alone is the recipient of an incoming message.
  ///
  /// - Parameter history: The history.
  /// - Returns: The source history.
  private static func sampleSource(_ history: SessionMergeEngine) -> ForkSourceHistory {
    ForkSourceHistory.snapshot(of: history, recipients: [sampleSessionId])
  }

  /// Sends `session/fork` with no cut for a session of the agent of `fixture`.
  ///
  /// - Parameters:
  ///   - source: The session to fork.
  ///   - fixture: The fixture.
  /// - Returns: The id of the fork.
  /// - Throws: The error of the request.
  private static func fork(_ source: SessionId, in fixture: ScriptedPromptFixture) async throws
    -> SessionId
  {
    try await fixture.harness.connection.forkSession(
      ForkSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: source)
    ).sessionId
  }

  /// A history as the agent reads it for a fork of a session of the agent of `fixture`: with
  /// the recipients of the fork chain of that session.
  ///
  /// - Parameters:
  ///   - history: The history.
  ///   - sessionId: The source session of the fork.
  ///   - fixture: The fixture.
  /// - Returns: The source history.
  /// - Throws: A failed requirement when the table does not hold the session.
  private static func forkSource(
    _ history: SessionMergeEngine, of sessionId: SessionId, in fixture: ScriptedPromptFixture
  ) async throws -> ForkSourceHistory {
    let agent = fixture.harness.agent
    let entry = try #require(await agent.sessions[sessionId])
    return await agent.forkSourceHistory(
      of: history, forkSource: entry.session.parentId, sessionId: sessionId)
  }

  /// Sends `session/fork` for the session of `fixture` with `meta`, and gives the refusal.
  ///
  /// - Parameters:
  ///   - fixture: The fixture of the source session.
  ///   - meta: The `_meta` of the request.
  /// - Returns: The error of the request, or `nil` when it did not throw a request error.
  private static func forkRefusal(of fixture: ScriptedPromptFixture, meta: JSONValue?) async
    -> RequestError?
  {
    let request = ForkSessionRequest(
      cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId, meta: meta)
    return await #expect(throws: RequestError.self) {
      _ = try await fixture.harness.connection.forkSession(request)
    }
  }

  // MARK: - The capability

  /// With the switch on, `initialize` announces `fork` with `_meta.sah.forkCut = true`.
  @Test func theCapabilityWithTheSwitchOnAnnouncesForkWithTheCutFlag() {
    let capabilities = RoutedACPAgent.advertisedCapabilities(in: .open, servesFork: true)

    #expect(SAH.ForkCut.isAdvertised(by: capabilities.session?.fork))
  }

  /// With the switch off, `initialize` announces no `fork`.
  @Test func theCapabilityWithTheSwitchOffAnnouncesNoFork() {
    let capabilities = RoutedACPAgent.advertisedCapabilities(in: .open, servesFork: false)

    #expect(capabilities.session?.fork == nil)
  }

  // MARK: - The map

  /// The cut after the agent message of turn 1 is the cut after turn 1.
  @Test func theCutAfterTheAgentMessageOfTurnOneIsAfterTurnOne() throws {
    #expect(
      try Self.forkPoint(cutting: Self.firstAgentMessageId, on: .after)
        == .afterTurn(Self.firstTurn))
  }

  /// The cut before the user message of turn 2 is the cut before turn 2.
  @Test func theCutBeforeTheUserMessageOfTurnTwoIsBeforeTurnTwo() throws {
    #expect(
      try Self.forkPoint(cutting: Self.secondUserMessageId, on: .before)
        == .beforeTurn(Self.secondTurn))
  }

  /// The cut after the user message of turn 2 rounds to the end of turn 2.
  @Test func theCutAfterAUserMessageIsAfterItsTurn() throws {
    #expect(
      try Self.forkPoint(cutting: Self.secondUserMessageId, on: .after)
        == .afterTurn(Self.secondTurn))
  }

  /// The cut before the agent message of turn 2 rounds to the start of turn 2.
  @Test func theCutBeforeAnAgentMessageIsBeforeItsTurn() throws {
    #expect(
      try Self.forkPoint(cutting: Self.secondAgentMessageId, on: .before)
        == .beforeTurn(Self.secondTurn))
  }

  /// A message from another session to this session between two user messages is one turn.
  @Test func anIncomingSessionMessageIsATurn() throws {
    #expect(
      try Self.forkPoint(
        cutting: Self.secondUserMessageId, on: .before,
        in: Self.historyWithSessionMessage(to: Self.sampleSessionId))
        == .beforeTurn(Self.turnAfterIncomingMessage))
  }

  /// A message that this session sent to another session is no turn of this session.
  @Test func anOutgoingSessionMessageIsNoTurn() throws {
    #expect(
      try Self.forkPoint(
        cutting: Self.secondUserMessageId, on: .before,
        in: Self.historyWithSessionMessage(to: Self.otherSessionId))
        == .beforeTurn(Self.secondTurn))
  }

  /// An action command between two prompts delivers no mail, so it is no turn: the second
  /// prompt is turn 2.
  @Test func anActionCommandIsNoTurn() throws {
    #expect(
      try Self.forkPoint(
        cutting: Self.secondUserMessageId, on: .before, in: Self.historyWithActionCommand)
        == .beforeTurn(Self.secondTurn))
  }

  /// A user message that waited in the queue takes the index of its delivery, not of its echo.
  @Test func aQueuedPromptTakesTheIndexOfItsDelivery() throws {
    #expect(
      try Self.forkPoint(
        cutting: Self.queuedUserMessageId, on: .before, in: Self.historyWithQueuedPrompt)
        == .beforeTurn(Self.queuedTurn))
  }

  /// A fork before the second message of a batch copies no message of the batch, as the session
  /// directory cuts before the whole batch.
  @Test func aCutOnTheSecondMessageOfABatchCopiesNoMessageOfTheBatch() throws {
    #expect(
      Self.userTexts(
        of: try Self.copy(
          cutting: Self.queuedUserMessageId, on: .before, in: Self.historyWithBatch))
        == ["One"])
  }

  /// With no cut, a fork while the answer to the result of a background run runs keeps the last
  /// completed turn.
  @Test func noCutWhileARunResultRunsKeepsTheLastCompletedTurn() throws {
    let source = Self.sampleSource(Self.historyWithRunningRunAnswer)

    let copied = source.copiedHistory(
      endingAt: try #require(source.end(of: .lastCompletedTurn)))

    #expect(Self.userTexts(of: copied) == ["One"])
  }

  /// A history file of an earlier build holds no delivery record. Each user message of it is a
  /// turn, as that build counted it.
  @Test func aHistoryFileOfAnEarlierBuildCountsEachUserMessage() async throws {
    let directory = makeResolvedDirectory(label: "SessionForkTests-earlier-build")
    let earlier = SessionMergeEngine(replaying: [
      Self.userMessage(Self.firstUserMessageId, "One"),
      Self.agentMessage(Self.firstAgentMessageId, "First"),
      Self.userMessage(Self.secondUserMessageId, "Two"),
    ])
    let contents = ["updates": earlier.transcriptUpdates]
    try JSONEncoder().encode(contents).write(
      to: directory.appendingPathComponent(SessionHistoryFile.fileName))
    let agent = try await AgentClientHarness.makeAgent()

    let resumed = await agent.retainedHistory(
      kept: nil, directory: directory, sessionId: Self.sampleSessionId)

    #expect(
      try Self.forkPoint(cutting: Self.secondUserMessageId, on: .before, in: resumed)
        == .beforeTurn(Self.secondTurn))
  }

  /// The map works on the history that a resume reads from the file of an earlier process.
  @Test func theMapWorksOnTheHistoryThatAResumeReadsFromDisk() async throws {
    let directory = makeResolvedDirectory(label: "SessionForkTests-resume")
    try SessionHistoryFile.write(Self.twoTurnHistory, in: directory)
    let agent = try await AgentClientHarness.makeAgent()

    let resumed = await agent.retainedHistory(
      kept: nil, directory: directory, sessionId: Self.sampleSessionId)

    #expect(
      try Self.forkPoint(cutting: Self.secondUserMessageId, on: .before, in: resumed)
        == .beforeTurn(Self.secondTurn))
  }

  /// A request with no cut forks at the last completed turn.
  @Test func noCutIsTheLastCompletedTurn() throws {
    #expect(
      try RoutedACPAgent.forkPoint(
        of: nil, in: Self.sampleSource(Self.twoTurnHistory), sessionId: Self.sampleSessionId)
        == .lastCompletedTurn)
  }

  /// In a fork of a fork, a message to the first session of the fork chain is a turn: the fork
  /// has a copy of the message, and the message names that first session.
  @Test func aMessageToTheFirstSourceIsATurnOfAForkOfAFork()
    async throws
  {
    let fixture = try await ScriptedPromptFixture.make(
      script: [], label: "SessionForkTests-fork-chain")
    let fork = try await Self.fork(fixture.sessionId, in: fixture)
    let forkOfFork = try await Self.fork(fork, in: fixture)
    let source = try await Self.forkSource(
      Self.historyWithSessionMessage(to: fixture.sessionId), of: forkOfFork, in: fixture)
    await fixture.close()

    #expect(
      try RoutedACPAgent.forkPoint(
        of: try Self.meta(cutting: Self.secondUserMessageId, on: .before), in: source,
        sessionId: forkOfFork) == .beforeTurn(Self.turnAfterIncomingMessage))
  }

  // MARK: - The handler

  /// A cut on a message id that the history of the source does not hold is invalid params.
  @Test func anUnknownMessageIdIsInvalidParams() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [], label: "SessionForkTests-unknown-message")
    let meta = try Self.meta(cutting: Self.unknownMessageId, on: .after)

    let refusal = await Self.forkRefusal(of: fixture, meta: meta)
    await fixture.close()

    #expect(refusal?.code == .invalidParams)
  }

  /// A cut with a side that the agent does not know is invalid params.
  @Test func anUnknownSideIsInvalidParams() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.textDelta("Hello."), .endPass], label: "SessionForkTests-unknown-side")
    let response = try await ScriptedPromptFixture.runPrompt(on: fixture, text: "Say hello")
      .response
    let meta = try Self.meta(cutting: response.messageId, on: Self.unknownSide)

    let refusal = await Self.forkRefusal(of: fixture, meta: meta)
    await fixture.close()

    #expect(refusal?.code == .invalidParams)
  }

  /// A `_meta.sah.forkCut` member that is not a cut is invalid params, not a fork at the last
  /// completed turn.
  @Test func aCutThatDoesNotDecodeIsInvalidParams() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [], label: "SessionForkTests-malformed-cut")
    let meta: JSONValue = .object([
      SAH.metaKey: .object([SAH.ForkCut.metaKey: .string("not a cut")])
    ])

    let refusal = await Self.forkRefusal(of: fixture, meta: meta)
    await fixture.close()

    #expect(refusal?.code == .invalidParams)
  }
}
