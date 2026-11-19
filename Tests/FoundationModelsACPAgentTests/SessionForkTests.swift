import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The `session/fork` method (D205): the `fork` capability with the cut flag, the cut in
/// `_meta.sah.forkCut`, and the map from an ACP message id to the index of the turn that holds the
/// message in the retained history of the source.
@Suite(.closesHarnesses) struct SessionForkTests {
  // MARK: - Constants

  /// The id of the user message of turn 1 in the sample history.
  private static let firstUserMessageId = MessageId(rawValue: "user-message-1")

  /// The id of the agent message of turn 1 in the sample history.
  private static let firstAgentMessageId = MessageId(rawValue: "agent-message-1")

  /// The id of the user message of turn 2 in the sample history.
  private static let secondUserMessageId = MessageId(rawValue: "user-message-2")

  /// The id of the agent message of turn 2 in the sample history.
  private static let secondAgentMessageId = MessageId(rawValue: "agent-message-2")

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

  /// The id of a message from another session in a sample history.
  private static let sessionMessageId = MessageId(rawValue: "session-message-1")

  /// Another session, which sends a message to the sample session or gets one from it.
  private static let otherSessionId = SessionId(rawValue: "SessionForkTests-other")

  /// The session that the map tests name in their refusals.
  private static let sampleSessionId = SessionId(rawValue: "SessionForkTests-sample")

  // MARK: - Fixtures

  /// The sample history: two turns, each with one user message and one agent message.
  private static var twoTurnHistory: SessionMergeEngine {
    SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: firstUserMessageId, content: .value([.text(TextContent(text: "One"))]))),
      .agentMessageChunk(
        ContentChunk(content: .text(TextContent(text: "First")), messageId: firstAgentMessageId)),
      .userMessage(
        UserMessage(
          messageId: secondUserMessageId, content: .value([.text(TextContent(text: "Two"))]))),
      .agentMessageChunk(
        ContentChunk(content: .text(TextContent(text: "Second")), messageId: secondAgentMessageId)),
    ])
  }

  /// A history with a user message, a message between the sample session and another session,
  /// and a second user message.
  ///
  /// - Parameter recipient: The session that gets the message between the sessions.
  /// - Returns: The history.
  private static func historyWithSessionMessage(to recipient: SessionId) -> SessionMergeEngine {
    let sender = recipient == sampleSessionId ? otherSessionId : sampleSessionId
    return SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: firstUserMessageId, content: .value([.text(TextContent(text: "One"))]))),
      .agentMessageChunk(
        ContentChunk(content: .text(TextContent(text: "First")), messageId: firstAgentMessageId)),
      .sessionMessage(
        FoundationModelsACP.SessionMessage(
          messageId: sessionMessageId, content: .value([.text(TextContent(text: "Note"))]),
          recipientSessionId: .value(recipient), senderSessionId: .value(sender))),
      .userMessage(
        UserMessage(
          messageId: secondUserMessageId, content: .value([.text(TextContent(text: "Two"))]))),
    ])
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
      of: try meta(cutting: messageId, on: side), in: history, sessionId: sampleSessionId)
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
        of: nil, in: Self.twoTurnHistory, sessionId: Self.sampleSessionId) == .lastCompletedTurn)
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

  /// A cut on a message of the source passes the map. The Router fork is not on this build, so
  /// the request then gets the internal error.
  @Test func aKnownCutPassesTheMapAndGetsTheNotServedError() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.textDelta("Hello."), .endPass], label: "SessionForkTests-known-cut")
    let response = try await ScriptedPromptFixture.runPrompt(on: fixture, text: "Say hello")
      .response
    let meta = try Self.meta(cutting: response.messageId, on: .before)

    let refusal = await Self.forkRefusal(of: fixture, meta: meta)
    await fixture.close()

    #expect(refusal?.code == .internalError)
  }
}
