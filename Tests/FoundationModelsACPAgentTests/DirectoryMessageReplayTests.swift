import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The replay of a `session/resume` gives the `session_message` views of the messages that a
/// session got, as the live session gave them (ACPA-6, D199 (f)). Each test of a directory
/// message opens a target session and a source session on one scripted agent, sends a message
/// through the directory of the agent, and waits for the reply of the target. Then it resumes the
/// target: in the same agent (a live resume), or in a second agent that reads the history file (a
/// cold resume). The suite trait closes each harness of a test whose body throws.
@Suite(.closesHarnesses) struct DirectoryMessageReplayTests {
  /// The directory label of the suite.
  private static let label = "DirectoryMessageReplayTests"

  /// The text of the message. The script of the target answers a prompt that holds it.
  private static let messageText = "ACPA6-REPLAY-MESSAGE please read the plan."

  /// The reply of the target to the message.
  private static let replyText = "ACPA6-REPLAY-REPLY"

  /// The title of the source session.
  private static let sourceTitle = "Plan the replay"

  /// The client id of the UI that sends a user message.
  private static let clientID = "testudo-ui"

  /// The longest time in seconds that the read of the wire of a resume waits.
  private static let traceWaitSeconds = 30

  /// A target session that got one directory message and replied to it.
  private struct Delivered {
    /// The fixture. Its session is the target.
    let fixture: ScriptedPromptFixture

    /// The source session.
    let source: SessionId

    /// The live view of the message in the stream of the target.
    let liveView: FoundationModelsACP.SessionMessage

    /// The id of the target session.
    var target: SessionId { fixture.sessionId }

    /// Opens the target and the source, sends the message to the target through the directory,
    /// and waits for the reply of the target.
    ///
    /// - Parameters:
    ///   - name: The label of the test.
    ///   - sender: The sender of the message, or `nil` for a session message from the source.
    /// - Returns: The target after its reply.
    static func make(name: String, from sender: SessionMessageSender?) async throws -> Delivered {
      let script: [ScriptedPassStep] = [
        .onPrompt(containing: messageText, play: [.textDelta(replyText), .endPass]),
        .endPass,
      ]
      let fixture = try await ScriptedPromptFixture.make(
        script: script, label: "\(label)-\(name)")
      let source = try await fixture.harness.connection.newSession(
        AgentClientHarness.makeNewSessionRequest(
          cwd: makeResolvedDirectory(label: "\(label)-\(name)-source"))
      ).sessionId
      let directory = fixture.harness.agent.sessionDirectory
      let sourceULID = try source.ulid()
      _ = try await directory.setTitle(sourceTitle, of: sourceULID)
      _ = try await directory.send(
        OutgoingSessionMessage(
          from: sender ?? .session(sourceULID), to: .session(try fixture.sessionId.ulid()),
          text: messageText, sourceSession: sourceULID))
      let target = fixture.sessionId
      let updates = try await fixture.collector.wait(for: "the target replied") { updates in
        updates.contains { $0.sessionId == target && isReplyChunk($0.update) }
      }
      let view = try #require(
        messageViews(in: updates.filter { $0.sessionId == target }.map(\.update)).first)
      return Delivered(fixture: fixture, source: source, liveView: view)
    }

    /// Resumes the target in the same agent, with the replay from the start.
    ///
    /// - Returns: The updates that the client got after the resume request, in order.
    func resumeLive() async throws -> [SessionUpdate] {
      let countBefore = await fixture.collector.updates.count
      _ = try await fixture.harness.connection.resumeSession(
        ResumeSessionRequest(
          cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: target,
          replayFrom: .start(ReplayFromStart())))
      let updates = await fixture.collector.updates.dropFirst(countBefore)
      let target = self.target
      return updates.filter { $0.sessionId == target }.map(\.update)
    }

    /// Closes the agent, and resumes the target in a second agent, which reads the history file
    /// of the target.
    ///
    /// - Returns: The updates of the target that the second client got after the resume
    ///   request, in order.
    func resumeCold() async throws -> [SessionUpdate] {
      let target = self.target
      return try await fixture.closeAndResume(
        makeSecond: { cwd in
          try await ScriptedPromptFixture.make(
            script: [.endPass], label: "\(label)-second", workingDirectory: cwd)
        },
        read: { second, countBefore in
          await second.collector.updates.dropFirst(countBefore)
            .filter { $0.sessionId == target }.map(\.update)
        })
    }

    /// Waits until the turn that the message started ended: the target sent an `idle` after its
    /// reply. The work of the target ends after the last output of the turn, so the end work of
    /// the turn is done.
    func waitForTheEndOfTheTurn() async throws {
      let target = self.target
      _ = try await fixture.collector.wait(for: "the turn of the target ended") { updates in
        let own = updates.filter { $0.sessionId == target }.map(\.update)
        guard let reply = own.firstIndex(where: isReplyChunk) else { return false }
        return own[reply...].contains { update in
          if case .stateUpdate(.idle) = update { return true }
          return false
        }
      }
    }

