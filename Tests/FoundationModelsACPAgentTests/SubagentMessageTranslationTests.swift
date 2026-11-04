import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The events of a session that carry a message between a caller and a child become the
/// `session_message` views of ``SubagentMessageProjector``. Each test drives the events of one
/// synthetic prompt. The other session of the message is a recording inbox on the projector of
/// the surface.
@Suite struct SubagentMessageTranslationTests {
  /// The text of the message in each test.
  private static let text = "Please check the second file as well."

  /// The reply of the run in the test of the final message.
  private static let reply = "The run replies."

  /// The tool of the `agents` calls.
  private static let agentsTool = "agents"

  /// The completion token of the run of the call route.
  private static let runToken = "01MSGRUNTOKEN00000000000001"

  /// The SDK tool-call id of the call that sends the message.
  private static let sdkCallId = "call-send-1"

  /// The session of the prompt in every test. It is the session of the synthetic prompt.
  private let own = SessionId(rawValue: syntheticSessionIdValue)

  /// The other session of the message.
  private let other = SessionId(rawValue: "other-session")

  /// The inbox of the other session.
  private let otherInbox = RecordingSessionInbox()

  /// The prompt and the recorder of its updates. The prompt knows the `agents` tool.
  private let prompt: (execution: SyntheticExecution, recorder: SinkRecorder)

  /// Makes the fixture: a synthetic prompt that has the other session attached to its projector
  /// of messages.
  init() {
    prompt = makeSinkedExecution()
    prompt.execution.runCallJoins.holds.bind(toolName: Self.agentsTool) { _ in }
    let inbox = otherInbox
    prompt.execution.runCallJoins.messages.attach(other) { inbox.accept($0) }
  }

  /// The updates of the prompt after it handled `events`.
  private func updates(of events: [SessionEvent]) async -> [SessionUpdate] {
    await prompt.execution.drive(events: makeEventStream(events))
    return await prompt.recorder.updates
  }

