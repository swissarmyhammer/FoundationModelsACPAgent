import Foundation
import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The `session_message` views of the messages between a caller and a child
/// (``SubagentMessageProjector``). The projector sends each view to the
/// inbox of the session whose transcript holds it. Each test gives the
/// projector two inboxes that record what they get, and reads the views from
/// them.
@Suite struct SubagentMessageProjectorTests {
  /// The text of the message in each test.
  private static let text = "Please check the second file as well."

  /// A projector with two attached sessions.
  private struct Pair {
    /// The projector.
    let projector = SubagentMessageProjector()

    /// The id of the caller session.
    let caller = SessionId(rawValue: "caller-session")

    /// The id of the child session.
    let child = SessionId(rawValue: "child-session")

    /// The inbox of the caller session.
    let callerInbox = RecordingSessionInbox()

    /// The inbox of the child session.
    let childInbox = RecordingSessionInbox()

    /// The inbox of a session of the pair.
    private func inbox(of session: SessionId) -> RecordingSessionInbox {
      session == caller ? callerInbox : childInbox
    }

    /// Makes the send step of a mail message from `sender`, and records the updates that come
    /// back for the transcript of `sender`, as the translator of that session sends them.
    func sent(_ record: SentMessageRecord, from sender: SessionId, text: String) {
      inbox(of: sender).accept(projector.sent(record, from: sender, text: text))
    }

    /// Makes the receive step of a mail message, and records the updates that come back for the
    /// transcript of `session`.
    func delivered(_ mail: MailID, to session: SessionId) {
      inbox(of: session).accept(projector.delivered(mail, to: session))
    }

    /// Makes the message of a run, and records the updates that come back for the caller.
    func message(fromRun token: String, key: String, text: String) {
      callerInbox.accept(
        projector.message(fromRun: token, key: key, text: text, receivedBy: caller))
    }

    /// Makes the receive step of the final message, and records the updates that come back for
    /// the caller.
    func receivedFinal(ofRun token: String, text: String) {
      callerInbox.accept(projector.receivedFinal(ofRun: token, by: caller, text: text))
    }

    /// Makes the pair and attaches both inboxes.
    init() {
      let callerInbox = self.callerInbox
      let childInbox = self.childInbox
      projector.attach(caller) { callerInbox.accept($0) }
      projector.attach(child) { childInbox.accept($0) }
    }
  }

  /// The record of a message that `send agent` mailed to the child.
  private static func toChild(_ mail: MailID, child: SessionId) -> SentMessageRecord {
    SentMessageRecord(
      mailId: mail.value.description, direction: .toChild, receiverRunId: child.rawValue,
      receiverSessionId: child.rawValue)
  }

  /// The record of a message that `send caller` mailed to the caller.
  private static func toCaller(_ mail: MailID, caller: SessionId) -> SentMessageRecord {
    SentMessageRecord(
      mailId: mail.value.description, direction: .toCaller, receiverRunId: nil,
      receiverSessionId: caller.rawValue)
  }

  @Test("send agent sends the outgoing view to the caller transcript at once")
  func sendAgentSendsTheOutgoingViewAtOnce() throws {
    let pair = Pair()
    let mail = MailID()

    pair.sent(Self.toChild(mail, child: pair.child), from: pair.caller, text: Self.text)

    let outgoing = try #require(pair.callerInbox.messages.first)
    #expect(outgoing.firstText == Self.text)
    #expect(outgoing.senderSessionId == .value(pair.caller))
    #expect(outgoing.recipientSessionId == .value(pair.child))
    #expect(outgoing.senderMessageId == .unchanged)
  }

  @Test("send agent sends no incoming view before the child received the mail")
  func sendAgentSendsNoIncomingViewEarly() {
    let pair = Pair()

    pair.sent(
      Self.toChild(MailID(), child: pair.child), from: pair.caller, text: Self.text)

    #expect(pair.childInbox.updates.isEmpty)
  }

  @Test("the child receipt sends the incoming view to the child transcript")
  func theReceiptSendsTheIncomingView() throws {
    let pair = Pair()
    let mail = MailID()
    pair.sent(Self.toChild(mail, child: pair.child), from: pair.caller, text: Self.text)

    pair.delivered(mail, to: pair.child)

    let incoming = try #require(pair.childInbox.messages.first)
    let outgoing = try #require(pair.callerInbox.messages.first)
    #expect(incoming.firstText == Self.text)
    #expect(incoming.senderSessionId == .value(pair.caller))
    #expect(incoming.recipientSessionId == .value(pair.child))
    #expect(incoming.senderMessageId == .value(outgoing.messageId))
  }

