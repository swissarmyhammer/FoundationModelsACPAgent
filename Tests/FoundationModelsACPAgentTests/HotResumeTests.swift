import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// A hot resume: a `session/resume` of a root that is live in this process. A second connection
/// takes the whole live tree (the root and its sub-agent sessions) and the work goes on. Nothing
/// is torn down: the open prompt stays open, the running child stays running, and a pending
/// question of the child is asked once, on the new owner.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct HotResumeTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "HotResumeTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The marker of the prompt of the root session.
  private static let rootMarker = "HOT-RESUME-ROOT"

  /// The marker of the prompt of the child.
  private static let childMarker = "HOT-RESUME-CHILD"

  /// The text that the child plays before it waits.
  private static let childText = "HOT-RESUME-CHILD-TEXT"

  /// The text that the child plays after the wait.
  private static let childTextAfter = "HOT-RESUME-CHILD-TEXT-AFTER"

  /// The message of the question of the child.
  private static let question = "Which colour do you want?"

  /// The seconds that a test waits for the sync after the response. A sync that does not come
  /// in this time ends the read, and the test fails on its own check.
  private static let syncWaitSeconds = 20

  /// The name of the one field of the question.
  private static let answerField = "answer"

  /// The answer that the user gives.
  private static let answer = "blue"

  /// The number of requests that one question makes at the client.
  private static let requestsOfOneQuestion = 1

  /// The text of the first live update that the child sends while the resume waits.
  private static let windowFirstText = "HOT-RESUME-WINDOW-FIRST"

  /// The text of the second live update that the child sends while the resume waits.
  private static let windowSecondText = "HOT-RESUME-WINDOW-SECOND"

  /// The text that marks the first frame of the replay: the announcement of the child.
  private static let announcementMarker = "subagent_update"

  /// The most polls of the wait until the agent recorded a live update of the window.
  private static let recordPollLimit = 1000

  /// The time between two polls of the wait until the agent recorded a live update.
  private static let recordPollInterval = Duration.milliseconds(10)

  /// The number of times that each live update of the window reaches the new connection.
  private static let deliveriesOfOneUpdate = 1

  /// The text of an update of the root that the agent records before the take, and sends after
  /// it.
  private static let recordedBeforeTheTakeText = "HOT-RESUME-RECORDED-BEFORE-THE-TAKE"

  /// The number of sends that wait in the gate of the test before the take.
  private static let sendsBeforeTheTake = 1

  /// The title of the permission request of the child.
  private static let permissionTitle = "Run the build?"

  /// The number of requests that reach the new connection while the first frame of the replay
  /// waits, when the agent obeys the rules.
  private static let requestsWhileTheReplayWaits = 0

  /// The live tree of one test: a root with an open prompt and a running child.
  private struct LiveTree {
    /// The first agent and its first connection.
    let fixture: ScriptedPromptFixture

    /// The task of the open prompt of the root.
    let prompt: Task<PromptResponse, any Error>

    /// The hold that keeps the child running. Release it to let the child end.
    let hold: ScriptedHold

    /// The id of the child session.
    let childId: SessionId

    /// The id of the root session.
    var rootId: SessionId { fixture.sessionId }

    /// The resume request of the root, with a replay from the start.
    var replayRequest: ResumeSessionRequest {
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: rootId,
        replayFrom: .start(ReplayFromStart()))
    }
  }

  /// A live tree whose child sends two live updates when the test releases a second hold: the
  /// window between the take of a resume and the end of its replay.
  private struct WindowTree {
    /// The live tree. Its hold keeps the child running after the two updates.
    let tree: LiveTree

    /// The hold that keeps back the two live updates of the child.
    let window: ScriptedHold
  }

  /// The kind of a question that a child asks.
  enum QuestionKind: CaseIterable, Sendable {
    /// An `elicitation/create`.
    case elicitation

    /// A `session/request_permission`.
    case permission

    /// The step of the child script that asks the question.
    var step: ScriptedPassStep {
      switch self {
      case .elicitation:
        .elicit(message: HotResumeTests.question)
      case .permission:
        .permission(title: HotResumeTests.permissionTitle)
      }
    }
  }

  /// The wire of a hot resume whose child asks a question in the window between the take and the
  /// replay.
  private struct QuestionWindowWire {
    /// The trace of the resume, with the wire sequence number of each event. It holds the agent
    /// requests that came up to the end of the read.
    let trace: [SequencedTraceEvent]

    /// The number of agent requests that reached the new connection while the first frame of the
    /// replay waited.
    let requestsWhileTheReplayWaits: Int

    /// The second connection.
    let second: AgentClientHarness

    /// The model of the resumed root on the second connection.
    let root: SessionModel
  }

  // MARK: - Fixtures

  /// Makes the fixture of a root whose prompt starts the child, with the given steps of the
  /// child.
  ///
  /// - Parameter childSteps: The steps that the child plays.
  /// - Returns: The fixture.
  /// - Throws: Whatever the fixture throws.
  private static func makeTreeFixture(
    childSteps: [ScriptedPassStep]
  ) async throws -> ScriptedPromptFixture {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: childMarker, play: childSteps),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    return try await ScriptedPromptFixture.make(script: script, label: label, workingDirectory: cwd)
  }

  /// Starts a root with an open prompt and a child that runs and waits on a hold.
  ///
  /// - Returns: The live tree.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startLiveTree() async throws -> LiveTree {
    let hold = ScriptedHold()
    let fixture = try await makeTreeFixture(
      childSteps: [.textDelta(childText), .holdUntilReleased(hold), .endPass])
    return try await openPrompt(of: fixture, hold: hold)
  }

  /// Starts a root with an open prompt and a child that waits on the window hold, then sends two
  /// live updates, and then waits on the hold of the tree.
  ///
  /// - Returns: The tree and its window hold.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startWindowTree() async throws -> WindowTree {
    let window = ScriptedHold()
    let hold = ScriptedHold()
    let fixture = try await makeTreeFixture(childSteps: [
      .textDelta(childText), .holdUntilReleased(window), .textDelta(windowFirstText),
      .textDelta(windowSecondText), .holdUntilReleased(hold), .endPass,
    ])
    return WindowTree(tree: try await openPrompt(of: fixture, hold: hold), window: window)
  }

  /// Starts a root with an open prompt and a child that waits on the window hold, then asks one
  /// question, and then plays its next text.
  ///
  /// - Parameter kind: The kind of the question.
  /// - Returns: The tree and its window hold.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startQuestionWindowTree(asking kind: QuestionKind) async throws -> WindowTree
  {
    let window = ScriptedHold()
    let fixture = try await makeTreeFixture(childSteps: [
      .textDelta(childText), .holdUntilReleased(window), kind.step, .textDelta(childTextAfter),
      .endPass,
    ])
    return WindowTree(tree: try await openPrompt(of: fixture, hold: ScriptedHold()), window: window)
  }

  /// Starts a root with an open prompt and a child that asks one question.
  ///
  /// - Returns: The live tree. Its hold is not used.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startAskingTree() async throws -> LiveTree {
    let fixture = try await makeTreeFixture(
      childSteps: [.elicit(message: question), .textDelta(childTextAfter), .endPass])
    let tree = try await openPrompt(of: fixture, hold: ScriptedHold())
    let recorder = try #require(fixture.harness.elicitations)
    _ = try await recorder.waitForCreates(count: requestsOfOneQuestion)
    return tree
  }

  /// Sends the prompt of the root and waits until the client holds an update of the child.
  ///
  /// - Parameters:
  ///   - fixture: The first agent and its connection.
  ///   - hold: The hold of the child script.
  /// - Returns: The live tree.
  /// - Throws: Whatever the wait throws.
  private static func openPrompt(
    of fixture: ScriptedPromptFixture, hold: ScriptedHold
  ) async throws -> LiveTree {
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootMarker))
    }
    let updates = try await fixture.collector.wait(for: "an update of the child") { updates in
      updates.contains { $0.sessionId != root }
    }
    let child = try #require(updates.first { $0.sessionId != root }?.sessionId)
    return LiveTree(fixture: fixture, prompt: prompt, hold: hold, childId: child)
  }

  /// Opens a second connection to the agent of the tree, and completes its `initialize`.
  ///
  /// - Parameters:
  ///   - tree: The live tree.
  ///   - wire: The wire of the second connection.
  /// - Returns: The harness of the second connection.
  /// - Throws: Whatever the handshake throws.
  private static func openSecondConnection(
    to tree: LiveTree, over wire: HarnessWire = .makeInMemory()
  ) async throws -> AgentClientHarness {
    let second = await AgentClientHarness.makeRecording(
      agent: tree.fixture.harness.agent, wire: wire)
    _ = try await second.client.initialize(
      AgentClientHarness.makeInitializeRequest(capabilities: ACPClient.advertisedCapabilities))
    return second
  }

  /// Resumes the root on a second connection and reads its wire up to the snapshot of the child
  /// that follows the response.
  ///
  /// - Parameters:
  ///   - tree: The live tree.
  ///   - second: The second connection.
  /// - Returns: The trace, in wire order.
  /// - Throws: Whatever the request throws.
  private static func resumeTrace(
    of tree: LiveTree, on second: AgentClientHarness
  ) async throws -> [WireTraceEvent] {
    let subscription = second.connection.subscribeToAllSessions()
    let child = tree.childId
    let first = WireTraceEvent.resumeRequest(id: .number(1), sessionId: tree.rootId)
    let reader = Task {
      await subscription.readResumeTrace(startingWith: [first]) { event in
        if case .update(let stream, let update) = event {
          return stream == child && update.isStateUpdate
        }
        return false
      }
    }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(syncWaitSeconds))
      reader.cancel()
    }
    _ = try await second.connection.resumeSession(tree.replayRequest)
    let trace = await reader.value
    timeout.cancel()
    return trace
  }

  /// Resumes the root on a second connection, and lets the child send its two live updates after
  /// the take and before the replay is out. The first frame of the replay waits in the transport
  /// of the second connection. While it waits, the test releases the window hold of the child, and
  /// waits until the agent recorded the second update. The projector of the child sends one update
  /// at a time, so the send of the first update is done then. Then the frame goes. No clock
  /// decides the order. The read of the wire ends at the `state_update` of the child after the
  /// response.
  ///
  /// - Parameter windowTree: The tree and its window hold.
  /// - Returns: The trace in wire order, and the harness of the second connection.
  /// - Throws: Whatever the request or a wait throws.
  private static func resumeTraceAcrossTheWindow(
    of windowTree: WindowTree
  ) async throws -> (trace: [WireTraceEvent], second: AgentClientHarness) {
    let tree = windowTree.tree
    let wire = HarnessWire.makeInMemory()
    let holder = FrameHoldingTransport(
      wrapping: wire.agentEnd, holdingFirstFrameContaining: announcementMarker)
    let second = try await openSecondConnection(to: tree, over: wire.replacingAgentEnd(with: holder))
    let child = tree.childId
    let agent = tree.fixture.harness.agent
    let trace = try await second.connection.subscribeToAllSessions().readResumeTrace(
      startingWith: [WireTraceEvent.resumeRequest(id: .number(1), sessionId: tree.rootId)],
      settledBy: { event in
        if case .update(let stream, let update) = event {
          return stream == child && update.isStateUpdate
        }
        return false
      },
      timeout: .seconds(syncWaitSeconds)
    ) {
      defer { holder.release() }
      let resume = Task { try await second.connection.resumeSession(tree.replayRequest) }
      defer { resume.cancel() }
      await holder.waitUntilHolding()
      windowTree.window.release()
      try await waitUntilRecorded(windowSecondText, of: child, in: agent)
      holder.release()
      _ = try await resume.value
    }
    return (trace, second)
  }

  /// Resumes the root on a second connection, and lets the child ask its question after the take
  /// and before the replay is out. The first frame of the replay waits in the transport of the
  /// second connection. While it waits, the test releases the window hold of the child, and waits
  /// until the question is settled: the new connection got the request, or the relay of the
  /// child keeps the question to ask it later. Then the frame goes. No clock decides the order.
  /// The read of the wire ends at the `state_update` of the child after the response, and the
  /// trace then gets the agent requests of the new connection, in wire order.
  ///
  /// - Parameter windowTree: The tree and its window hold.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the request or a wait throws.
  private static func resumeAcrossAQuestionWindow(
    of windowTree: WindowTree
  ) async throws -> QuestionWindowWire {
    let tree = windowTree.tree
    let wire = HarnessWire.makeInMemory()
    let holder = FrameHoldingTransport(
      wrapping: wire.agentEnd, holdingFirstFrameContaining: announcementMarker)
    let second = try await openSecondConnection(to: tree, over: wire.replacingAgentEnd(with: holder))
    let recorder = try #require(second.elicitations)
    let relay = try #require(await tree.fixture.harness.agent.sessions[tree.childId]?.projector.relay)
    let child = tree.childId
    var whileTheReplayWaits = 0
    var root: SessionModel?
    let read = try await second.connection.subscribeToAllSessions().readSequencedResumeTrace(
      startingWith: [WireTraceEvent.resumeRequest(id: .number(1), sessionId: tree.rootId)],
      settledBy: { event in
        if case .update(let stream, let update) = event {
          return stream == child && update.isStateUpdate
        }
        return false
      },
      timeout: .seconds(syncWaitSeconds)
    ) {
      defer { holder.release() }
      let resume = Task { try await second.client.resumeSession(tree.replayRequest) }
      defer { resume.cancel() }
      await holder.waitUntilHolding()
      windowTree.window.release()
      try await pollUntil(limit: recordPollLimit, interval: recordPollInterval) {
        let asked = await !recorder.agentRequests.isEmpty
        let kept = await relay.withdrawnQuestionCount > 0
        return asked || kept
      }
      whileTheReplayWaits = await recorder.agentRequests.count
      holder.release()
      root = try await resume.value
    }
    let requests = try await recorder.waitForAgentRequests(count: requestsOfOneQuestion)
    return QuestionWindowWire(
      trace: read + requests, requestsWhileTheReplayWaits: whileTheReplayWaits, second: second,
      root: try #require(root))
  }

  /// Waits until the retained history of a session holds a text.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - sessionId: The session.
  ///   - agent: The agent of the session.
  /// - Throws: An issue when the history does not hold the text at the end of the wait.
  private static func waitUntilRecorded(
    _ text: String, of sessionId: SessionId, in agent: RoutedACPAgent
  ) async throws {
    try await pollUntil(limit: recordPollLimit, interval: recordPollInterval) {
      await recordedText(of: sessionId, in: agent).contains(text)
    }
    try #require(await recordedText(of: sessionId, in: agent).contains(text))
  }

  /// The agent text in the retained history of a session.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - agent: The agent of the session.
  /// - Returns: The text of the agent messages, joined.
  private static func recordedText(of sessionId: SessionId, in agent: RoutedACPAgent) async
    -> String
  {
    let history = await agent.sessions[sessionId]?.history
    return ReplayedMessage.replayed(in: history?.replayUpdates(from: .start) ?? []).map(\.text)
      .joined()
  }

  /// The positions in a trace of the text chunks on the stream of a session that hold a text.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - session: The session.
  ///   - trace: The trace.
  /// - Returns: The positions, in wire order.
  private static func positions(
    of text: String, on session: SessionId, in trace: [WireTraceEvent]
  ) -> [Int] {
    trace.indices.filter { trace[$0].isAgentText(containing: text, on: session) }
  }

  /// Releases the child, and waits until the open prompt of the root ends.
  ///
  /// - Parameters:
  ///   - tree: The live tree.
  ///   - collector: The collector of the connection that owns the root now.
  /// - Returns: The stop reason of the end of the prompt, from the `idle` state of the root.
  /// - Throws: Whatever the prompt or the wait throws.
  private static func finish(
    _ tree: LiveTree, observedBy collector: UpdateCollector
  ) async throws -> StopReason? {
    tree.hold.release()
    let root = tree.rootId
    let updates = try await collector.wait(for: "the root ends its turn") { updates in
      ScriptedPromptFixture.idleStopReason(in: updates.filter { $0.sessionId == root }) != nil
    }
    _ = try await tree.prompt.value
    return ScriptedPromptFixture.idleStopReason(in: updates.filter { $0.sessionId == root })
  }

  // MARK: - The work goes on

  /// A hot resume leaves the open prompt of the root open: it ends as the script says, never
  /// as `cancelled`.
  @Test func aHotResumeDoesNotCancelTheOpenPrompt() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    _ = try await Self.resumeTrace(of: tree, on: second)

    let stopReason = try await Self.finish(tree, observedBy: try #require(second.collector))

    #expect(stopReason == .endTurn)
    await tree.fixture.close()
  }

  /// A hot resume leaves the child running: the child ends its turn after the resume, and the
  /// new connection sees the end.
  @Test func theChildRunEndsNormallyAfterAHotResume() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    _ = try await Self.resumeTrace(of: tree, on: second)
    let child = tree.childId

    tree.hold.release()
    let updates = try await #require(second.collector).wait(for: "the child ends its turn") { updates in
      updates.filter { $0.sessionId == child }.contains { notification in
        ScriptedPromptFixture.idleStopReason(in: [notification]) == .endTurn
      }
    }

    #expect(!updates.isEmpty)
    _ = try await tree.prompt.value
    await tree.fixture.close()
  }

  // MARK: - The replay

  /// The replay of the new connection announces the child on the stream of the root, and only then
  /// sends the history of the child.
  @Test func theReplayAnnouncesTheChildBeforeItsHistory() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    let child = tree.childId

    let trace = try await Self.resumeTrace(of: tree, on: second)

    let announced = trace.firstIndex { $0.isAnnouncement(of: child) }
    let history = trace.firstIndex { $0.isHistory(of: child) }
    let announcedAt = try #require(announced)
    let historyAt = try #require(history)
    #expect(announcedAt < historyAt)
    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    await tree.fixture.close()
  }

  /// The replay sends the text of the child under the id of the child, before the response.
  @Test func theReplayHoldsTheHistoryOfTheChildBeforeTheResponse() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    let child = tree.childId

    let trace = try await Self.resumeTrace(of: tree, on: second)

    let response = try #require(trace.firstIndex { $0.isResumeResponse })
    let history = try #require(trace.firstIndex { $0.isHistory(of: child) })
    #expect(history < response)
    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    await tree.fixture.close()
  }

  /// The wire of a hot resume follows the rules of the sub-agent trace validator.
  @Test func theWireOfAHotResumeFollowsTheRulesOfTheValidator() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)

    let trace = try await Self.resumeTrace(of: tree, on: second)

    #expect(SubagentWireTraceValidator().validate(trace) == [])
    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    await tree.fixture.close()
  }

  // MARK: - The window between the take and the replay

  /// A live update that the child sends after the take, while the replay is not out, reaches the
  /// new connection only after the announcement of the child.
  @Test func aLiveUpdateOfTheChildDuringTheReplayComesAfterItsAnnouncement() async throws {
    let windowTree = try await Self.startWindowTree()
    defer { windowTree.tree.prompt.cancel() }
    let child = windowTree.tree.childId

    let (trace, second) = try await Self.resumeTraceAcrossTheWindow(of: windowTree)

    let announcedAt = try #require(trace.firstIndex { $0.isAnnouncement(of: child) })
    let liveAt = try #require(Self.positions(of: Self.windowFirstText, on: child, in: trace).first)
    #expect(announcedAt < liveAt)
    _ = try await Self.finish(windowTree.tree, observedBy: try #require(second.collector))
    await windowTree.tree.fixture.close()
  }

  /// Each live update that the child sends between the take and the end of the replay reaches
  /// the new connection one time, after the response, in the order of the child. The replay does
  /// not hold these updates, so they go with the live traffic.
  @Test func eachLiveUpdateOfTheWindowComesOnceAfterTheResponseInOrder() async throws {
    let windowTree = try await Self.startWindowTree()
    defer { windowTree.tree.prompt.cancel() }
    let child = windowTree.tree.childId

    let (trace, second) = try await Self.resumeTraceAcrossTheWindow(of: windowTree)

    let response = try #require(trace.firstIndex { $0.isResumeResponse })
    let first = Self.positions(of: Self.windowFirstText, on: child, in: trace)
    let next = Self.positions(of: Self.windowSecondText, on: child, in: trace)
    let order = [response] + first + next
    #expect(
      first.count == Self.deliveriesOfOneUpdate && next.count == Self.deliveriesOfOneUpdate
        && order == order.sorted())
    _ = try await Self.finish(windowTree.tree, observedBy: try #require(second.collector))
    await windowTree.tree.fixture.close()
  }

  /// The wire of a hot resume with live updates in the window follows the rules of the sub-agent
  /// trace validator.
  @Test func theWireOfAHotResumeAcrossTheWindowFollowsTheRulesOfTheValidator() async throws {
    let windowTree = try await Self.startWindowTree()
    defer { windowTree.tree.prompt.cancel() }

    let (trace, second) = try await Self.resumeTraceAcrossTheWindow(of: windowTree)

    #expect(SubagentWireTraceValidator().validate(trace) == [])
    _ = try await Self.finish(windowTree.tree, observedBy: try #require(second.collector))
    await windowTree.tree.fixture.close()
  }

  // MARK: - A question in the window between the take and the replay

  /// A question that the child asks after the take, while the replay is not out, does not reach
  /// the new connection while the first frame of the replay waits.
  @Test(arguments: QuestionKind.allCases)
  func aQuestionOfTheChildInTheWindowWaitsForTheReplay(kind: QuestionKind) async throws {
    let windowTree = try await Self.startQuestionWindowTree(asking: kind)
    defer { windowTree.tree.prompt.cancel() }

    let wire = try await Self.resumeAcrossAQuestionWindow(of: windowTree)

    #expect(wire.requestsWhileTheReplayWaits == Self.requestsWhileTheReplayWaits)
    await windowTree.tree.fixture.close()
  }

  /// The wire of a hot resume with a question of the child in the window follows the rules of
  /// the sub-agent trace validator: the request comes after the announcement of the child, after
  /// the response, and after the snapshot of the child.
  @Test(arguments: QuestionKind.allCases)
  func theWireOfAHotResumeWithAQuestionInTheWindowFollowsTheRulesOfTheValidator(
    kind: QuestionKind
  ) async throws {
    let windowTree = try await Self.startQuestionWindowTree(asking: kind)
    defer { windowTree.tree.prompt.cancel() }

    let wire = try await Self.resumeAcrossAQuestionWindow(of: windowTree)

    let trace = WireTraceEvent.merged(wire.trace)
    #expect(SubagentWireTraceValidator().validate(trace) == [])
    await windowTree.tree.fixture.close()
  }

  /// The answer of the new owner to a question of the window reaches the child, and the child
  /// plays its next text. The question is not lost.
  @Test func theAnswerToAQuestionOfTheWindowReachesTheChild() async throws {
    let windowTree = try await Self.startQuestionWindowTree(asking: .elicitation)
    let wire = try await Self.resumeAcrossAQuestionWindow(of: windowTree)
    let child = windowTree.tree.childId

    try await Self.answerQuestion(of: wire.root)
    let updates = try await #require(wire.second.collector).wait(for: "the text after the answer") {
      updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId == child })
        .contains(Self.childTextAfter)
    }

    #expect(!updates.isEmpty)
    _ = try await windowTree.tree.prompt.value
    await windowTree.tree.fixture.close()
  }

  /// A question of the window is asked one time on the new owner, also after the answer: the
  /// held ask and the re-ask after the release do not both send it.
  @Test func aQuestionOfTheWindowIsAskedOnceOnTheNewOwner() async throws {
    let windowTree = try await Self.startQuestionWindowTree(asking: .elicitation)
    let wire = try await Self.resumeAcrossAQuestionWindow(of: windowTree)

    try await Self.answerQuestion(of: wire.root)
    _ = try await windowTree.tree.prompt.value
    let asked = await wire.second.elicitations?.creates ?? []

    #expect(asked.count == Self.requestsOfOneQuestion)
    await windowTree.tree.fixture.close()
  }

  /// An update that the agent records before the take, and that goes out after the take, goes
  /// to the old connection. The replay of the new connection holds it already, so the new
  /// connection does not get it live a second time. A closed gate of the test keeps the send
  /// from the record until after the take.
  @Test func anUpdateRecordedBeforeTheTakeGoesToTheOldConnection() async throws {
    let tree = try await Self.startLiveTree()
    defer { tree.prompt.cancel() }
    let agent = tree.fixture.harness.agent
    let gate = SessionAnnouncementGate(isOpen: false)
    let sink = agent.historySink(for: tree.rootId, gate: gate)
    let chunk = ContentChunk(
      content: .text(TextContent(text: Self.recordedBeforeTheTakeText)),
      messageId: ACPEventTranslator.makeMessageId())
    let recorded = Task { await sink(.agentMessageChunk(chunk)) }
    defer { recorded.cancel() }
    try await pollUntil(limit: Self.recordPollLimit, interval: Self.recordPollInterval) {
      gate.pendingCount == Self.sendsBeforeTheTake
    }
    let second = try await Self.openSecondConnection(to: tree)
    _ = try await Self.resumeTrace(of: tree, on: second)

    await gate.open()
    await recorded.value
    let updates = try await Self.waitForText(
      Self.recordedBeforeTheTakeText, on: tree.rootId, in: tree.fixture.collector)

    #expect(!updates.isEmpty)
    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    await tree.fixture.close()
  }

  /// Waits until a collector holds a text chunk of a session. The wait ends after
  /// ``syncWaitSeconds``, and then it throws.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - sessionId: The session.
  ///   - collector: The collector of a connection.
  /// - Returns: The notifications of the collector at the end of the wait.
  /// - Throws: ``ConditionWaitCancelled`` when the text does not come in time.
  private static func waitForText(
    _ text: String, on sessionId: SessionId, in collector: UpdateCollector
  ) async throws -> [UpdateSessionNotification] {
    let delivered = Task {
      try await collector.wait(for: "the text \(text)") { updates in
        updates.contains { $0.sessionId == sessionId && $0.update.agentMessageText.contains(text) }
      }
    }
    let limit = Task {
      try? await Task.sleep(for: .seconds(syncWaitSeconds))
      delivered.cancel()
    }
    defer { limit.cancel() }
    return try await delivered.value
  }

  // MARK: - The owner

  /// The new connection owns the root after the resume.
  @Test func theNewConnectionOwnsTheRootAfterAHotResume() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    _ = try await Self.resumeTrace(of: tree, on: second)

    let owner = tree.fixture.harness.agent.connections.owner(of: tree.rootId)

    #expect(owner == second.routedConnection.id)
    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    await tree.fixture.close()
  }

  /// The old connection gets no update after the resume: what the child makes later goes to the
  /// new connection only.
  @Test func theOldConnectionGetsNoUpdateAfterAHotResume() async throws {
    let tree = try await Self.startLiveTree()
    let second = try await Self.openSecondConnection(to: tree)
    _ = try await Self.resumeTrace(of: tree, on: second)
    let countAtResume = await tree.fixture.collector.updates.count

    _ = try await Self.finish(tree, observedBy: try #require(second.collector))
    let countAtEnd = await tree.fixture.collector.updates.count

    #expect(countAtEnd == countAtResume)
    await tree.fixture.close()
  }

  // MARK: - The pending request

  /// A question of the child that waits at the resume is asked on the new owner one time. The
  /// old connection keeps its one request, and gets no second.
  @Test func aPendingQuestionOfTheChildIsAskedOnceOnTheNewOwner() async throws {
    let tree = try await Self.startAskingTree()
    let second = try await Self.openSecondConnection(to: tree)
    let recorder = try #require(second.elicitations)

    let root = try await second.client.resumeSession(tree.replayRequest)
    let asked = try await recorder.waitForCreates(count: Self.requestsOfOneQuestion)

    #expect(asked.count == Self.requestsOfOneQuestion)
    try await Self.answerQuestion(of: root)
    _ = try await tree.prompt.value
    await tree.fixture.close()
  }

  /// The old connection does not get the question a second time.
  @Test func theOldConnectionIsNotAskedTheQuestionAgain() async throws {
    let tree = try await Self.startAskingTree()
    let second = try await Self.openSecondConnection(to: tree)
    let recorder = try #require(second.elicitations)
    let root = try await second.client.resumeSession(tree.replayRequest)
    _ = try await recorder.waitForCreates(count: Self.requestsOfOneQuestion)

    let oldRequests = await tree.fixture.harness.elicitations?.creates ?? []

    #expect(oldRequests.count == Self.requestsOfOneQuestion)
    try await Self.answerQuestion(of: root)
    _ = try await tree.prompt.value
    await tree.fixture.close()
  }

  /// The answer of the new owner reaches the child, and the child plays its next text.
  @Test func theAnswerOfTheNewOwnerReachesTheChild() async throws {
    let tree = try await Self.startAskingTree()
    let second = try await Self.openSecondConnection(to: tree)
    let root = try await second.client.resumeSession(tree.replayRequest)

    try await Self.answerQuestion(of: root)
    let child = tree.childId
    let updates = try await #require(second.collector).wait(for: "the text after the answer") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId == child })
        .contains(Self.childTextAfter)
    }

    #expect(!updates.isEmpty)
    _ = try await tree.prompt.value
    await tree.fixture.close()
  }

  /// Waits until the model of the root holds the question at the model of the child, and
  /// answers it.
  ///
  /// - Parameter root: The model of the resumed root on the second connection.
  /// - Throws: Whatever the wait throws.
  private static func answerQuestion(of root: SessionModel) async throws {
    try await ObservedValue.wait(for: "the child holds the question") {
      root.children.first?.pendingElicitations.isEmpty == false
    }
    let child = try #require(await root.children.first)
    let pending = try await ElicitationWait.firstPendingElicitation(in: child)
    await MainActor.run {
      child.acceptElicitation(pending.id, content: .object([answerField: .string(answer)]))
    }
  }

  // MARK: - A failed resume

  /// A hot resume that fails leaves the owner as it was. The direct caller has no connection to
  /// replay through, so the request fails before it takes the session.
  @Test func aFailedHotResumeLeavesTheOwnerAsItWas() async throws {
    let tree = try await Self.startLiveTree()
    let agent = tree.fixture.harness.agent
    let ownerBefore = agent.connections.owner(of: tree.rootId)

    _ = try? await agent.resumeSession(tree.replayRequest)

    #expect(agent.connections.owner(of: tree.rootId) == ownerBefore)
    _ = try await Self.finish(tree, observedBy: tree.fixture.collector)
    await tree.fixture.close()
  }

  /// A hot resume that fails leaves the live session open, with its prompt running to its end.
  @Test func aFailedHotResumeLeavesTheLiveSessionUsable() async throws {
    let tree = try await Self.startLiveTree()
    let agent = tree.fixture.harness.agent

    _ = try? await agent.resumeSession(tree.replayRequest)
    let stopReason = try await Self.finish(tree, observedBy: tree.fixture.collector)

    #expect(stopReason == .endTurn)
    #expect(await agent.sessions[tree.rootId]?.isClosed == false)
    await tree.fixture.close()
  }
}

extension WireTraceEvent {
  /// Whether this event is the response of the resume.
  fileprivate var isResumeResponse: Bool {
    if case .resumeResponse = self {
      return true
    }
    return false
  }

  /// Whether this event is an announcement of `child`, on any stream.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` for a `subagent_update` that names `child`.
  fileprivate func isAnnouncement(of child: SessionId) -> Bool {
    if case .update(_, let update) = self {
      return update.announces(child)
    }
    return false
  }

  /// Whether this event is an update on the stream of `child` that is not a `state_update`: a
  /// piece of the history of the child.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` for such an update.
  fileprivate func isHistory(of child: SessionId) -> Bool {
    if case .update(let stream, let update) = self {
      return stream == child && !update.isStateUpdate
    }
    return false
  }
}