  /// The events of one `agents` call that mailed a message: the open and the close record, the
  /// report of the call with the sent-message record, and the SDK call with its arguments.
  private func sendEvents(
    direction: SentMessageRecord.Direction, mail: MailID, reportFirst: Bool = true
  ) -> [SessionEvent] {
    let record = SentMessageRecord(
      mailId: mail.value.description, direction: direction, receiverRunId: other.rawValue,
      receiverSessionId: other.rawValue)
    let json = String(data: (try? JSONEncoder().encode(record)) ?? Data(), encoding: .utf8) ?? ""
    let invocation = ToolInvocationRecord(
      tool: Self.agentsTool, op: "send agent", correlationID: Self.runToken,
      sessionID: ULID.generate(), openedAt: Date(timeIntervalSince1970: 0))
    let report = ToolCallReport(
      tool: Self.agentsTool, op: "send agent", correlationID: Self.runToken,
      sessionID: ULID.generate(),
      attachments: [ToolCallAttachment(schemaName: SentMessageRecord.schemaName, contentJSON: json)])
    let call = SessionEvent.toolCall(
      id: Self.sdkCallId, name: Self.agentsTool,
      argumentsJSON: #"{"op":"send agent","id":"\#(other.rawValue)","message":"\#(Self.text)"}"#)
    return [
      .toolInvocation(invocation, toolCallID: Self.sdkCallId),
      .toolInvocation(invocation.closed(at: Date(timeIntervalSince1970: 1)), toolCallID: Self.sdkCallId),
    ]
      + (reportFirst ? [.toolCallReport(report), call] : [call, .toolCallReport(report)])
      + [.toolStatus(id: Self.sdkCallId, status: .completed, summary: nil, output: nil)]
  }

  /// The message event of a run of the call route.
  private func runEvent(
    tool: String, kind: OperationEventKind, outcome: OperationOutcome? = nil
  ) -> OperationEvent {
    OperationEvent(
      tool: tool, op: "start agent", correlationID: Self.runToken, kind: kind, detail: Self.text,
      outcome: outcome)
  }

  @Test("a send agent call sends the outgoing view with the text of its arguments")
  func aSendAgentCallSendsTheOutgoingView() async throws {
    let updates = await updates(of: sendEvents(direction: .toChild, mail: MailID()))

    let outgoing = try #require(updates.compactMap(\.sessionMessagePayload).first)
    #expect(outgoing.firstText == Self.text)
    #expect(outgoing.senderSessionId == .value(own))
    #expect(outgoing.recipientSessionId == .value(other))
  }

  @Test("a send agent call sends the outgoing view when its SDK call comes before its report")
  func aSendAgentCallWithTheCallFirstSendsTheOutgoingView() async throws {
    let updates = await updates(
      of: sendEvents(direction: .toChild, mail: MailID(), reportFirst: false))

    let outgoing = try #require(updates.compactMap(\.sessionMessagePayload).first)
    #expect(outgoing.firstText == Self.text)
  }

  @Test("a send agent call sends no incoming view before the receiver took the mail")
  func aSendAgentCallSendsNoIncomingViewEarly() async {
    _ = await updates(of: sendEvents(direction: .toChild, mail: MailID()))

    #expect(otherInbox.updates.isEmpty)
  }

  @Test("the sent-message record is not tool call content")
  func theSentRecordIsNotToolCallContent() async throws {
    let mail = MailID()

    let updates = await updates(of: sendEvents(direction: .toChild, mail: mail))

    let content = toolCallUpdates(in: updates).flatMap { texts(in: $0.content) }
    #expect(!content.contains { $0.contains(mail.value.description) })
  }

  @Test("a mail that this session took sends the incoming view and links the outgoing view")
  func aReceiptSendsTheIncomingView() async throws {
    let mail = MailID()
    let record = SentMessageRecord(
      mailId: mail.value.description, direction: .toCaller, receiverRunId: nil,
      receiverSessionId: own.rawValue)
    otherInbox.accept(
      prompt.execution.runCallJoins.messages.sent(record, from: other, text: Self.text))

    let updates = await updates(of: [.mailDelivered(mail)])

    let incoming = try #require(updates.compactMap(\.sessionMessagePayload).first)
    #expect(incoming.firstText == Self.text)
    #expect(incoming.senderSessionId == .value(other))
    #expect(incoming.senderMessageId == .value(try #require(otherInbox.messages.first).messageId))
    #expect(otherInbox.messages.last?.recipientMessageId == .value(incoming.messageId))
  }

  @Test("a message of a run over the call route sends the incoming view to this session")
  func aRunMessageSendsTheIncomingView() async throws {
    prompt.execution.runCallJoins.messages.bind(token: Self.runToken, child: other, caller: own)

    let updates = await updates(of: [.runMessage(runEvent(tool: Self.agentsTool, kind: .message))])

    let incoming = try #require(updates.compactMap(\.sessionMessagePayload).first)
    #expect(incoming.firstText == Self.text)
    #expect(incoming.senderSessionId == .value(other))
    #expect(otherInbox.messages.first?.firstText == Self.text)
  }

  @Test("the final message of a run over the call route sends the incoming view")
  func theFinalMessageSendsTheIncomingView() async throws {
    let messages = prompt.execution.runCallJoins.messages
    messages.bind(token: Self.runToken, child: other, caller: own)
    messages.finalReply(ofRun: Self.runToken, text: Self.reply)
    let settled = runEvent(tool: Self.agentsTool, kind: .completed, outcome: .succeeded)

    let updates = await updates(of: [.runSettled(settled)])

    let incoming = try #require(updates.compactMap(\.sessionMessagePayload).first)
    #expect(incoming.firstText == Self.text)
    #expect(otherInbox.messages.first?.firstText == Self.reply)
  }

  @Test("the run of another tool sends no message view")
  func theRunOfAnotherToolSendsNoMessageView() async {
    prompt.execution.runCallJoins.messages.bind(token: Self.runToken, child: other, caller: own)
    let settled = runEvent(tool: "shell", kind: .completed, outcome: .succeeded)

    let updates = await updates(of: [.runSettled(settled)])

    #expect(updates.compactMap(\.sessionMessagePayload).isEmpty && otherInbox.updates.isEmpty)
  }
}
