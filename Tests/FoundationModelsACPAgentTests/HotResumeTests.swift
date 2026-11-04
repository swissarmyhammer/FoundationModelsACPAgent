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

  // MARK: - Fixtures

  /// Starts a root with an open prompt and a child that runs and waits on a hold.
  ///
  /// - Returns: The live tree.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startLiveTree() async throws -> LiveTree {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childMarker,
        play: [.textDelta(childText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    return try await openPrompt(of: fixture, hold: hold)
  }

  /// Starts a root with an open prompt and a child that asks one question.
  ///
  /// - Returns: The live tree. Its hold is not used.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startAskingTree() async throws -> LiveTree {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childMarker,
        play: [.elicit(message: question), .textDelta(childTextAfter), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
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
  /// - Parameter tree: The live tree.
  /// - Returns: The harness of the second connection.
  /// - Throws: Whatever the handshake throws.
  private static func openSecondConnection(to tree: LiveTree) async throws -> AgentClientHarness {
    let second = await AgentClientHarness.makeRecording(agent: tree.fixture.harness.agent)
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
      updates.contains { Self.endStopReason(of: root, in: [$0]) != nil }
    }
    _ = try await tree.prompt.value
    return Self.endStopReason(of: root, in: updates)
  }

  /// The stop reason of the first `idle` state of a session that has one.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - updates: The notifications.
  /// - Returns: The stop reason, or `nil`.
  private static func endStopReason(
    of session: SessionId, in updates: [UpdateSessionNotification]
  ) -> StopReason? {
    updates.lazy.compactMap { notification -> StopReason? in
      if notification.sessionId == session, case .stateUpdate(.idle(let idle)) = notification.update {
        return idle.stopReason
      }
      return nil
    }.first
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
      updates.contains { notification in
        if notification.sessionId == child, case .stateUpdate(.idle(let idle)) = notification.update
        {
          return idle.stopReason == .endTurn
        }
        return false
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
