import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

// MARK: - The messages of the session directory
//
// The session directory delivers a message from the user in another session, or from a session
// through the `sessions` tool (ACPA-6, D199 (f)). The target session gets one `session_message`
// view with `SAH.SessionMessage` in `_meta`, when it takes the mail, or when it reads the message
// with the `inbox` operation of the `sessions` tool. The projector of the messages
// (``SubagentMessageProjector``) holds the state. The types here read the directory.

/// A message that the session directory delivered to a session of this agent, ready to show.
struct DirectoryMessage: Sendable {
  /// The key of the message: the text of the id of its mail.
  let key: String

  /// The sender of the message, as the directory gives it.
  let from: SessionMessageSender

  /// The sender session, or the source session of a user message. `nil` for a user message that
  /// the user wrote in no session.
  let senderSessionId: SessionId?

  /// The session that got the message.
  let recipient: SessionId

  /// The text of the message, with no sender header.
  let text: String

  /// The `_meta` of the view, with `SAH.SessionMessage`, or `nil` when it did not encode.
  let meta: FoundationModelsACP.JSONValue?

  /// The id of the view in the transcript of the recipient.
  var incomingId: MessageId { .incomingView(of: key) }

  /// The view of the message in the transcript of the recipient.
  var incomingView: SessionUpdate {
    .sessionMessage(
      SessionMessage(
        messageId: incomingId, content: .value([.text(TextContent(text: text))]),
        recipientSessionId: .value(recipient),
        senderSessionId: senderSessionId.map { .value($0) } ?? .unchanged,
        meta: meta.map { .value($0) } ?? .unchanged))
  }

  /// The host mail that this message can be, or `nil` for a user message. Only a session sends
  /// host mail.
  var hostMail: ExpectedHostMail? {
    guard case .session = from, let senderSessionId else {
      return nil
    }
    return ExpectedHostMail(sender: senderSessionId, recipient: recipient, text: text)
  }
}

/// A mail that the host mail route sends through the session directory
/// (``RoutedACPAgent/makeAgentRunHost(recordingRoot:)``). The route records it before the send,
/// so the directory path of the projector does not show it a second time.
///
/// The projector finds a record with `firstIndex(of:)`, so the synthesized `Equatable`
/// conformance is the only reader of each property. Periphery does not see a synthesized
/// reader, so each property has a marker.
struct ExpectedHostMail: Equatable, Sendable {
  /// The session of the run that sends the mail.
  /// Read by the synthesized `Equatable` conformance; periphery sees no reader.
  // periphery:ignore
  let sender: SessionId

  /// The caller session that gets the mail.
  /// Read by the synthesized `Equatable` conformance; periphery sees no reader.
  // periphery:ignore
  let recipient: SessionId

  /// The text of the mail.
  /// Read by the synthesized `Equatable` conformance; periphery sees no reader.
  // periphery:ignore
  let text: String
}

/// Reads the session directory for the messages that it delivered.
struct DirectoryMessageSource: Sendable {
  /// The session directory of the agent.
  let directory: any SessionDirectory

  /// The message of a mail that a session took, when the directory delivered it.
  ///
  /// - Parameters:
  ///   - mail: The id of the mail that the session took.
  ///   - session: The session that took it.
  /// - Returns: The message, or `nil` when the directory did not deliver the mail. A read that
  ///   fails is logged and gives `nil`. A session id that is not a ULID is unexpected: it stops
  ///   a debug build, and a release build logs it and gives `nil`.
  func message(of mail: MailID, takenBy session: SessionId) async -> FoundationModelsExtras
    .SessionMessage?
  {
    guard let recipient = ULID(ulidString: session.rawValue) else {
      assertionFailure("session id is not a ULID: \(session.rawValue)")
      ACPAgentTelemetry.logger(.session).error(
        "The id of a session is not a ULID. The directory read stops, and the mail gets no view.",
        metadata: [ACPAgentTelemetry.LogMetadataKey.sessionId: "\(session.rawValue)"])
      return nil
    }
    do {
      return try await directory.message(mail, to: recipient)
    } catch {
      Self.logFailedRead(of: session, error: error)
      return nil
    }
  }

  /// The view data of a delivered message: the sender, the text and the `_meta`.
  ///
  /// - Parameter message: The message that the directory delivered.
  /// - Returns: The message, ready to show.
  func describe(_ message: FoundationModelsExtras.SessionMessage) async -> DirectoryMessage {
    let named = Self.namedSession(of: message)
    let senderSessionId = named.map { SessionId(rawValue: $0.description) }
    let summary = await summary(of: named)
    let sender = Self.sender(of: message, sessionId: senderSessionId, summary: summary)
    let recipient = SessionId(rawValue: message.to.description)
    return DirectoryMessage(
      key: message.id.value.description, from: message.from, senderSessionId: senderSessionId,
      recipient: recipient, text: message.text,
      meta: Self.meta(
        SAH.SessionMessage(
          messageId: message.id.value.description,
          inReplyTo: message.inReplyTo?.value.description, sender: sender),
        recipient: recipient))
  }

