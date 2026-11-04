import FoundationModelsACP
import FoundationModelsRouter
import Synchronization

/// The `session_message` views of the messages between a caller and a child session.
///
/// A message has two views. The outgoing view is in the transcript of the sender. The incoming
/// view is in the transcript of the receiver. Each view has its own `messageId`. The two views
/// link only by ids: the incoming view names the outgoing view in `senderMessageId`, and the
/// outgoing view names the incoming view in `recipientMessageId`. Both ids derive from one key,
/// so the same message always gets the same two ids, also after a restore. A key sends its views
/// one time.
///
/// The object serves all sessions of one surface (``RunCallJoinTable/messages``). Each session
/// attaches an inbox (``attach(_:inbox:)``): the projector of the session gives the inbox. An
/// update that goes to an inbox goes through the projector of that session, so it keeps its order
/// with the events of the session, and a closed gate holds it until the announcement of the
/// session.
///
/// A message goes in two steps. The send step makes the outgoing view. The receive step makes the
/// incoming view, and never comes before the receiver got the message. A receive that comes
/// before the send waits for it. Each call that a session makes from its own events returns the
/// updates for the transcript of that session, so the session sends them at once, in the order of
/// its events. The call gives the updates for any other session to the inbox of that session.
///
/// Three routes make messages.
///
/// - The mail route (``sent(_:from:text:)``, ``delivered(_:to:)``). The `agents` tool attached a
///   record to the tool call that mailed the message. The send step is the record with its text.
///   The receive step is the `mailDelivered` event of the receiver.
/// - The message of a run (``bind(token:child:caller:)``, ``message(fromRun:key:text:receivedBy:)``).
///   A run of the call route posts a message to its caller. The caller journals it as a
///   `runMessage` event, which is both steps. A message whose run is not bound yet waits for the
///   bind.
/// - The final message of a run (``finalReply(ofRun:text:)``, ``receivedFinal(ofRun:by:text:)``).
///   The send step is the end of the run, with its reply. The receive step is the `runSettled`
///   event of the caller. The caller can journal the end after the run retired its session, so
///   the outgoing view names the incoming view at once (the ids derive from the token). A run
///   with no reply (a failed or a cancelled run) has no outgoing view, and its incoming view
///   names none.
///
/// A class, because the sessions of a surface share one object. A `Mutex` guards the state. The
/// object calls an inbox after it left the lock, so an inbox can call the object.
final class SubagentMessageProjector: Sendable {
  /// Gives one update to the stream of a session. It never waits.
  typealias Inbox = @Sendable (SessionUpdate) -> Void

  /// The most entries that each table of the object keeps. At the limit the oldest entry leaves.
  fileprivate static let tableLimit = 1024

  /// The state, under its lock.
  private let state = Mutex(State())

  /// Makes an object with no session.
  init() {}

  // MARK: - The sessions

  /// Attaches the inbox of a session. A second call for the same session replaces the inbox.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - inbox: Gives one update to the stream of the session.
  func attach(_ session: SessionId, inbox: @escaping Inbox) {
    state.withLock { $0.inboxes[session] = inbox }
  }

  /// Detaches the inbox of a session. A view for the session then goes nowhere.
  ///
  /// - Parameter session: The session.
  func detach(_ session: SessionId) {
    state.withLock { _ = $0.inboxes.removeValue(forKey: session) }
  }

  // MARK: - The mail route

  /// The send step of a message that the `agents` tool mailed. If the receiver took the mail
  /// already, the receive step follows at once.
  ///
  /// - Parameters:
  ///   - record: The record that the tool attached to the call.
  ///   - sender: The session that holds the call.
  ///   - text: The text of the message, from the arguments of the call.
  /// - Returns: The updates for the transcript of `sender`.
  func sent(_ record: SentMessageRecord, from sender: SessionId, text: String) -> [SessionUpdate] {
    let message = Message(
      key: record.mailId, sender: sender,
      recipient: SessionId(rawValue: record.receiverSessionId), text: text)
    return perform(as: sender) { $0.send(message) }
  }

  /// The receive step of a message that the `agents` tool mailed: a session took a mail. A mail
  /// that is not a message of the `agents` tool, for example the mail of a prompt, sends nothing.
  ///
  /// - Parameters:
  ///   - mail: The mail that the session took.
  ///   - session: The session that took it.
  /// - Returns: The updates for the transcript of `session`.
  func delivered(_ mail: MailID, to session: SessionId) -> [SessionUpdate] {
    perform(as: session) {
      $0.receive(key: mail.value.description, by: session, text: nil)
    }
  }

