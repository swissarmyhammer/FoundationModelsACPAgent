import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The wire view of a message that the session directory delivers to a hosted session (ACPA-6,
/// D199 (f)). Each test opens a target session and a source session on one scripted agent, sends
/// a message through the directory of the agent, and reads the updates that the client of the
/// target got. The suite trait closes each harness of a test whose body throws, also the harness
/// of a ``Pair`` whose make throws after its fixture opened.
@Suite(.closesHarnesses) struct DirectoryMessageWireTests {
  /// The directory label of the suite.
  private static let label = "DirectoryMessageWireTests"

  /// The text of the message. The script of the target answers a prompt that holds it.
  private static let messageText = "ACPA6-DIRECTORY-MESSAGE please read the plan."

  /// The reply of the target to the message.
  private static let replyText = "ACPA6-REPLY"

  /// The prompt of the first turn of the target in the test of a queued message.
  private static let busyMarker = "ACPA6-BUSY"

  /// The reply of the first turn of the target in the test of a queued message.
  private static let busyReply = "ACPA6-BUSY-DONE"

  /// The title of the source session.
  private static let sourceTitle = "Plan the release"

  /// The client id of the UI that sends a user message.
  private static let clientID = "testudo-ui"

  /// A target session and a source session on one scripted agent.
  private struct Pair {
    /// The fixture. Its session is the target.
    let fixture: ScriptedPromptFixture

    /// The source session.
    let source: SessionId

    /// The working folder of the source session.
    let sourceFolder: URL

    /// The id of the target session.
    var target: SessionId { fixture.sessionId }

    /// The directory of the agent.
    var directory: RouterSessionDirectory { fixture.harness.agent.sessionDirectory }

    /// Makes the pair. The source session gets ``DirectoryMessageWireTests/sourceTitle``.
    ///
    /// - Parameters:
    ///   - name: The label of the test.
    ///   - gatePath: The gate that the first turn of the target waits at.
    /// - Returns: The pair.
    static func make(name: String, gatePath: String) async throws -> Pair {
      let script: [ScriptedPassStep] = [
        .onPrompt(
          containing: busyMarker,
          play: [.gate(path: gatePath), .textDelta(busyReply), .endPass]),
        .onPrompt(containing: messageText, play: [.textDelta(replyText), .endPass]),
        .endPass,
      ]
      let fixture = try await ScriptedPromptFixture.make(
        script: script, label: "\(label)-\(name)")
      let sourceFolder = makeResolvedDirectory(label: "\(label)-\(name)-source")
      let source = try await fixture.harness.connection.newSession(
        AgentClientHarness.makeNewSessionRequest(cwd: sourceFolder)
      ).sessionId
      let pair = Pair(fixture: fixture, source: source, sourceFolder: sourceFolder)
      _ = try await pair.directory.setTitle(sourceTitle, of: try source.ulid())
      return pair
    }

    /// Sends the message to the target through the directory.
    ///
    /// - Parameters:
    ///   - sender: The sender of the message.
    ///   - sourceSession: The session in which the user wrote the message, or `nil`.
    func send(from sender: SessionMessageSender, sourceSession: ULID? = nil) async throws {
      _ = try await directory.send(
        OutgoingSessionMessage(
          from: sender, to: .session(try target.ulid()), text: messageText,
          sourceSession: sourceSession))
    }

    /// The updates of the target, after its reply to the message went out.
    ///
    /// - Returns: The updates of the target, in order.
    func targetUpdatesAfterTheReply() async throws -> [SessionUpdate] {
      let target = self.target
      let notifications = try await fixture.collector.wait(for: "the target replied") {
        updates in
        updates.contains { $0.sessionId == target && chunkText(of: $0.update) == replyText }
      }
      return notifications.filter { $0.sessionId == target }.map(\.update)
    }
  }

  /// The text of an agent-message chunk.
  ///
  /// - Parameter update: The update.
  /// - Returns: The text, or `nil` for an update that is not a text chunk.
  private static func chunkText(of update: SessionUpdate) -> String? {
    guard case .text(let content) = agentMessageChunk(of: update)?.content else { return nil }
    return content.text
  }

  /// The index of the first update that `isMatch` accepts.
  ///
  /// - Parameters:
  ///   - updates: The updates.
  ///   - isMatch: The test of an update.
  /// - Returns: The index. The test fails when no update matches.
  private static func index(
    in updates: [SessionUpdate], where isMatch: (SessionUpdate) -> Bool
  ) throws -> Int {
    let found = updates.firstIndex(where: isMatch)
    return try #require(found)
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

  @Test("a user message to an idle session gives one view with the user sender")
  func aUserMessageGivesOneViewWithTheUserSender() async throws {
    let pair = try await Pair.make(name: "user", gatePath: "/nonexistent")
    defer { await pair.fixture.close() }
    try await pair.send(from: .user(clientID: Self.clientID), sourceSession: try pair.source.ulid())

    let updates = try await pair.targetUpdatesAfterTheReply()

    let sender = try Self.sender(in: updates)
    #expect(Self.messageViews(in: updates).count == 1)
    #expect(sender.kind == .user)
    #expect(sender.sessionId == pair.source)
    #expect(sender.title == Self.sourceTitle)
    #expect(sender.cwd == pair.sourceFolder.path)
  }

  @Test("the view of a user message comes before the reply of the turn")
  func theViewComesBeforeTheReply() async throws {
    let pair = try await Pair.make(name: "order", gatePath: "/nonexistent")
    defer { await pair.fixture.close() }
    try await pair.send(from: .user(clientID: Self.clientID), sourceSession: try pair.source.ulid())

    let updates = try await pair.targetUpdatesAfterTheReply()

    let view = try Self.index(in: updates) { $0.sessionMessagePayload?.firstText == Self.messageText }
    let reply = try Self.index(in: updates) { Self.chunkText(of: $0) == Self.replyText }
    #expect(view < reply)
  }

  @Test("a session message gives the title, the agent and the folder of the sender")
  func aSessionMessageGivesTheSenderSession() async throws {
    let pair = try await Pair.make(name: "session", gatePath: "/nonexistent")
    defer { await pair.fixture.close() }
    try await pair.send(from: .session(try pair.source.ulid()))

    let updates = try await pair.targetUpdatesAfterTheReply()
    let summary = try #require(try await pair.directory.summary(of: try pair.source.ulid()))

    let sender = try Self.sender(in: updates)
    #expect(sender.kind == .session)
    #expect(sender.title == Self.sourceTitle)
    #expect(sender.agent == (summary.agentName ?? summary.agentID))
    #expect(sender.cwd == pair.sourceFolder.path)
  }

  @Test("a queued message shows when its turn starts, after the turn before it")
  func aQueuedMessageShowsWhenItsTurnStarts() async throws {
    let gate = makeResolvedDirectory(label: "\(Self.label)-queued-gate")
      .appendingPathComponent("gate").path
    let pair = try await Pair.make(name: "queued", gatePath: gate)
    defer { await pair.fixture.close() }
    let busy = Task {
      try await pair.fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: pair.target, text: Self.busyMarker))
    }
    // A wait that throws must not leave the busy prompt at the gate. The cancel comes before the
    // close of the fixture, because the defer blocks run in the reverse order.
    defer { busy.cancel() }
    let target = pair.target
    _ = try await pair.fixture.collector.wait(for: "the target works") { updates in
      updates.contains { $0.sessionId == target && isRunningState($0.update) }
    }
    try await pair.send(from: .session(try pair.source.ulid()))
    try "open".write(toFile: gate, atomically: true, encoding: .utf8)

    let updates = try await pair.targetUpdatesAfterTheReply()
    _ = try await busy.value

    let busyReply = try Self.index(in: updates) { Self.chunkText(of: $0) == Self.busyReply }
    let view = try Self.index(in: updates) { $0.sessionMessagePayload?.firstText == Self.messageText }
    let reply = try Self.index(in: updates) { Self.chunkText(of: $0) == Self.replyText }
    #expect(busyReply < view)
    #expect(view < reply)
  }
}
