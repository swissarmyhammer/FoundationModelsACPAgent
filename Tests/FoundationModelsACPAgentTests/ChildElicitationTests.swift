import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// A question of a child run goes to the client one time, under the session id of the child. The
/// answer goes back to the run that asked. The root session sends no second request for the same
/// question. The child runs on a scripted model, and its `elicit` step asks the user.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildElicitationTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildElicitationTests"

  /// The agent that the root session starts.
  private static let childAgent = "asker"

  /// The marker of the prompt of the root session.
  private static let rootMarker = "ROOT-STARTS-AN-ASKING-CHILD"

  /// The marker of the prompt of the child.
  private static let childMarker = "CHILD-ASKS-THE-USER-NOW"

  /// The message of the question of the child.
  private static let question = "Which colour do you want?"

  /// The name of the one field of the question.
  private static let answerField = "answer"

  /// The text that the child plays after the question.
  private static let afterText = "CHILD-TEXT-AFTER-THE-QUESTION"

  /// The answer that the user gives.
  private static let answer = "blue"

  /// The number of requests that one question of a child makes at the client.
  private static let requestsOfOneQuestion = 1

  /// One run of the root session with a child that asks.
  private struct AskingRun {
    /// The fixture. The caller closes it.
    let fixture: ScriptedPromptFixture

    /// The task of the prompt of the root session.
    let prompt: Task<PromptResponse, any Error>

    /// The client model of the child session.
    let child: SessionModel

    /// The id of the child session.
    var childId: SessionId { child.sessionId }

    /// The id of the root session.
    var rootId: SessionId { fixture.sessionId }
  }

  /// Starts the root session with a child that asks one question, and waits until the client
  /// holds the question at the model of the child.
  ///
  /// - Returns: The run.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startAskingRun() async throws -> AskingRun {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childMarker,
        play: [.elicit(message: question), .textDelta(afterText), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootMarker))
    }
    let rootModel = fixture.session
    try await ObservedValue.wait(for: "the child holds the question") {
      rootModel.children.first?.pendingElicitations.isEmpty == false
    }
    let child = try #require(await rootModel.children.first)
    return AskingRun(fixture: fixture, prompt: prompt, child: child)
  }

  /// Answers the question that the client holds at the model of the child.
  ///
  /// - Parameters:
  ///   - run: The run.
  ///   - resolve: The client call that answers one question.
  private static func resolve(
    _ run: AskingRun,
    with resolve: @escaping @MainActor @Sendable (SessionModel, PendingElicitation.ID) -> Void
  ) async throws {
    let child = run.child
    let pending = try await ElicitationWait.firstPendingElicitation(in: child)
    await MainActor.run { resolve(child, pending.id) }
  }

  /// Waits for the final status of the `agents` call of the root session, then gives the
  /// notifications of the wire.
  ///
  /// - Parameter run: The run.
  /// - Returns: The notifications, in wire order.
  /// - Throws: Whatever the wait throws.
  private static func waitForTheEndOfTheChild(_ run: AskingRun) async throws
    -> [UpdateSessionNotification]
  {
    let root = run.rootId
    return try await run.fixture.collector.wait(for: "the child ends") { updates in
      Self.endStopReason(in: updates.filter { $0.sessionId != root }) != nil
    }
  }

  /// The stop reason of the end of the turn. The state ledger of a child sends a first `idle`
  /// with no stop reason when the work ends, and the end of the turn sends the `idle` with it.
  ///
  /// - Parameter updates: The notifications.
  /// - Returns: The stop reason of the first `idle` that has one, or `nil`.
  private static func endStopReason(in updates: [UpdateSessionNotification]) -> StopReason? {
    updates.lazy.compactMap { notification -> StopReason? in
      if case .stateUpdate(.idle(let idle)) = notification.update { return idle.stopReason }
      return nil
    }.first
  }

  /// The session ids that the requests name.
  ///
  /// - Parameter requests: The `elicitation/create` requests.
  /// - Returns: The session id of each request that has the scope of a session.
  private static func sessionIds(of requests: [CreateElicitationRequest]) -> [SessionId] {
    requests.compactMap { request in
      switch request.mode {
      case .form(let form):
        if case .session(let scope) = form.scope { return scope.sessionId }
        return nil
      case .url(let url):
        if case .session(let scope) = url.scope { return scope.sessionId }
        return nil
      default:
        return nil
      }
    }
  }

  // MARK: - The child session id

  /// The question of the child arrives with the session id of the child.
  @Test func theQuestionOfAChildArrivesUnderTheChildSessionId() async throws {
    let run = try await Self.startAskingRun()
    let recorder = try #require(run.fixture.harness.elicitations)

    let requests = try await recorder.waitForCreates(count: Self.requestsOfOneQuestion)

    #expect(Self.sessionIds(of: requests).first == run.childId)
    try await Self.resolve(run) { $0.cancelElicitation($1) }
    await run.fixture.close()
  }

  /// The client gets the question one time. The copy that the parent session holds is not sent.
  @Test func theClientGetsOneRequestForTheQuestionOfAChild() async throws {
    let run = try await Self.startAskingRun()
    try await Self.resolve(run) {
      $0.acceptElicitation($1, content: .object([Self.answerField: .string(Self.answer)]))
    }
    _ = try await Self.waitForTheEndOfTheChild(run)

    let requests = await run.fixture.harness.elicitations?.creates ?? []

    #expect(requests.count == Self.requestsOfOneQuestion)
    await run.fixture.close()
  }

  // MARK: - The answer

  /// The answer of the user reaches the child run. The run goes on and plays its next text under
  /// the child id.
  @Test func theAnswerReachesTheRunThatAsked() async throws {
    let run = try await Self.startAskingRun()
    try await Self.resolve(run) {
      $0.acceptElicitation($1, content: .object([Self.answerField: .string(Self.answer)]))
    }

    let updates = try await Self.waitForTheEndOfTheChild(run)

    let childText = ScriptedPromptFixture.agentText(
      in: updates.filter { $0.sessionId == run.childId })
    #expect(childText.contains(Self.afterText))
    await run.fixture.close()
  }

  // MARK: - The state

  /// The question of the child makes the child `requires_action`.
  @Test func theChildIsRequiresActionWhileItsQuestionWaits() async throws {
    let run = try await Self.startAskingRun()
    try await Self.resolve(run) {
      $0.acceptElicitation($1, content: .object([Self.answerField: .string(Self.answer)]))
    }

    let updates = try await Self.waitForTheEndOfTheChild(run)

    let childStates = updates.filter { $0.sessionId == run.childId }.map(\.update)
    #expect(childStates.contains { isRequiresActionState($0) })
    await run.fixture.close()
  }

  /// The copy of the question in the parent does not make the root `requires_action`.
  @Test func theRootIsNotRequiresActionBecauseOfTheQuestionOfItsChild() async throws {
    let run = try await Self.startAskingRun()
    try await Self.resolve(run) {
      $0.acceptElicitation($1, content: .object([Self.answerField: .string(Self.answer)]))
    }

    let updates = try await Self.waitForTheEndOfTheChild(run)

    let rootStates = updates.filter { $0.sessionId == run.rootId }.map(\.update)
    #expect(!rootStates.contains { isRequiresActionState($0) })
    await run.fixture.close()
  }

  // MARK: - The cancel

  /// A cancel of the child ends the question that waits: the client holds no question of the
  /// child any more, and the child ends as cancelled.
  @Test func aCancelOfTheChildEndsItsPendingQuestion() async throws {
    let run = try await Self.startAskingRun()

    try await run.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: run.childId))
    try await ElicitationWait.waitUntilNoPendingElicitation(in: run.child)
    let updates = try await Self.waitForTheEndOfTheChild(run)

    let childUpdates = updates.filter { $0.sessionId == run.childId }
    #expect(Self.endStopReason(in: childUpdates) == .cancelled)
    await run.fixture.close()
  }

  // MARK: - The replay

  /// A resume with a replay from the start sends no question to the client.
  @Test func aReplaySendsNoQuestion() async throws {
    let run = try await Self.startAskingRun()
    try await Self.resolve(run) {
      $0.acceptElicitation($1, content: .object([Self.answerField: .string(Self.answer)]))
    }
    _ = try await Self.waitForTheEndOfTheChild(run)
    _ = try await run.prompt.value
    let cwd = run.fixture.cwd

    let requestsAfterTheReplay = try await run.fixture.closeAndResume(
      makeSecond: { _ in
        try await ScriptedPromptFixture.make(
          script: [.endPass], label: "\(Self.label)-second", workingDirectory: cwd)
      },
      read: { second, _ in await second.harness.elicitations?.creates ?? [] })

    #expect(requestsAfterTheReplay.isEmpty)
  }
}