  /// The session that a message names as its sender: the sender session, or the source session
  /// of a user message.
  ///
  /// - Parameter message: The message.
  /// - Returns: The session, or `nil` for a user message that names no session.
  private static func namedSession(of message: FoundationModelsExtras.SessionMessage) -> ULID? {
    switch message.from {
    case .session(let sender): sender
    case .user: message.sourceSession
    }
  }

  /// The summary of the named session.
  ///
  /// - Parameter id: The session, or `nil`.
  /// - Returns: The summary, or `nil` when there is no session or the directory does not know
  ///   it. A read that fails is logged and gives `nil`.
  private func summary(of id: ULID?) async -> SessionSummary? {
    guard let id else {
      return nil
    }
    do {
      return try await directory.summary(of: id)
    } catch {
      Self.logFailedRead(of: SessionId(rawValue: id.description), error: error)
      return nil
    }
  }

  /// The sender object of `_meta.sah.message`.
  ///
  /// - Parameters:
  ///   - message: The message.
  ///   - sessionId: The named session of the message, or `nil`.
  ///   - summary: The summary of the named session, or `nil`.
  /// - Returns: The sender. A user sender has no agent.
  private static func sender(
    of message: FoundationModelsExtras.SessionMessage, sessionId: SessionId?,
    summary: SessionSummary?
  ) -> SAH.SessionMessage.Sender {
    let isSession = if case .session = message.from { true } else { false }
    return SAH.SessionMessage.Sender(
      kind: isSession ? .session : .user, sessionId: sessionId,
      title: summary?.title.flatMap(nonEmpty),
      agent: isSession ? summary.map { $0.agentName.flatMap(nonEmpty) ?? $0.agentID } : nil,
      cwd: summary?.workingDirectory.path)
  }

  /// A text that is not empty.
  ///
  /// - Parameter text: The text.
  /// - Returns: The text, or `nil` when it is empty.
  private static func nonEmpty(_ text: String) -> String? {
    text.isEmpty ? nil : text
  }

  /// The `_meta` of a view, with `object` in `_meta.sah.message`.
  ///
  /// - Parameters:
  ///   - object: The message object.
  ///   - recipient: The session that gets the view, for the log.
  /// - Returns: The `_meta`, or `nil` when the object did not encode. The failure is logged.
  private static func meta(_ object: SAH.SessionMessage, recipient: SessionId)
    -> FoundationModelsACP.JSONValue?
  {
    do {
      return try object.inject(into: nil)
    } catch {
      assertionFailure("the message object did not encode: \(error)")
      ACPAgentTelemetry.logger(.session).error(
        "The sender of a directory message did not encode. The view goes out with no sender.",
        metadata: [
          ACPAgentTelemetry.LogMetadataKey.sessionId: "\(recipient.rawValue)",
          ACPAgentTelemetry.LogMetadataKey.errorType: "\(type(of: error))",
        ])
      return nil
    }
  }

  /// Logs a read of the directory that failed.
  ///
  /// - Parameters:
  ///   - session: The session of the read.
  ///   - error: The error of the read.
  private static func logFailedRead(of session: SessionId, error: any Error) {
    ACPAgentTelemetry.logger(.session).warning(
      "A read of the session directory failed. The message view has less data.",
      metadata: [
        ACPAgentTelemetry.LogMetadataKey.sessionId: "\(session.rawValue)",
        ACPAgentTelemetry.LogMetadataKey.errorType: "\(type(of: error))",
        "error.message": "\(error)",
      ])
  }
}

/// Reads the events of the session directory for a projector of messages, in a task of its own.
/// The task ends when the projector goes away (``stop()``).
final class DirectoryMessageFeed: Sendable {
  /// The task that reads the events, or `nil` before the start.
  private let task = Mutex<Task<Void, Never>?>(nil)

  /// Makes a feed that reads nothing yet.
  init() {}

  /// Starts to read `events` into `projector`. The stream is open before this call returns, so
  /// no event after the call is lost.
  ///
  /// - Parameters:
  ///   - events: The event stream of the directory.
  ///   - projector: The projector that gets each event. The feed holds it weakly.
  func start(
    reading events: AsyncStream<SessionDirectoryEvent>, into projector: SubagentMessageProjector
  ) {
    let reader = Task { [weak projector] in
      for await event in events {
        guard let projector else {
          return
        }
        await projector.directoryEventArrived(event)
      }
    }
    task.withLock { $0 = reader }
  }

  /// Stops the task. The event stream then closes.
  func stop() {
    task.withLock { $0?.cancel() }
  }
}