    /// Reads the history file of the target. The first agent stays open: no `session/close`
    /// wrote the file.
    ///
    /// - Returns: The transcript updates of the file, as a replay gives them.
    func writtenHistory() async throws -> [SessionUpdate] {
      let entry = try #require(await fixture.harness.agent.sessions[target])
      let history = try #require(try SessionHistoryFile.read(from: entry.transcriptDirectory))
      return history.replayedTranscriptUpdates
    }

    /// Resumes the target in a second agent, which reads the history file of the target, while
    /// the first agent stays open. It is the resume after a hard stop of the first process: no
    /// `session/close` wrote the file.
    ///
    /// - Returns: The updates of the target that the second client got after the resume
    ///   request, in order.
    func resumeColdWithNoClose() async throws -> [SessionUpdate] {
      let target = self.target
      let second = try await ScriptedPromptFixture.make(
        script: [.endPass], label: "\(label)-no-close-second", workingDirectory: fixture.cwd)
      defer { await second.close() }
      let countBefore = await second.collector.updates.count
      _ = try await second.harness.connection.resumeSession(
        ResumeSessionRequest(
          cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: target,
          replayFrom: .start(ReplayFromStart())))
      return await second.collector.updates.dropFirst(countBefore)
        .filter { $0.sessionId == target }.map(\.update)
    }
  }

  /// Whether an update is a live chunk of the reply of the target.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for an `agent_message_chunk` with the text of the reply.
  private static func isReplyChunk(_ update: SessionUpdate) -> Bool {
    update.agentMessageText == replyText
  }

  /// Whether an update is the replayed reply of the target: a whole `agent_message`.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for an `agent_message` whose content holds the text of the reply.
  private static func isReplayedReply(_ update: SessionUpdate) -> Bool {
    isReplayedAgentMessage(update, holding: replyText)
  }

  /// Whether an update is a whole `agent_message` whose content holds `text`.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - text: The text to find.
  /// - Returns: `true` for an `agent_message` whose content holds `text`.
  private static func isReplayedAgentMessage(_ update: SessionUpdate, holding text: String) -> Bool
  {
    guard let message = agentMessageReplace(of: update),
      let blocks = patchValue(message.content)
    else {
      return false
    }
    return blocks.contains { block in
      if case .text(let content) = block { return content.text.contains(text) }
      return false
    }
  }

  /// The views of the message in the updates of the target.
  ///
  /// - Parameter updates: The updates of the target.
  /// - Returns: The `session_message` payloads that hold the text of the message.
  private static func messageViews(in updates: [SessionUpdate])
    -> [FoundationModelsACP.SessionMessage]
  {
    updates.compactMap(\.sessionMessagePayload).filter { $0.firstText == messageText }
  }

  /// The sender in the `_meta` of the one view of the message.
  ///
  /// - Parameter updates: The updates of the target.
  /// - Returns: The sender. The test fails when there is no view or no sender.
  private static func sender(in updates: [SessionUpdate]) throws -> SAH.SessionMessage.Sender {
    let view = try #require(messageViews(in: updates).first)
    return try #require(SAH.SessionMessage.extract(from: patchValue(view.meta))).sender
  }

  // MARK: - The messages of the directory

  @Test("a live resume after a user message replays the view with the user sender")
  func aLiveResumeReplaysTheUserSender() async throws {
    let delivered = try await Delivered.make(
      name: "live-user", from: .user(clientID: Self.clientID))
    defer { await delivered.fixture.close() }

    let replay = try await delivered.resumeLive()

    let sender = try Self.sender(in: replay)
    #expect(sender.kind == .user)
    #expect(sender.sessionId == delivered.source)
    #expect(sender.title == Self.sourceTitle)
  }

  @Test("a cold resume after a user message replays the view with the user sender")
  func aColdResumeReplaysTheUserSender() async throws {
    let delivered = try await Delivered.make(
      name: "cold-user", from: .user(clientID: Self.clientID))

    let replay = try await delivered.resumeCold()

    let sender = try Self.sender(in: replay)
    #expect(sender.kind == .user)
    #expect(sender.sessionId == delivered.source)
    #expect(sender.title == Self.sourceTitle)
  }

  @Test("a cold resume after a session message replays the view with the session sender")
  func aColdResumeReplaysTheSessionSender() async throws {
    let delivered = try await Delivered.make(name: "cold-session", from: nil)

    let replay = try await delivered.resumeCold()

    let sender = try Self.sender(in: replay)
    #expect(sender.kind == .session)
    #expect(sender.sessionId == delivered.source)
  }

  @Test("a cold resume replays the view one time, the same as the live view")
  func aColdResumeReplaysTheLiveView() async throws {
    let delivered = try await Delivered.make(name: "cold-same", from: nil)

    let replay = try await delivered.resumeCold()

    #expect(Self.messageViews(in: replay) == [delivered.liveView])
  }

  @Test("the replayed view comes before the reply of the turn that the message started")
  func theReplayedViewComesBeforeTheReply() async throws {
    let delivered = try await Delivered.make(
      name: "cold-order", from: .user(clientID: Self.clientID))

    let replay = try await delivered.resumeCold()

    let view = try #require(replay.firstIndex { $0.sessionMessagePayload?.firstText == Self.messageText })
    let reply = try #require(replay.firstIndex(where: Self.isReplayedReply))
    #expect(view < reply)
  }

  // MARK: - The write of the history at the end of a turn that a message started

  @Test("a turn that a directory message started writes the view to the history file")
  func aMessageTurnWritesTheViewToTheHistoryFile() async throws {
    let delivered = try await Delivered.make(name: "write-view", from: nil)
    defer { await delivered.fixture.close() }
    try await delivered.waitForTheEndOfTheTurn()

    let written = try await delivered.writtenHistory()

    #expect(Self.messageViews(in: written) == [delivered.liveView])
  }

  @Test("a turn that a directory message started writes the reply to the history file")
  func aMessageTurnWritesTheReplyToTheHistoryFile() async throws {
    let delivered = try await Delivered.make(name: "write-reply", from: nil)
    defer { await delivered.fixture.close() }
    try await delivered.waitForTheEndOfTheTurn()

    let written = try await delivered.writtenHistory()

    #expect(written.contains(where: Self.isReplayedReply))
  }

  @Test("a resume from disk with no close of the first agent replays the turn of the message")
  func aResumeWithNoCloseReplaysTheMessageTurn() async throws {
    let delivered = try await Delivered.make(name: "no-close", from: nil)
    defer { await delivered.fixture.close() }
    try await delivered.waitForTheEndOfTheTurn()

    let replay = try await delivered.resumeColdWithNoClose()

    #expect(Self.messageViews(in: replay) == [delivered.liveView])
    #expect(replay.contains(where: Self.isReplayedReply))
  }

  /// Finds the transcript directory of a session under a working directory. The table of the
  /// agent drops a child when the child ended, so the test finds the directory on disk.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - root: The working directory that holds the recordings.
  /// - Returns: The directory whose name is the id of the session, or `nil` when there is none.
  private static func transcriptDirectory(of sessionId: SessionId, under root: URL) -> URL? {
    let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let item = items?.nextObject() as? URL {
      if item.lastPathComponent == sessionId.rawValue {
        return item
      }
    }
    return nil
  }

  @Test("a turn that a mail of the agents tool started writes the history file of the child")
  func anAgentsMailTurnWritesTheHistoryFileOfTheChild() async throws {
    let started = try await SubagentMessageWireTests.startMessengerChild()
    defer { await started.fixture.close() }
    let directory = try #require(
      Self.transcriptDirectory(of: started.child, under: started.fixture.cwd))

    let history = try #require(try SessionHistoryFile.read(from: directory))

    #expect(
      history.replayedTranscriptUpdates.contains {
        Self.isReplayedAgentMessage($0, holding: SubagentMessageWireTests.finalText)
      })
  }

  // MARK: - The messages of the agents tool

  /// Resumes the root of a recorded run in a second agent, and reads the `session_message`
  /// views of the root that the replay gives before the response. The child of the run ended, so
  /// the replay of the root does not hold the stream of the child.
  ///
  /// - Parameters:
  ///   - run: The recorded run. Its fixture is closed.
  ///   - text: The text of the views to read.
  /// - Returns: The views of the root that hold `text`, in wire order.
  private static func replayedRootViews(
    of run: SubagentMessageWireTests.Run, holding text: String
  ) async throws -> [FoundationModelsACP.SessionMessage] {
    let second = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-agents-second", workingDirectory: run.cwd)
    defer { await second.close() }
    let connection = second.harness.connection
    let trace = try await second.subscribeToTheResumeWire().readResumeTrace(
      timeout: .seconds(traceWaitSeconds)
    ) {
      _ = try await connection.resumeSession(
        ResumeSessionRequest(
          cwd: AbsolutePath(rawValue: run.cwd.path), sessionId: run.root,
          replayFrom: .start(ReplayFromStart())))
    }
    return trace.compactMap { event -> FoundationModelsACP.SessionMessage? in
      guard case .update(let stream, let update) = event, stream == run.root else { return nil }
      return update.sessionMessagePayload
    }.filter { $0.firstText == text }
  }

  @Test("a resume replays the outgoing view of send agent one time")
  func aResumeReplaysTheOutgoingViewOneTime() async throws {
    let run = try await SubagentMessageWireTests.runSendAgent()

    let views = try await Self.replayedRootViews(
      of: run, holding: SubagentMessageWireTests.rootMessage)

    #expect(views.count == 1)
  }

  @Test("a resume replays the incoming view of send caller one time")
  func aResumeReplaysTheIncomingViewOneTime() async throws {
    let run = try await SubagentMessageWireTests.runMessengerChild()

    let views = try await Self.replayedRootViews(of: run, holding: SubagentMessageWireTests.message)

    #expect(views.count == 1)
  }
}