/// The relay of a session that gets the relayed copy of a child question, and the relay of a
/// child session that is not announced yet. Each test calls the relay directly, with a double of
/// the Router session that records each answer.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildElicitationRelayTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildElicitationRelayTests"

  /// The name of the tool that posts the questions of the tests.
  private static let askingTool = "elicitor"

  /// The name of the agent that relays the copies.
  private static let relayingAgent = "worker"

  /// The parts of one test: the fixture, the relay under test, and the double of the Router
  /// session.
  private struct Parts {
    /// The wired fixture.
    let fixture: ScriptedPromptFixture

    /// The relay under test.
    let relay: ElicitationRelay

    /// The record of the claims that the relay reads.
    let claims: ElicitationClaims

    /// The double that records the answers that go to Router.
    let session: CloseCountingRoutedSession
  }

  /// Wires a fixture and a relay for its session, runs `body`, and closes the fixture.
  ///
  /// - Parameters:
  ///   - announcement: The gate of the relay, or `nil` for a session the client knows.
  ///   - body: The work of the test.
  /// - Returns: What `body` returns.
  /// - Throws: What the wiring or `body` throws.
  private static func withParts<Result>(
    announcement: SessionAnnouncementGate? = nil, _ body: (Parts) async throws -> Result
  ) async throws -> Result {
    let fixture = try await ScriptedPromptFixture.make(script: [], label: label)
    let claims = ElicitationClaims()
    let table = fixture.harness.agent.connections
    let sessionId = fixture.sessionId
    let relay = ElicitationRelay(
      sessionId: sessionId, announcement: announcement, claims: claims,
      outboundPath: { table.path(forSession: sessionId) })
    let entry = try #require(await fixture.harness.agent.sessions[sessionId])
    let parts = Parts(
      fixture: fixture, relay: relay, claims: claims,
      session: CloseCountingRoutedSession(wrapping: entry.session))
    do {
      let result = try await body(parts)
      await fixture.close()
      return result
    } catch {
      await fixture.close()
      throw error
    }
  }

  /// The event of a question.
  ///
  /// - Parameter request: The request.
  /// - Returns: The event that the projector gives the relay.
  private static func event(of request: ElicitationRequest) -> OperationEvent {
    OperationEvent(
      tool: askingTool, op: "elicit", correlationID: "child-elicitation-\(request.elicitationId)",
      kind: .elicitation, detail: "", elicitation: request)
  }

  /// The relayed copy of a question, as the relay of a parent session gets it.
  ///
  /// - Parameter elicitationId: The id of the question.
  /// - Returns: The copy.
  private static func copy(of elicitationId: ULID) -> ElicitationRequest {
    OpenQuestion.makeFormRequest(elicitationId: elicitationId)
      .relayed(by: relayingAgent, askedBy: askingTool)
  }

  /// The end that Router sends for a question.
  ///
  /// - Parameter elicitationId: The id of the question.
  /// - Returns: The end.
  private static func end(of elicitationId: ULID) -> ElicitationEnd {
    ElicitationEnd(
      elicitationId: elicitationId, response: .cancel(reason: RunPlane.runCancelledReason))
  }

  /// Waits until the client holds a question, and cancels it there.
  ///
  /// - Parameter parts: The parts of the test.
  /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
  private static func cancelTheQuestionAtTheClient(_ parts: Parts) async throws {
    let clientSession = parts.fixture.session
    try await ObservedValue.wait(for: "the question reaches the client") {
      !clientSession.pendingElicitations.isEmpty
    }
    await MainActor.run {
      for pending in clientSession.pendingElicitations {
        clientSession.cancelElicitation(pending.id)
      }
    }
  }

  // MARK: - The relayed copy

  /// A relayed copy waits for its child. When the child claims the question, the relay sends
  /// nothing and gives Router no answer.
  @Test func aRelayedCopyIsDroppedWhenTheChildClaimsTheQuestion() async throws {
    let (creates, responses) = try await Self.withParts { parts in
      let elicitationId = ULID()
      let copy = Task {
        await parts.relay.relay(Self.event(of: Self.copy(of: elicitationId)), on: parts.session)
      }
      parts.claims.claim(elicitationId.ulidString)
      await copy.value
      return (
        await parts.fixture.harness.elicitations?.creates ?? [],
        await parts.session.responses.map(\.response)
      )
    }

    #expect(creates.isEmpty)
    #expect(responses.isEmpty)
  }

  /// A copy whose child was claimed before the copy came is dropped too.
  @Test func aRelayedCopyOfAClaimedQuestionIsDropped() async throws {
    let creates = try await Self.withParts { parts in
      let elicitationId = ULID()
      parts.claims.claim(elicitationId.ulidString)
      await parts.relay.relay(Self.event(of: Self.copy(of: elicitationId)), on: parts.session)
      return await parts.fixture.harness.elicitations?.creates ?? []
    }

    #expect(creates.isEmpty)
  }

  /// A copy that the host released goes to the client as a question of the session.
  @Test func aReleasedCopyGoesToTheClient() async throws {
    let creates = try await Self.withParts { parts in
      parts.claims.release(owner: parts.fixture.sessionId)
      let copy = Task {
        await parts.relay.relay(Self.event(of: Self.copy(of: ULID())), on: parts.session)
      }
      try await Self.cancelTheQuestionAtTheClient(parts)
      await copy.value
      return await parts.fixture.harness.elicitations?.creates ?? []
    }

    #expect(creates.count == 1)
  }

  /// The end of a copy that waits goes to nobody: the relay keeps no end, so a question with
  /// the same id still reaches the client.
  @Test func theEndOfAWaitingCopyLeavesNoEndBehind() async throws {
    let creates = try await Self.withParts { parts in
      let elicitationId = ULID()
      let copy = Task {
        await parts.relay.relay(Self.event(of: Self.copy(of: elicitationId)), on: parts.session)
      }
      await parts.relay.end(Self.end(of: elicitationId))
      await copy.value
      let original = Task {
        await parts.relay.relay(
          Self.event(of: OpenQuestion.makeFormRequest(elicitationId: elicitationId)),
          on: parts.session)
      }
      try await Self.cancelTheQuestionAtTheClient(parts)
      await original.value
      return await parts.fixture.harness.elicitations?.creates ?? []
    }

    #expect(creates.count == 1)
  }

  /// The end of a copy that the relay dropped goes to nobody too.
  @Test func theEndOfADroppedCopyLeavesNoEndBehind() async throws {
    let creates = try await Self.withParts { parts in
      let elicitationId = ULID()
      parts.claims.claim(elicitationId.ulidString)
      await parts.relay.relay(Self.event(of: Self.copy(of: elicitationId)), on: parts.session)
      await parts.relay.end(Self.end(of: elicitationId))
      let original = Task {
        await parts.relay.relay(
          Self.event(of: OpenQuestion.makeFormRequest(elicitationId: elicitationId)),
          on: parts.session)
      }
      try await Self.cancelTheQuestionAtTheClient(parts)
      await original.value
      return await parts.fixture.harness.elicitations?.creates ?? []
    }

    #expect(creates.count == 1)
  }

  // MARK: - The announcement

  /// A question of a session that is announced later waits for the announcement. After the
  /// announcement it reaches the client.
  @Test func aQuestionWaitsForTheAnnouncementOfItsSession() async throws {
    let gate = SessionAnnouncementGate(isOpen: false)
    let creates = try await Self.withParts(announcement: gate) { parts in
      let question = Task {
        await parts.relay.relay(
          Self.event(of: OpenQuestion.makeFormRequest()), on: parts.session)
      }
      await gate.open()
      try await Self.cancelTheQuestionAtTheClient(parts)
      await question.value
      return await parts.fixture.harness.elicitations?.creates ?? []
    }

    #expect(creates.count == 1)
  }

  /// A question of a session that ended with no announcement is never sent. Router gets a
  /// cancel that says why.
  @Test func aQuestionOfAnUnannouncedSessionIsCancelledAtRouter() async throws {
    let gate = SessionAnnouncementGate(isOpen: false)
    let (creates, responses) = try await Self.withParts(announcement: gate) { parts in
      let question = Task {
        await parts.relay.relay(
          Self.event(of: OpenQuestion.makeFormRequest()), on: parts.session)
      }
      gate.discard()
      await question.value
      return (
        await parts.fixture.harness.elicitations?.creates ?? [],
        await parts.session.responses.map(\.response)
      )
    }

    #expect(creates.isEmpty)
    #expect(
      responses == [.cancel(reason: ElicitationRelay.CancelReason.notAnnounced.rawValue)])
  }
}
