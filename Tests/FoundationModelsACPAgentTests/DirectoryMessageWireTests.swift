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
/// of a ``Pair`` whose make throws after its fixture opened. Each wait for an update ends after
/// ``waitBound``, so a test whose update does not come fails and does not wait forever.
@Suite(.closesHarnesses, .timeLimit(.minutes(1))) struct DirectoryMessageWireTests {
  /// The longest time that a wait for an update of the target takes.
  private static let waitBound = Duration.seconds(20)

  /// The time between two reads of the inbox of the target, while a test waits for a message.
  private static let inboxPollInterval = Duration.milliseconds(10)

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

    /// Starts a turn of the target that waits at the gate of the pair, and waits until the target
    /// works. A message to the target then waits in its queue.
    ///
    /// - Returns: The task of the prompt of the turn. The caller cancels it.
    func startBusyTurn() async throws -> Task<PromptResponse, any Error> {
      let target = self.target
      let connection = fixture.harness.connection
      let busy = Task {
        try await connection.prompt(
          AgentClientHarness.makePromptRequest(sessionId: target, text: busyMarker))
      }
      do {
        _ = try await waitForTarget("the target works") { isRunningState($0) }
      } catch {
        busy.cancel()
        throw error
      }
      return busy
    }

    /// Waits, for at most ``DirectoryMessageWireTests/waitBound``, until the inbox of the target
    /// holds a message that is not read. A message from a session to a durable target goes
    /// through an inbox file, and the directory scans the file in a task of its own. Only after
    /// the scan is the message in the inbox, with its mail in the queue of the target.
    ///
    /// - Throws: `CancellationError` when the bound comes first, or the error of a read.
    func waitUntilInInbox() async throws {
      let directory = self.directory
      let target = try target.ulid()
      try await bounded(by: waitBound) {
        while try await directory.inbox(of: target, markRead: false).isEmpty {
          try await Task.sleep(for: inboxPollInterval)
        }
      }
    }

    /// The target reads its inbox, as the `inbox` operation of the `sessions` tool does. The read
    /// starts no turn.
    func readInbox() async throws {
      _ = try await directory.inbox(of: try target.ulid(), markRead: true)
    }

    /// The updates of the target, after the view of the message went out.
    ///
    /// - Returns: The updates of the target, in order.
    func targetUpdatesAfterTheView() async throws -> [SessionUpdate] {
      try await waitForTarget("the target shows the message") {
        !messageViews(in: [$0]).isEmpty
      }
    }

    /// The updates of the target, after its reply to the message went out.
    ///
    /// - Returns: The updates of the target, in order.
    func targetUpdatesAfterTheReply() async throws -> [SessionUpdate] {
      try await targetUpdates(afterChunk: replyText)
    }

    /// The updates of the target, after a text chunk of the target went out.
    ///
    /// - Parameter text: The text of the chunk.
    /// - Returns: The updates of the target, in order.
    func targetUpdates(afterChunk text: String) async throws -> [SessionUpdate] {
      try await waitForTarget("the target sent \(text)") { chunkText(of: $0) == text }
    }

    /// Waits, for at most ``DirectoryMessageWireTests/waitBound``, until the target sent an
    /// update that `isMatch` accepts.
    ///
    /// - Parameters:
    ///   - condition: The name of the condition, for the error of a wait that does not end.
    ///   - isMatch: The test of one update of the target.
    /// - Returns: The updates of the target, in order, up to the first that matches.
    /// - Throws: ``ConditionWaitCancelled`` when the bound comes first.
    private func waitForTarget(
      _ condition: String, until isMatch: @escaping @Sendable (SessionUpdate) -> Bool
    ) async throws -> [SessionUpdate] {
      let target = self.target
      let collector = fixture.collector
      let notifications = try await bounded(by: waitBound) {
        try await collector.wait(for: condition) { updates in
          updates.contains { $0.sessionId == target && isMatch($0.update) }
        }
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

  /// The path of a gate in a new folder. The busy turn of the target waits until a file is at
  /// the path.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The path. No file is at it yet.
  private static func gatePath(name: String) -> String {
    makeResolvedDirectory(label: "\(label)-\(name)-gate").appendingPathComponent("gate").path
  }

  /// Opens a gate, so the busy turn that waits at it goes on.
  ///
  /// - Parameter gate: The path of the gate.
  private static func open(_ gate: String) throws {
    try "open".write(toFile: gate, atomically: true, encoding: .utf8)
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
    let gate = Self.gatePath(name: "queued")
    let pair = try await Pair.make(name: "queued", gatePath: gate)
    defer { await pair.fixture.close() }
    let busy = try await pair.startBusyTurn()
    // A wait that throws must not leave the busy prompt at the gate. The cancel comes before the
    // close of the fixture, because the defer blocks run in the reverse order.
    defer { busy.cancel() }
    try await pair.send(from: .session(try pair.source.ulid()))
    try Self.open(gate)

    let updates = try await pair.targetUpdatesAfterTheReply()
    _ = try await busy.value

    let busyReply = try Self.index(in: updates) { Self.chunkText(of: $0) == Self.busyReply }
    let view = try Self.index(in: updates) { $0.sessionMessagePayload?.firstText == Self.messageText }
    let reply = try Self.index(in: updates) { Self.chunkText(of: $0) == Self.replyText }
    #expect(busyReply < view)
    #expect(view < reply)
  }

  @Test("an inbox read of a queued message gives one view with the session sender")
  func anInboxReadGivesOneView() async throws {
    let gate = Self.gatePath(name: "inbox")
    let pair = try await Pair.make(name: "inbox", gatePath: gate)
    defer { await pair.fixture.close() }
    let busy = try await pair.startBusyTurn()
    defer { busy.cancel() }
    try await pair.send(from: .session(try pair.source.ulid()))
    try await pair.waitUntilInInbox()

    try await pair.readInbox()

    let updates = try await pair.targetUpdatesAfterTheView()
    #expect(Self.messageViews(in: updates).count == 1)
    #expect(try Self.sender(in: updates).kind == .session)
  }

  @Test("a second inbox read gives no second view")
  func aSecondInboxReadGivesNoSecondView() async throws {
    let gate = Self.gatePath(name: "second-read")
    let pair = try await Pair.make(name: "second-read", gatePath: gate)
    defer { await pair.fixture.close() }
    let busy = try await pair.startBusyTurn()
    defer { busy.cancel() }
    try await pair.send(from: .session(try pair.source.ulid()))
    try await pair.waitUntilInInbox()
    try await pair.readInbox()
    _ = try await pair.targetUpdatesAfterTheView()

    try await pair.readInbox()
    try Self.open(gate)
    _ = try await busy.value

    let updates = try await pair.targetUpdates(afterChunk: Self.busyReply)
    #expect(Self.messageViews(in: updates).count == 1)
  }

  @Test("a turn after the inbox read gives no second view")
  func aTurnAfterTheInboxReadGivesNoSecondView() async throws {
    let gate = Self.gatePath(name: "later-turn")
    let pair = try await Pair.make(name: "later-turn", gatePath: gate)
    defer { await pair.fixture.close() }
    let busy = try await pair.startBusyTurn()
    defer { busy.cancel() }
    try await pair.send(from: .session(try pair.source.ulid()))
    try await pair.waitUntilInInbox()
    try await pair.readInbox()
    _ = try await pair.targetUpdatesAfterTheView()
    try Self.open(gate)
    _ = try await busy.value

    _ = try await pair.fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: pair.target, text: Self.messageText))

    let updates = try await pair.targetUpdatesAfterTheReply()
    #expect(Self.messageViews(in: updates).count == 1)
  }
}
