import ACPMarkdown
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The share of a session as a link (D208 (g), (k)): the server snapshot of a session, the sharer
/// that the host gives through ``SessionShareHost``, and the turn-end events for Keep Updated.
///
/// Each test runs a scripted agent in the test process. A fake store of the host records each
/// share call, so no test uses a cloud service. The suite trait closes each harness of a test
/// whose body throws.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SessionShareTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "SessionShareTests"

  /// The corrective of a session that has no history in this server.
  private static let noHistoryCorrective =
    "This server has no history of the session. Use Export as Markdown… in the app."

  /// The text of the prompt that makes the scripted model call the `sessions` tool.
  private static let shareMarker = "SHARE-BY-TOOL"

  /// The name of the `sessions` tool.
  private static let sessionsName = "sessions"

  /// The link that the fake store gives each share.
  private static let shareURL = URL(string: "https://share.example/session-share")!

  /// The time of each share of the fake store.
  private static let shareDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// The longest time that a test waits for the turn-end events.
  private static let readTimeout = Duration.seconds(60)

  /// The text of the thought in the sample history. The default options of a share keep it.
  private static let thoughtText = "SHARE-THOUGHT the user wants a link."

  /// The sample history: a user message, a thought and an agent message, one `session/update`
  /// payload for each line.
  private static let sampleLines = [
    #"{"content": [{"text": "Share the build.", "type": "text"}], "messageId": "u1", "sessionUpdate": "user_message"}"#,
    #"{"content": {"text": "\#(thoughtText)", "type": "text"}, "messageId": "th1", "sessionUpdate": "agent_thought_chunk"}"#,
    #"{"content": {"text": "I share the build.", "type": "text"}, "messageId": "a1", "sessionUpdate": "agent_message_chunk"}"#,
  ]

  /// The text of a directory message from another session.
  private static let messageText = "SHARE-MESSAGE please read the plan."

  /// The reply of the target to the directory message.
  private static let replyText = "SHARE-REPLY"

  // MARK: - The fake store of the host

  /// The store of a host for the tests: it keeps each share in memory and records each call.
  private actor FakeShareStore {
    /// The share of each session.
    private var shares: [ULID: SessionShare] = [:]

    /// The snapshot of each call of `share`, in order.
    private(set) var sharedSnapshots: [SessionSnapshot] = []

    /// The options of each call of `update`, in order.
    private(set) var updatedOptions: [SessionShareOptions] = []

    /// The session of each call of `stop`, in order.
    private(set) var stoppedSessions: [ULID] = []

    /// Puts a share of a session into the store, as an earlier share call does.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - options: The options of the share.
    func seed(_ session: ULID, options: SessionShareOptions) {
      shares[session] = SessionShareTests.share(with: options)
    }

    /// Records a new share.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - snapshot: The snapshot of the session.
    ///   - options: The options of the share.
    /// - Returns: The share.
    func share(_ session: ULID, snapshot: SessionSnapshot, options: SessionShareOptions)
      -> SessionShare
    {
      sharedSnapshots.append(snapshot)
      return keep(session, options: options)
    }

    /// Records an update of a share.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - snapshot: The snapshot of the session.
    ///   - options: The options of the share.
    /// - Returns: The share.
    func update(_ session: ULID, snapshot: SessionSnapshot, options: SessionShareOptions)
      -> SessionShare
    {
      updatedOptions.append(options)
      return keep(session, options: options)
    }

    /// Records a stop of a share.
    ///
    /// - Parameter session: The session.
    func stop(_ session: ULID) {
      stoppedSessions.append(session)
      shares[session] = nil
    }

    /// The share of a session.
    ///
    /// - Parameter session: The session.
    /// - Returns: The share, or `nil`.
    func current(_ session: ULID) -> SessionShare? {
      shares[session]
    }

    /// Keeps the share of a session.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - options: The options of the share.
    /// - Returns: The share.
    private func keep(_ session: ULID, options: SessionShareOptions) -> SessionShare {
      let share = SessionShareTests.share(with: options)
      shares[session] = share
      return share
    }

    /// The share calls of the host over this store.
    nonisolated var host: SessionShareHost {
      SessionShareHost(
        share: { await self.share($0, snapshot: $1, options: $2) },
        update: { await self.update($0, snapshot: $1, options: $2) },
        stop: { await self.stop($0) },
        currentShare: { await self.current($0) })
    }
  }

  // MARK: - Helpers

  /// A share of the fake store.
  ///
  /// - Parameter options: The options of the share.
  /// - Returns: The share.
  private static func share(with options: SessionShareOptions) -> SessionShare {
    SessionShare(
      url: shareURL, anyoneWithLink: options.anyoneWithLink, options: options,
      updatedAt: shareDate)
  }

  /// Puts the sample history into the retained history of a session, as the sink of the session
  /// records each update that it sends.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - agent: The agent of the session.
  private static func seed(_ sessionId: SessionId, on agent: RoutedACPAgent) async throws {
    for line in sampleLines {
      let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(line.utf8))
      await agent.recordInHistory(update, of: sessionId)
    }
  }

  /// Whether an update makes a transcript entry, and is not a state update.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for an update of the transcript.
  private static func isTranscriptUpdate(_ update: SessionUpdate) -> Bool {
    !SessionMergeEngine(replaying: [update]).transcriptUpdates.isEmpty
  }

  /// Opens a scripted agent whose model calls the `sessions` tool with `arguments` on the
  /// share marker, over the fake store `store`.
  ///
  /// - Parameters:
  ///   - name: The label of the test.
  ///   - arguments: The JSON arguments of the call.
  ///   - store: The fake store of the host, or `nil` for an agent with no sharer.
  /// - Returns: The fixture.
  private static func toolFixture(
    name: String, arguments: String, store: FakeShareStore?
  ) async throws -> ScriptedPromptFixture {
    try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: shareMarker,
          play: [.toolCall(name: sessionsName, argumentsJSON: arguments), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)",
      sessionShareHost: store?.host)
  }

  /// Runs the share marker prompt, and gives the output of the tool calls of the session.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The output text.
  private static func runShareCall(on fixture: ScriptedPromptFixture) async throws -> String {
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: shareMarker)
    return try ToolOutputText.of(run.updates, in: fixture.sessionId)
  }

  /// Reads the first turn-end events of an agent while `request` runs.
  ///
  /// - Parameters:
  ///   - count: The number of events to read.
  ///   - agent: The agent.
  ///   - request: The steps that end the turns.
  /// - Returns: The sessions of the events that came before ``readTimeout``, at most `count`.
  /// - Throws: The error of `request`.
  private static func firstTurnEnds(
    _ count: Int, of agent: RoutedACPAgent, whileRunning request: () async throws -> Void
  ) async throws -> [SessionId] {
    let stream = agent.turnEnds()
    return try await TimedRead.value(
      of: { await stream.prefix(count).reduce(into: []) { $0.append($1) } },
      timeout: readTimeout, whileRunning: request)
  }

  // MARK: - The server snapshot

  @Test("the snapshot of a recorded session is the build of the updates that a replay sends")
  func theSnapshotIsTheBuildOfTheReplay() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-snapshot")
    defer { await fixture.close() }
    let agent = fixture.harness.agent
    try await Self.seed(fixture.sessionId, on: agent)
    let id = try fixture.sessionId.ulid()
    let summary = try #require(try await agent.sessionDirectory.summary(of: id))
    let snapshot = try await agent.snapshot(of: id, options: SessionSnapshot.Options())
    let countBefore = await fixture.collector.updates.count

    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId,
        replayFrom: .start(ReplayFromStart())))
    let replay = await fixture.collector.updates.dropFirst(countBefore)
      .filter { $0.sessionId == fixture.sessionId }.map(\.update)
      .filter(Self.isTranscriptUpdate)

    #expect(
      snapshot
        == SessionSnapshot.build(
          updates: replay,
          options: SessionSnapshot.Options(title: summary.title, agentName: summary.agentName)))
  }

  @Test("the snapshot of a session with no history gives the corrective of the export")
  func theSnapshotOfASessionWithNoHistoryGivesTheCorrective() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-no-history")
    await fixture.close()
    let second = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-no-history-second", workingDirectory: fixture.cwd)
    defer { await second.close() }

    await #expect {
      _ = try await second.harness.agent.snapshot(
        of: try fixture.sessionId.ulid(), options: SessionSnapshot.Options())
    } throws: { error in
      String(describing: error) == Self.noHistoryCorrective
    }
  }

  // MARK: - The sessions tool

  @Test("share session through the sessions tool gives the link of the host")
  func shareSessionGivesTheLinkOfTheHost() async throws {
    let fixture = try await Self.toolFixture(
      name: "share", arguments: #"{"op":"share session"}"#, store: FakeShareStore())
    defer { await fixture.close() }

    let output = try await Self.runShareCall(on: fixture)

    #expect(output.contains(Self.shareURL.absoluteString), "\(output)")
  }

  @Test("share session gives the host the server snapshot of the session")
  func shareSessionGivesTheHostTheSnapshot() async throws {
    let store = FakeShareStore()
    let fixture = try await Self.toolFixture(
      name: "share-snapshot", arguments: #"{"op":"share session"}"#, store: store)
    defer { await fixture.close() }
    try await Self.seed(fixture.sessionId, on: fixture.harness.agent)

    _ = try await Self.runShareCall(on: fixture)
    let shared = try #require(await store.sharedSnapshots.first)

    #expect(shared.markdown.contains(Self.thoughtText), "\(shared.markdown)")
  }

  @Test("update share gives the host the options of the share with the new Keep Updated")
  func updateShareGivesTheHostKeepUpdated() async throws {
    let store = FakeShareStore()
    let fixture = try await Self.toolFixture(
      name: "update", arguments: #"{"op":"update share","keepUpdated":true}"#, store: store)
    defer { await fixture.close() }
    await store.seed(try fixture.sessionId.ulid(), options: .defaults)

    _ = try await Self.runShareCall(on: fixture)

    var expected = SessionShareOptions.defaults
    expected.keepUpdated = true
    #expect(await store.updatedOptions == [expected])
  }

  @Test("stop sharing calls the stop of the host for the session")
  func stopSharingCallsTheHost() async throws {
    let store = FakeShareStore()
    let fixture = try await Self.toolFixture(
      name: "stop", arguments: #"{"op":"stop sharing"}"#, store: store)
    defer { await fixture.close() }
    let id = try fixture.sessionId.ulid()
    await store.seed(id, options: .defaults)

    _ = try await Self.runShareCall(on: fixture)

    #expect(await store.stoppedSessions == [id])
  }

  @Test("share session with no sharer gives the corrective of SHARING_UNAVAILABLE")
  func shareSessionWithNoSharerIsUnavailable() async throws {
    let fixture = try await Self.toolFixture(
      name: "no-sharer", arguments: #"{"op":"share session"}"#, store: nil)
    defer { await fixture.close() }

    let output = try await Self.runShareCall(on: fixture)

    #expect(output.contains("its host gives no session sharer"), "\(output)")
  }

  // MARK: - Keep Updated

  @Test("the host gets one turn-end event for each turn of a prompt")
  func theHostGetsOneTurnEndForEachPromptTurn() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-turn-ends")
    defer { await fixture.close() }
    let other = try await fixture.harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: fixture.cwd)
    ).sessionId

    let ends = try await Self.firstTurnEnds(2, of: fixture.harness.agent) {
      try await ScriptedPromptFixture.runPrompt(on: fixture, text: "first")
      try await ScriptedPromptFixture.runPrompt(
        AgentClientHarness.makePromptRequest(sessionId: other, text: "second"),
        through: fixture.harness, count: 2)
    }

    #expect(ends == [fixture.sessionId, other])
  }

  @Test("the host gets a turn-end event for a turn that a mail started")
  func theHostGetsATurnEndForAMailTurn() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(containing: Self.messageText, play: [.textDelta(Self.replyText), .endPass]),
        .endPass,
      ],
      label: "\(Self.label)-mail-turn")
    defer { await fixture.close() }
    let directory = fixture.harness.agent.sessionDirectory
    let source = try await fixture.harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(
        cwd: makeResolvedDirectory(label: "\(Self.label)-mail-source"))
    ).sessionId
    let target = fixture.sessionId

    let ends = try await Self.firstTurnEnds(1, of: fixture.harness.agent) {
      _ = try await directory.send(
        OutgoingSessionMessage(
          from: .session(try source.ulid()), to: .session(try target.ulid()),
          text: Self.messageText, sourceSession: try source.ulid()))
    }

    #expect(ends == [target])
  }
}