  // MARK: - The message of a run

  /// Binds a run to its two sessions, and sends the views of the messages that waited for it.
  /// All views go to the inboxes.
  ///
  /// - Parameters:
  ///   - token: The completion token of the `start agent` call that started the run.
  ///   - child: The session of the run.
  ///   - caller: The session that started the run.
  func bind(token: String, child: SessionId, caller: SessionId) {
    let run = Run(child: child, caller: caller)
    let token = token.uppercased()
    perform(as: nil) { state in
      state.runs.store(run, for: token)
      let waiting = state.waitingRunMessages.remove(token) ?? []
      return waiting.flatMap { state.runMessage($0, of: run) }
    }
  }

  /// Sends both steps of a message that a run posted to its caller. The caller session has the
  /// message when this call comes. A run that is not bound waits for the bind.
  ///
  /// - Parameters:
  ///   - token: The completion token of the `start agent` call that started the run.
  ///   - key: The key of the message. A message with a key that went out is not sent again.
  ///   - text: The text of the message.
  ///   - caller: The session that holds the message, which is the caller of the run.
  /// - Returns: The updates for the transcript of `caller`.
  func message(fromRun token: String, key: String, text: String, receivedBy caller: SessionId)
    -> [SessionUpdate]
  {
    let waiting = WaitingRunMessage(key: key, text: text)
    let token = token.uppercased()
    return perform(as: caller) { state in
      guard let run = state.runs[token] else {
        state.waitingRunMessages.store(
          (state.waitingRunMessages[token] ?? []) + [waiting], for: token)
        return []
      }
      return state.runMessage(waiting, of: run)
    }
  }

  // MARK: - The final message of a run

  /// The send step of the final message of a run: the end of the run. A run that is not bound
  /// sends nothing.
  ///
  /// - Parameters:
  ///   - token: The completion token of the `start agent` call that started the run.
  ///   - text: The reply of the run, or `nil` for a run that failed or was cancelled. A blank
  ///     reply is the same as none.
  func finalReply(ofRun token: String, text: String?) {
    let token = token.uppercased()
    perform(as: nil) { state in
      guard let run = state.runs[token] else {
        return []
      }
      let key = Self.finalKey(of: token)
      guard let text, !text.allSatisfy(\.isWhitespace) else {
        return state.sendNothing(
          Message(key: key, sender: run.child, recipient: run.caller, text: ""))
      }
      return state.send(
        Message(
          key: key, sender: run.child, recipient: run.caller, text: text,
          namesIncomingAtSend: true))
    }
  }

  /// The receive step of the final message of a run: the caller journaled the end of the run.
  ///
  /// - Parameters:
  ///   - token: The completion token of the `start agent` call that started the run.
  ///   - caller: The session that journaled the end of the run.
  ///   - text: The text that the caller got: the report of the end.
  /// - Returns: The updates for the transcript of `caller`.
  func receivedFinal(ofRun token: String, by caller: SessionId, text: String) -> [SessionUpdate] {
    perform(as: caller) {
      $0.receive(key: Self.finalKey(of: token.uppercased()), by: caller, text: text)
    }
  }

  /// The key of the final message of a run.
  ///
  /// - Parameter token: The completion token of the run, in upper case.
  /// - Returns: The key.
  private static func finalKey(of token: String) -> String {
    "final-\(token)"
  }

  // MARK: - The delivery

  /// Runs a step under the lock, then gives the updates of the step out in order. An update for
  /// the session `current` goes back to the caller. Each other update goes to the inbox of its
  /// session.
  ///
  /// - Parameters:
  ///   - current: The session that made the call, or `nil` for a call of no session.
  ///   - step: The step. It returns the updates to give.
  /// - Returns: The updates for `current`, in order.
  @discardableResult
  private func perform(as current: SessionId?, _ step: (inout State) -> [Delivery])
    -> [SessionUpdate]
  {
    let deliveries = state.withLock { step(&$0) }
    var inline: [SessionUpdate] = []
    for delivery in deliveries {
      if delivery.session == current {
        inline.append(delivery.update)
      } else {
        delivery.inbox?(delivery.update)
      }
    }
    return inline
  }
}

// MARK: - The types of the state

