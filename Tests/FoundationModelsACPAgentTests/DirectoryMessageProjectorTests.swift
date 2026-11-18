import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The `session_message` view of a message that the session directory delivered (ACPA-6, D199
/// (f)). The projector of the surface reads the directory, and the target session gets one
/// incoming view with `SAH.SessionMessage` in `_meta`, when it takes the mail. Each test uses the
/// in-memory directory of FoundationModelsExtras, with a target session and a source session.
@Suite struct DirectoryMessageProjectorTests {
  /// The text of the message in each test.
  private static let text = "Please read the plan in the other folder."

  /// The title of the source session.
  private static let sourceTitle = "Plan the release"

  /// The agent id of the source session.
  private static let sourceAgentID = "planner"

  /// The display name of the agent of the source session.
  private static let sourceAgentName = "Planner"

  /// The working folder of the source session.
  private static let sourceFolder = URL(fileURLWithPath: "/tmp/acpa6-source")

  /// The working folder of the target session.
  private static let targetFolder = URL(fileURLWithPath: "/tmp/acpa6-target")

  /// The client id of the UI that sends a user message.
  private static let clientID = "testudo-ui"

  /// The in-memory directory, with the two sessions.
  private let directory = InMemorySessionDirectory()

  /// The projector of the surface of the target session. It reads `directory`.
  private let projector: SubagentMessageProjector

  /// The id of the source session.
  private let source = ULID()

  /// The id of the target session.
  private let target = ULID()

  /// The inbox of the target session.
  private let targetInbox = RecordingSessionInbox()

  /// Makes the fixture: two live idle sessions in the directory, and a projector that has the
  /// target session attached.
  init() {
    directory.register(
      Self.summary(
        of: source, title: Self.sourceTitle, agentID: Self.sourceAgentID,
        agentName: Self.sourceAgentName, folder: Self.sourceFolder))
    directory.register(
      Self.summary(
        of: target, title: nil, agentID: Self.sourceAgentID, agentName: nil,
        folder: Self.targetFolder))
    projector = SubagentMessageProjector(directory: directory)
    let inbox = targetInbox
    projector.attach(targetId) { inbox.accept($0) }
  }

  /// The ACP id of the target session.
  private var targetId: SessionId { SessionId(rawValue: target.description) }

  /// The ACP id of the source session.
  private var sourceId: SessionId { SessionId(rawValue: source.description) }

  /// The summary of a live idle root session.
  ///
  /// - Parameters:
  ///   - id: The session id.
  ///   - title: The title, or `nil`.
  ///   - agentID: The agent id.
  ///   - agentName: The display name of the agent, or `nil`.
  ///   - folder: The working folder.
  /// - Returns: The summary.
  private static func summary(
    of id: ULID, title: String?, agentID: String, agentName: String?, folder: URL
  ) -> SessionSummary {
    SessionSummary(
      id: id, agentID: agentID, agentName: agentName, workingDirectory: folder, title: title,
      tags: [], kind: .root, state: .idle, origin: .client,
      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
      isLive: true)
  }

  /// Sends one message to the target through the directory.
  ///
  /// - Parameters:
  ///   - sender: The sender of the message.
  ///   - sourceSession: The session in which the user wrote the message, or `nil`.
  /// - Returns: The message as the directory delivered it.
  private func send(from sender: SessionMessageSender, sourceSession: ULID? = nil) async throws
    -> FoundationModelsExtras.SessionMessage
  {
    let receipts = try await directory.send(
      OutgoingSessionMessage(
        from: sender, to: .session(target), text: Self.text, sourceSession: sourceSession))
    let id = try #require(receipts.first?.messageID)
    return try #require(try await directory.message(id, to: target))
  }

  /// The target takes the mail of `message`, as its translator does at `mailDelivered`.
  ///
  /// - Parameter message: The delivered message.
  /// - Returns: The updates for the transcript of the target.
  private func take(_ message: FoundationModelsExtras.SessionMessage) async -> [SessionUpdate] {
    await projector.learnDirectoryMessage(of: message.id, takenBy: targetId)
    return projector.delivered(message.id, to: targetId)
  }

  /// The target reads its inbox, as the `inbox` operation of the `sessions` tool does. The
  /// directory marks the message read, and the mail of the message leaves the queue of the
  /// target, as its translator sees at `cancelled`.
  ///
  /// - Parameter message: The delivered message.
  /// - Returns: The updates for the transcript of the target.
  private func read(_ message: FoundationModelsExtras.SessionMessage) async throws
    -> [SessionUpdate]
  {
    _ = try await directory.inbox(of: target, markRead: true)
    return await projector.withdrawn(message.id, from: targetId)
  }

  /// The `SAH.SessionMessage` in the `_meta` of a view.
  ///
  /// - Parameter message: The view.
  /// - Returns: The object. The test fails when there is no view or no object.
  private static func meta(of message: FoundationModelsACP.SessionMessage?) throws
    -> SAH.SessionMessage
  {
    let view = try #require(message)
    return try #require(SAH.SessionMessage.extract(from: patchValue(view.meta)))
  }

  @Test("a user message with a source session gives one view with the user sender")
  func aUserMessageGivesOneViewWithTheUserSender() async throws {
    let message = try await send(from: .user(clientID: Self.clientID), sourceSession: source)

    let updates = await take(message)

    let sender = try Self.meta(of: updates.first?.sessionMessagePayload).sender
    #expect(updates.count == 1)
    #expect(sender.kind == .user)
    #expect(sender.sessionId == sourceId)
    #expect(sender.title == Self.sourceTitle)
    #expect(sender.cwd == Self.sourceFolder.path)
  }

  @Test("a user message names the source session as the sender of the view")
  func aUserMessageNamesTheSourceSession() async throws {
    let message = try await send(from: .user(clientID: Self.clientID), sourceSession: source)

    let view = try #require(await take(message).first?.sessionMessagePayload)

    #expect(view.senderSessionId == .value(sourceId))
    #expect(view.recipientSessionId == .value(targetId))
    #expect(view.firstText == Self.text)
  }

  @Test("a session message gives the title, the agent and the folder of the sender")
  func aSessionMessageGivesTheSenderSession() async throws {
    let message = try await send(from: .session(source))

    let sender = try Self.meta(of: await take(message).first?.sessionMessagePayload).sender

    #expect(sender.kind == .session)
    #expect(sender.title == Self.sourceTitle)
    #expect(sender.agent == Self.sourceAgentName)
    #expect(sender.cwd == Self.sourceFolder.path)
  }

  @Test("the delivered event alone sends no view before the target takes the mail")
  func theEventAloneSendsNoView() async throws {
    let message = try await send(from: .session(source))

    await projector.directoryEventArrived(.messageDelivered(message))

    #expect(targetInbox.updates.isEmpty)
  }

  @Test("the delivered event gives the view when the target takes the mail")
  func theEventGivesTheViewAtTheTake() async throws {
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))

    let updates = projector.delivered(message.id, to: targetId)

    #expect(updates.compactMap(\.sessionMessagePayload).count == 1)
  }

  @Test("a directory event that is not messageDelivered gives no view")
  func anotherEventGivesNoView() async throws {
    let message = try await send(from: .session(source))
    let summary = Self.summary(
      of: target, title: nil, agentID: Self.sourceAgentID, agentName: nil,
      folder: Self.targetFolder)
    for event: SessionDirectoryEvent in [
      .started(summary, requestedByClient: nil), .factsChanged(summary),
      .stateChanged(id: target, state: .working, lastSummary: nil), .archived(id: target),
    ] {
      await projector.directoryEventArrived(event)
    }

    let updates = projector.delivered(message.id, to: targetId)

    #expect(updates.isEmpty)
  }

  @Test("a second take of the same mail sends no second view")
  func aSecondTakeSendsNoSecondView() async throws {
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))

    let first = await take(message)
    let second = await take(message)

    #expect(first.count + second.count == 1)
  }

  @Test("an inbox read gives one view with the sender of the message")
  func anInboxReadGivesOneView() async throws {
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))

    let updates = try await read(message)

    let sender = try Self.meta(of: updates.first?.sessionMessagePayload).sender
    #expect(updates.count == 1)
    #expect(sender.kind == .session)
    #expect(sender.sessionId == sourceId)
  }

  @Test("an inbox read before the delivered event gives the view")
  func anInboxReadBeforeTheEventGivesTheView() async throws {
    let message = try await send(from: .session(source))

    let updates = try await read(message)

    #expect(updates.compactMap(\.sessionMessagePayload).count == 1)
  }

  @Test("a second inbox read sends no second view")
  func aSecondInboxReadSendsNoSecondView() async throws {
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))

    let first = try await read(message)
    let second = try await read(message)

    #expect(first.count + second.count == 1)
  }

  @Test("a take after the inbox read sends no second view")
  func aTakeAfterTheInboxReadSendsNoSecondView() async throws {
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))
    _ = try await read(message)

    let updates = await take(message)

    #expect(updates.isEmpty)
  }

  @Test("a withdrawn mail that the target did not read gives no view")
  func aWithdrawnUnreadMailGivesNoView() async throws {
    let message = try await send(from: .session(source))

    let updates = await projector.withdrawn(message.id, from: targetId)

    #expect(updates.isEmpty)
  }

  @Test("an expected host mail keeps the views of the host mail route")
  func anExpectedHostMailKeepsItsViews() async throws {
    projector.attach(sourceId) { _ in }
    projector.expectHostMail(
      ExpectedHostMail(sender: sourceId, recipient: targetId, text: Self.text))
    let message = try await send(from: .session(source))
    await projector.directoryEventArrived(.messageDelivered(message))
    let early = await take(message)

    projector.mailed(message.id, from: sourceId, to: targetId, text: Self.text)

    let incoming = targetInbox.messages.filter { $0.messageId.rawValue.hasPrefix("in-") }
    #expect(early.isEmpty)
    #expect(incoming.count == 1)
    #expect(incoming.first?.senderMessageId != .unchanged)
  }

  @Test("a message of the agents tool keeps its one incoming view")
  func aMessageOfTheAgentsToolKeepsItsView() async throws {
    let mail = MailID()
    let record = SentMessageRecord(
      mailId: mail.value.description, receiver: .run(id: target.description),
      receiverSessionId: target.description)
    projector.attach(sourceId) { _ in }
    _ = projector.sent(record, from: sourceId, text: Self.text)

    await projector.learnDirectoryMessage(of: mail, takenBy: targetId)
    let updates = projector.delivered(mail, to: targetId)

    let views = updates.compactMap(\.sessionMessagePayload)
    #expect(views.count == 1)
    #expect(views.first?.meta == .unchanged)
  }
}