  @Test("the receipt links the outgoing view to the incoming view by ids only")
  func theReceiptLinksTheOutgoingView() throws {
    let pair = Pair()
    let mail = MailID()
    pair.sent(Self.toChild(mail, child: pair.child), from: pair.caller, text: Self.text)

    pair.delivered(mail, to: pair.child)

    let link = try #require(pair.callerInbox.messages.last)
    let incoming = try #require(pair.childInbox.messages.first)
    #expect(link.messageId == pair.callerInbox.messages.first?.messageId)
    #expect(link.recipientMessageId == .value(incoming.messageId))
    #expect(link.content == .unchanged)
  }

  @Test("a receipt that comes before the sent record sends the views in order")
  func aReceiptBeforeTheSentRecordSendsTheViewsInOrder() throws {
    let pair = Pair()
    let mail = MailID()

    pair.delivered(mail, to: pair.child)
    #expect(pair.callerInbox.updates.isEmpty && pair.childInbox.updates.isEmpty)
    pair.sent(Self.toChild(mail, child: pair.child), from: pair.caller, text: Self.text)

    let outgoing = try #require(pair.callerInbox.messages.first)
    let incoming = try #require(pair.childInbox.messages.first)
    #expect(outgoing.firstText == Self.text)
    #expect(incoming.senderMessageId == .value(outgoing.messageId))
    #expect(pair.callerInbox.messages.last?.recipientMessageId == .value(incoming.messageId))
  }

  @Test("a receipt of a mail that nobody sent sends nothing")
  func aReceiptOfAnUnknownMailSendsNothing() {
    let pair = Pair()

    pair.delivered(MailID(), to: pair.child)

    #expect(pair.callerInbox.updates.isEmpty && pair.childInbox.updates.isEmpty)
  }

  @Test("a second receipt of the same mail sends no second incoming view")
  func aSecondReceiptSendsNothing() {
    let pair = Pair()
    let mail = MailID()
    pair.sent(Self.toChild(mail, child: pair.child), from: pair.caller, text: Self.text)

    pair.delivered(mail, to: pair.child)
    pair.delivered(mail, to: pair.child)

    #expect(pair.childInbox.messages.count == 1)
  }

  @Test("send caller over the mail route sends the outgoing view to the child transcript")
  func sendCallerSendsTheOutgoingViewToTheChild() throws {
    let pair = Pair()

    pair.sent(Self.toCaller(MailID(), caller: pair.caller), from: pair.child, text: Self.text)

    let outgoing = try #require(pair.childInbox.messages.first)
    #expect(outgoing.senderSessionId == .value(pair.child))
    #expect(outgoing.recipientSessionId == .value(pair.caller))
    #expect(pair.callerInbox.updates.isEmpty)
  }

  @Test("the caller receipt sends the incoming view to the caller transcript")
  func theCallerReceiptSendsTheIncomingView() throws {
    let pair = Pair()
    let mail = MailID()
    pair.sent(Self.toCaller(mail, caller: pair.caller), from: pair.child, text: Self.text)

    pair.delivered(mail, to: pair.caller)

    let incoming = try #require(pair.callerInbox.messages.first)
    #expect(incoming.firstText == Self.text)
    #expect(incoming.senderMessageId == .value(try #require(pair.childInbox.messages.first).messageId))
  }

  @Test("a message of a run waits for the bind of its token")
  func aRunMessageWaitsForTheBind() {
    let pair = Pair()

    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)