extension SubagentMessageProjector {
  /// One message between two sessions.
  fileprivate struct Message: Sendable {
    /// The key of the message. The ids of both views derive from it.
    let key: String

    /// The session that sent the message.
    let sender: SessionId

    /// The session that got the message.
    let recipient: SessionId

    /// The text of the message, as the sender wrote it.
    let text: String

    /// Whether the outgoing view names the incoming view when it goes out. A message whose
    /// receive step can come after the sender session ended needs this.
    var namesIncomingAtSend = false

    /// The id of the outgoing view, in the transcript of the sender.
    var outgoingId: MessageId { MessageId(rawValue: "out-\(key)") }

    /// The id of the incoming view, in the transcript of the recipient.
    var incomingId: MessageId { MessageId(rawValue: "in-\(key)") }

    /// The outgoing view: the message with its text, for the transcript of the sender.
    var outgoingView: SessionUpdate {
      .sessionMessage(
        SessionMessage(
          messageId: outgoingId, content: .value([.text(TextContent(text: text))]),
          recipientMessageId: namesIncomingAtSend ? .value(incomingId) : .unchanged,
          recipientSessionId: .value(recipient), senderSessionId: .value(sender)))
    }

    /// The incoming view: the message with its text, for the transcript of the receiver.
    ///
    /// - Parameters:
    ///   - receiver: The session that got the message.
    ///   - text: The text that the receiver got.
    ///   - hasOutgoingView: Whether the incoming view names an outgoing view.
    /// - Returns: The update.
    func incomingView(receivedBy receiver: SessionId, text: String, hasOutgoingView: Bool = true)
      -> SessionUpdate
    {
      .sessionMessage(
        SessionMessage(
          messageId: incomingId, content: .value([.text(TextContent(text: text))]),
          recipientSessionId: .value(receiver),
          senderMessageId: hasOutgoingView ? .value(outgoingId) : .unchanged,
          senderSessionId: .value(sender)))
    }

    /// The patch that names the incoming view in the outgoing view. It changes nothing else.
    var linkView: SessionUpdate {
      .sessionMessage(
        SessionMessage(messageId: outgoingId, recipientMessageId: .value(incomingId)))
    }
  }

  /// A run that is bound to its two sessions.
  fileprivate struct Run: Sendable {
    /// The session of the run.
    let child: SessionId

    /// The session that started the run.
    let caller: SessionId
  }

  /// A message of a run that waits for the bind of the run.
  fileprivate struct WaitingRunMessage: Sendable {
    /// The key of the message.
    let key: String

    /// The text of the message.
    let text: String
  }

  /// A receive step that came before its send step.
  fileprivate struct Receipt: Sendable {
    /// The session that got the message.
    let session: SessionId

    /// The text that the session got, or `nil` for the text of the sender.
    let text: String?
  }

  /// An update, and the session whose transcript holds it.
  fileprivate struct Delivery: Sendable {
    /// The session whose transcript holds the update.
    let session: SessionId

    /// The inbox of the session, or `nil` when the session has none.
    let inbox: Inbox?

    /// The update.
    let update: SessionUpdate
  }

  /// An empty table with the limit of the tables of the object.
  fileprivate static func newTable<Value: Sendable>() -> BoundedTable<Value> {
    BoundedTable(limit: tableLimit)
  }

