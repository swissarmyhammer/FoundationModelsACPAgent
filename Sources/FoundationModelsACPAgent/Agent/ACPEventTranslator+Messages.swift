import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

// MARK: - The messages between a caller and a child
//
// A message between a caller and a child has a `session_message` view in the transcript of each
// of its two sessions (``SubagentMessageProjector``). This session finds the message in its own
// events, and hands it to the projector of the surface. The projector gives back the updates for
// this session, which the translator sends in the order of its events. It gives the updates for
// the other session to the inbox of that session.

extension ACPEventTranslator {
  /// The key of the JSON argument that holds the text of a message. `send agent` and `send
  /// caller` both name it `message`.
  private static let messageArgumentKey = "message"

  /// Takes the sent-message records out of the report of a tool call. The records are for the
  /// projector of the surface, never for the client as tool call content. The text of a message
  /// is in the arguments of the SDK `toolCall` event of the same call. That event can come before
  /// or after the report. So the records wait for the text, or the text waits for the records
  /// (``sendMessages(ofCall:)``).
  ///
  /// - Parameter report: The report of the call.
  /// - Returns: The report with its other attachments, or `nil` when the call attached only
  ///   sent-message records.
  mutating func keepSentMessages(of report: ToolCallReport) async -> ToolCallReport? {
    let records = report.attachments.compactMap(SentMessageRecord.init(attachment:))
    guard !records.isEmpty else {
      return report
    }
    let callId = runCallJoins.toolCallId(for: RunToken(report.correlationID)).rawValue
    sentMessages[callId, default: []] += records
    await sendMessages(ofCall: callId)
    let rest = report.attachments.filter { $0.schemaName != SentMessageRecord.schemaName }
    guard !rest.isEmpty else {
      return nil
    }
    return ToolCallReport(
      tool: report.tool, op: report.op, correlationID: report.correlationID,
      sessionID: report.sessionID, attachments: rest)
  }

  /// Keeps the text of the message in the arguments of an SDK tool call. The call can be a call
  /// that mails a message. The text waits for the report of the call, or goes out at once with
  /// the records that wait for it (``sendMessages(ofCall:)``). A call of a tool that starts no
  /// child, and a call with no text, keep nothing.
  ///
  /// - Parameters:
  ///   - id: The SDK id of the call.
  ///   - name: The name of the tool.
  ///   - argumentsJSON: The arguments of the call.
  mutating func keepMessageText(ofCall id: String, tool name: String, argumentsJSON: String) async {
    guard runCallJoins.holds.holdsCalls(of: name),
      let text = Self.messageText(inArguments: argumentsJSON)
    else {
      return
    }
    messageTexts.store(text, forCall: id)
    await sendMessages(ofCall: id)
  }

  /// Sends the outgoing views of the messages that a tool call mailed, when both the records of
  /// the call and the text of its arguments are known. Else it does nothing.
  ///
  /// - Parameter id: The SDK id of the call. It is the wire id that the join table gave the
  ///   report.
  private mutating func sendMessages(ofCall id: String) async {
    guard sentMessages[id] != nil, let text = messageTexts.take(forCall: id),
      let records = sentMessages.removeValue(forKey: id)
    else {
      return
    }
    for record in records {
      await sendAll(runCallJoins.messages.sent(record, from: sessionId, text: text))
    }
  }

  /// Sends the incoming view of a mail that this session took, when the mail is a message of the
  /// `agents` tool. Any other mail, for example the mail of a prompt, sends nothing.
  ///
  /// - Parameter mail: The mail that the session took.
  func receiveMessage(of mail: MailID) async {
    await sendAll(runCallJoins.messages.delivered(mail, to: sessionId))
  }

  /// Sends the incoming view of a message that a run of the call route posted to this session.
  /// The event is both steps of the message. An event of a tool that starts no child, and an event
  /// with no text, send nothing.
  ///
  /// - Parameter event: The `runMessage` event of the run.
  mutating func sendMessage(of event: OperationEvent) async {
    guard runCallJoins.holds.holdsCalls(of: event.tool), !event.detail.isEmpty else {
      return
    }
    await sendAll(
      runCallJoins.messages.message(
        fromRun: event.correlationID, key: messageKey(of: event), text: event.detail,
        receivedBy: sessionId))
  }

  /// Sends the incoming view of the final message of a run. The `runSettled` event of the run is
  /// the receive step of the message. The final message comes from a run of the tool that starts
  /// a child only.
  ///
  /// - Parameter event: The `runSettled` event of the run.
  func receiveFinalMessage(of event: OperationEvent) async {
    guard runCallJoins.holds.holdsCalls(of: event.tool), !event.detail.isEmpty else {
      return
    }
    await sendAll(
      runCallJoins.messages.receivedFinal(
        ofRun: event.correlationID, by: sessionId, text: event.detail))
  }

  /// Sends updates to the client, in order.
  ///
  /// - Parameter updates: The updates.
  private func sendAll(_ updates: [SessionUpdate]) async {
    for update in updates {
      await send(update)
    }
  }

  /// The key of a message of a run. It derives from the one mail that holds the message, so a
  /// message that a restore sends again gets the same key. A message with no single mail in its
  /// origin gets a key from the token of the run and a count.
  ///
  /// - Parameter event: The event of the message.
  /// - Returns: The key. Its first part names the kind of the event.
  private mutating func messageKey(of event: OperationEvent) -> String {
    if case .mail(let ids) = origin, ids.count == 1, let mail = ids.first {
      return "\(event.kind.rawValue)-\(mail.value.description)"
    }
    unmailedMessageCount += 1
    return "\(event.kind.rawValue)-\(event.correlationID)-\(unmailedMessageCount)"
  }

  /// The text of the `message` argument of a call.
  ///
  /// - Parameter argumentsJSON: The arguments of the call, as JSON text.
  /// - Returns: The text, or `nil` when the arguments are not an object with a text `message`.
  private static func messageText(inArguments argumentsJSON: String) -> String? {
    guard
      let arguments = try? JSONDecoder().decode(
        FoundationModelsACP.JSONValue.self, from: Data(argumentsJSON.utf8)),
      case .object(let fields) = arguments, case .string(let text) = fields[messageArgumentKey]
    else {
      return nil
    }
    return text
  }
}

/// The texts of the messages in the arguments of recent tool calls, by the SDK id of the call. A
/// call that mails no message leaves its text here, so the set keeps only the newest.
struct MessageTexts: Sendable {
  /// The most texts that the set keeps.
  fileprivate static let limit = 32

  /// The texts by the SDK id of the call.
  private var texts = BoundedTable<String>(limit: MessageTexts.limit)

  /// Keeps the text of a call. At the limit, the oldest text leaves.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - id: The SDK id of the call.
  mutating func store(_ text: String, forCall id: String) {
    texts.store(text, for: id)
  }

  /// Takes the text of a call out of the set.
  ///
  /// - Parameter id: The SDK id of the call.
  /// - Returns: The text, or `nil` when the set holds none for the call.
  mutating func take(forCall id: String) -> String? {
    texts.remove(id)
  }
}