    #expect(pair.callerInbox.updates.isEmpty && pair.childInbox.updates.isEmpty)
  }

  @Test("the bind sends the views of a message that came before it")
  func theBindSendsTheWaitingViews() throws {
    let pair = Pair()
    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)

    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    let outgoing = try #require(pair.childInbox.messages.first)
    let incoming = try #require(pair.callerInbox.messages.first)
    #expect(outgoing.senderSessionId == .value(pair.child))
    #expect(incoming.recipientSessionId == .value(pair.caller))
    #expect(incoming.senderMessageId == .value(outgoing.messageId))
  }

  @Test("a message of a bound run sends outgoing, incoming and link in order")
  func aBoundRunMessageSendsTheThreeUpdates() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)

    let incoming = try #require(pair.callerInbox.messages.first)
    #expect(pair.childInbox.messages.count == 2)
    #expect(pair.childInbox.messages.last?.recipientMessageId == .value(incoming.messageId))
    #expect(pair.childInbox.messages.last?.content == .unchanged)
  }

  @Test("a message of a run with the same key sends its views one time")
  func aRepeatedRunMessageSendsOneTime() {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)
    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)

    #expect(pair.callerInbox.messages.count == 1)
  }

  @Test("two messages of a run get two different message ids")
  func twoRunMessagesGetDifferentIds() {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)
    pair.message(fromRun: "TOKEN", key: "mail-2", text: Self.text)

    let ids = Set(pair.callerInbox.messages.map(\.messageId))
    #expect(ids.count == 2)
  }

  @Test("a message ids derive from the key, so a second projector gives the same ids")
  func theIdsAreDeterministic() throws {
    let first = Pair()
    let second = Pair()
    for pair in [first, second] {
      pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
      pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)
    }

    #expect(first.callerInbox.messages.first?.messageId == second.callerInbox.messages.first?.messageId)
  }

  @Test("a detached session gets no view")
  func aDetachedSessionGetsNoView() {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.projector.detach(pair.child)

    pair.message(fromRun: "TOKEN", key: "mail-1", text: Self.text)

    #expect(pair.childInbox.updates.isEmpty)
  }

  // MARK: - The final message

  /// The reply of the run in the tests of the final message.
  private static let reply = "The second file is fine."

  /// The report that the caller gets for the end of the run.
  private static let report = "Agent reader (run-1) finished.\n\nThe second file is fine."

  @Test("the end of a run sends the reply as the outgoing view in the child transcript")
  func theEndOfARunSendsTheOutgoingView() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)

    let outgoing = try #require(pair.childInbox.messages.first)
    #expect(outgoing.firstText == Self.reply)
    #expect(outgoing.senderSessionId == .value(pair.child))
    #expect(outgoing.recipientSessionId == .value(pair.caller))
  }

  @Test("the outgoing view of the final message names the incoming view at once")
  func theFinalOutgoingViewNamesTheIncomingView() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)
    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    let outgoing = try #require(pair.childInbox.messages.first)
    let incoming = try #require(pair.callerInbox.messages.first)

    #expect(outgoing.recipientMessageId == .value(incoming.messageId))
  }

  @Test("the journal of the end sends the report as the incoming view in the caller transcript")
  func theJournalOfTheEndSendsTheIncomingView() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)

    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    let incoming = try #require(pair.callerInbox.messages.first)
    #expect(incoming.firstText == Self.report)
    #expect(incoming.senderMessageId == .value(try #require(pair.childInbox.messages.first).messageId))
  }

  @Test("the journal of the end sends no patch to the child transcript")
  func theJournalOfTheEndSendsNoPatchToTheChild() {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)

    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    #expect(pair.childInbox.messages.count == 1)
  }

  @Test("the journal of the end sends no incoming view before the end of the run")
  func theJournalBeforeTheEndSendsNothingYet() {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)

    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    #expect(pair.callerInbox.updates.isEmpty)
  }

  @Test("the end of a run after the journal sends both views")
  func theEndAfterTheJournalSendsBothViews() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)

    #expect(pair.childInbox.messages.first?.firstText == Self.reply)
    #expect(pair.callerInbox.messages.first?.firstText == Self.report)
  }

  @Test("a run with no reply sends the incoming view without an outgoing view")
  func aRunWithNoReplySendsOnlyTheIncomingView() throws {
    let pair = Pair()
    pair.projector.bind(token: "TOKEN", child: pair.child, caller: pair.caller)
    pair.projector.finalReply(ofRun: "TOKEN", text: nil)

    pair.receivedFinal(ofRun: "TOKEN", text: Self.report)

    let incoming = try #require(pair.callerInbox.messages.first)
    #expect(incoming.senderMessageId == .unchanged)
    #expect(pair.childInbox.updates.isEmpty)
  }

  @Test("the end of a run that is not bound sends nothing")
  func theEndOfAnUnboundRunSendsNothing() {
    let pair = Pair()

    pair.projector.finalReply(ofRun: "TOKEN", text: Self.reply)

    #expect(pair.childInbox.updates.isEmpty)
  }
}