  /// The state that the lock guards.
  fileprivate struct State: Sendable {
    /// The inbox of each attached session.
    var inboxes: [SessionId: Inbox] = [:]

    /// The bound runs, by completion token in upper case.
    var runs: BoundedTable<Run> = SubagentMessageProjector.newTable()

    /// The messages of runs that are not bound yet, by completion token in upper case.
    var waitingRunMessages: BoundedTable<[WaitingRunMessage]> = SubagentMessageProjector.newTable()

    /// The messages whose send step is done and whose receive step is not, by key.
    var awaitingReceipt: BoundedTable<Message> = SubagentMessageProjector.newTable()

    /// The messages that have no outgoing view, and whose receive step is not done, by key.
    var withoutOutgoingView: BoundedTable<Message> = SubagentMessageProjector.newTable()

    /// The receive steps that came before their send step, by key.
    var earlyReceipts: BoundedTable<Receipt> = SubagentMessageProjector.newTable()

    /// The keys whose send step is done.
    var sentKeys = RecentIDSet<String>(limit: SubagentMessageProjector.tableLimit)

    /// Records that the send step of a key is done.
    ///
    /// - Parameter key: The key of the message.
    /// - Returns: `true` the first time. `false` when the key was done already.
    mutating func markSent(_ key: String) -> Bool {
      guard !sentKeys.contains(key) else {
        return false
      }
      sentKeys.insert(key)
      return true
    }

    /// An update with the inbox of the session that gets it.
    ///
    /// - Parameters:
    ///   - session: The session whose transcript holds the update.
    ///   - update: The update.
    /// - Returns: The delivery.
    func delivery(to session: SessionId, _ update: SessionUpdate) -> Delivery {
      Delivery(session: session, inbox: inboxes[session], update: update)
    }

    /// The updates that finish a message when its receiver got it: the incoming view, then the
    /// patch that links the outgoing view to it. A message that named its incoming view at the
    /// send needs no patch.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - receiver: The session that got the message.
    ///   - text: The text that the receiver got.
    /// - Returns: The deliveries, in order.
    func completion(of message: Message, receivedBy receiver: SessionId, text: String)
      -> [Delivery]
    {
      let incoming = delivery(
        to: receiver, message.incomingView(receivedBy: receiver, text: text))
      return message.namesIncomingAtSend
        ? [incoming] : [incoming, delivery(to: message.sender, message.linkView)]
    }

    /// The send step of a message. If the receive step came before, the message finishes.
    ///
    /// - Parameter message: The message.
    /// - Returns: The deliveries, in order. None for a key that was done.
    mutating func send(_ message: Message) -> [Delivery] {
      guard markSent(message.key) else {
        return []
      }
      let outgoing = delivery(to: message.sender, message.outgoingView)
      guard let receipt = earlyReceipts.remove(message.key) else {
        awaitingReceipt.store(message, for: message.key)
        return [outgoing]
      }
      return [outgoing]
        + completion(
          of: message, receivedBy: receipt.session, text: receipt.text ?? message.text)
    }

    /// The send step of a message that has no outgoing view. If the receive step came before, the
    /// incoming view goes out at once. It names no outgoing view.
    ///
    /// - Parameter message: The message. Its text is not used.
    /// - Returns: The deliveries. None for a key that was done.
    mutating func sendNothing(_ message: Message) -> [Delivery] {
      guard markSent(message.key) else {
        return []
      }
      guard let receipt = earlyReceipts.remove(message.key) else {
        withoutOutgoingView.store(message, for: message.key)
        return []
      }
      return incomingOnly(of: message, receivedBy: receipt.session, text: receipt.text ?? "")
    }

    /// The receive step of a message.
    ///
    /// - Parameters:
    ///   - key: The key of the message.
    ///   - receiver: The session that got the message.
    ///   - text: The text that the receiver got, or `nil` for the text of the sender.
    /// - Returns: The deliveries, in order. None when the send step did not come yet, and none
    ///   for a key that is not a message or was done.
    mutating func receive(key: String, by receiver: SessionId, text: String?) -> [Delivery] {
      if let message = awaitingReceipt.remove(key) {
        return completion(of: message, receivedBy: receiver, text: text ?? message.text)
      }
      if let message = withoutOutgoingView.remove(key) {
        return incomingOnly(of: message, receivedBy: receiver, text: text ?? "")
      }
      if !sentKeys.contains(key) {
        earlyReceipts.store(Receipt(session: receiver, text: text), for: key)
      }
      return []
    }

    /// The incoming view of a message that has no outgoing view.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - receiver: The session that got the message.
    ///   - text: The text that the receiver got.
    /// - Returns: The deliveries.
    func incomingOnly(of message: Message, receivedBy receiver: SessionId, text: String)
      -> [Delivery]
    {
      [
        delivery(
          to: receiver,
          message.incomingView(receivedBy: receiver, text: text, hasOutgoingView: false))
      ]
    }

    /// Both steps of a message of a run. A key that went out sends nothing.
    ///
    /// - Parameters:
    ///   - waiting: The key and the text of the message.
    ///   - run: The run that posted the message.
    /// - Returns: The deliveries, in order.
    mutating func runMessage(_ waiting: WaitingRunMessage, of run: Run) -> [Delivery] {
      let message = Message(
        key: waiting.key, sender: run.child, recipient: run.caller, text: waiting.text)
      let sent = send(message)
      guard !sent.isEmpty else {
        return []
      }
      return sent + receive(key: waiting.key, by: run.caller, text: nil)
    }
  }
}
