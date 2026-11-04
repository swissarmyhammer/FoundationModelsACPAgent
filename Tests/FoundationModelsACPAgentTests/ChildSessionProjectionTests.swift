import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A child session goes to the wire through the same projector as the root
/// session, under its own session id. The root session starts a child with an
/// `agents` call. The child runs on a scripted model.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildSessionProjectionTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildSessionProjectionTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The agent that the child starts in the chain of three sessions.
  private static let leafAgent = "leaf"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-CHILD-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-RUN-MARKER"

  /// The marker of the prompt of the leaf.
  private static let leafPrompt = "LEAF-RUN-MARKER"

  /// The first text of a child that holds after it.
  private static let startedText = "CHILD-STARTED-TEXT"

  /// A time that is past the settle period of an `agents` call.
  private static let pastTheSettlePeriod = 3600

  /// The final text of the leaf.
  private static let leafText = "LEAF-FINAL-TEXT"

  /// The final text of the child.
  private static let childText = "CHILD-FINAL-TEXT"

  /// The number of `runCode` calls that the scripted child makes.
  private static let toolCallsOfTheChild = 2

  /// The snippet of each `runCode` call of the child.
  private static let snippet = "40 + 2"

  /// The snippet of each `runCode` call that the root makes before its `agents` call.
  private static let warmupSnippet = "1 + 1"

  /// The number of `runCode` calls that the root makes before its `agents` call in a run that
  /// the validator reads. The scripted model gives the id `scripted-call-N` to the call N of
  /// each session. The validator reads a tool call id as one name in the whole trace. ACP
  /// scopes the id to its session. These calls move the id of the `agents` call away from the
  /// ids of the two calls of the child.
  private static let rootWarmupCalls = 2

  /// The wire after one run of the scripted child.
  private struct Wire {
    /// The fixture.
    let fixture: ScriptedPromptFixture

    /// The id of the child.
    let child: SessionId

    /// The id of the `agents` call of the root session.
    let agentsCall: ToolCallId

    /// The notifications, in wire order.
    let updates: [UpdateSessionNotification]

    /// The root session.
    var root: SessionId { fixture.sessionId }

    /// The notifications of one session, in wire order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The notifications that name it.
    func updates(of session: SessionId) -> [UpdateSessionNotification] {
      updates.filter { $0.sessionId == session }
    }

    /// The position of the first announcement of the child.
    var announcement: Int? {
      updates.firstIndex { notification in
        if case .subagentUpdate(let update) = notification.update {
          return update.sessionId == child
        }
        return false
      }
    }

    /// The position of the final status of the `agents` call.
    var finalAgentsCall: Int? {
      updates.firstIndex { notification in
        notification.sessionId == root
          && ChildSessionProjectionTests.isFinal(notification.update, of: agentsCall)
      }
    }

    /// The state updates of the child, in order.
    var childStates: [StateUpdate] {
      updates(of: child).compactMap { notification in
        if case .stateUpdate(let state) = notification.update { return state }
        return nil
      }
    }

    /// The ids of the tool calls that a session sent.
    ///
    /// - Parameter session: The session.
    /// - Returns: The ids.
    func toolCallIds(of session: SessionId) -> Set<ToolCallId> {
      Set(
        updates(of: session).compactMap { notification in
          if case .toolCallUpdate(let call) = notification.update { return call.toolCallId }
          return nil
        })
    }

    /// The wire as a trace for the validator.
    var trace: [WireTraceEvent] {
      updates.map { .update(sessionId: $0.sessionId, update: $0.update) }
    }
  }

  /// Whether an update gives a final status to a call.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - call: The call.
  /// - Returns: `true` for a `completed`, `failed` or `cancelled` status of that call.
  static func isFinal(_ update: SessionUpdate, of call: ToolCallId) -> Bool {
    guard case .toolCallUpdate(let update) = update, update.toolCallId == call,
      case .value(let status) = update.status
    else {
      return false
    }
    return status == .completed || status == .failed || status == .cancelled
  }

  /// The `idle` of a state update.
  ///
  /// - Parameter state: The state update, or `nil`.
  /// - Returns: The `idle`, or `nil` for any other state.
  private static func idle(of state: StateUpdate?) -> IdleStateUpdate? {
    if case .idle(let idle)? = state { return idle }
    return nil
  }

  /// The stop reason of an `idle` state update.
  ///
  /// - Parameter state: The state update, or `nil`.
  /// - Returns: The stop reason, or `nil` for any other state.
  private static func stopReason(of state: StateUpdate?) -> StopReason? {
    idle(of: state)?.stopReason
  }

  /// Whether an update is an agent message.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for a message chunk.
  private static func isMessage(_ update: SessionUpdate) -> Bool {
    if case .agentMessageChunk = update { return true }
    return false
  }

  /// The id of a session that an announcement names.
  ///
  /// - Parameter updates: The notifications.
  /// - Returns: The first announced child, or `nil`.
  private static func firstChild(in updates: [UpdateSessionNotification]) -> SessionId? {
    for notification in updates {
      if case .subagentUpdate(let update) = notification.update { return update.sessionId }
    }
    return nil
  }

  /// The id of the `agents` call of a session, as the first update that names the tool.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - session: The session of the call.
  /// - Returns: The id, or `nil`.
  private static func agentsCall(in updates: [UpdateSessionNotification], of session: SessionId)
    -> ToolCallId?
  {
    for notification in updates where notification.sessionId == session {
      if case .toolCallUpdate(let call) = notification.update,
        call.name == .value(AgentsToolTests.agentsToolName)
      {
        return call.toolCallId
      }
    }
    return nil
  }

  /// The scripted steps of one `runCode` call.
  ///
  /// - Returns: The step.
  /// - Throws: The arguments-encoding error.
  private static func codeCall() throws -> ScriptedPassStep {
    try ScriptedPromptFixture.makeRunCodeCall(code: snippet)
  }

  /// Runs the root session with a child that plays `childPlay`, and waits
  /// for the final status of the `agents` call.
  ///
  /// - Parameters:
  ///   - childPlay: The steps of the child.
  ///   - rootWarmupCalls: The number of `runCode` calls that the root makes before its `agents`
  ///     call.
  ///   - childTools: The `tools` key of the child agent, or `nil` for the default tools.
  /// - Returns: The wire.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func run(
    childPlay: [ScriptedPassStep], rootWarmupCalls: Int = 0, childTools: String? = nil
  ) async throws -> Wire {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd, tools: childTools)
    try AgentsToolTests.writeAgent(named: leafAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: leafPrompt, play: [.textDelta(leafText), .endPass]),
      .onPrompt(containing: childPrompt, play: childPlay),
      .onPrompt(
        containing: rootPrompt,
        play: try warmup(rootWarmupCalls) + [
          AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: rootPrompt))
    let updates = try await fixture.collector.wait(for: "the final status of the agents call") {
      updates in
      guard let call = agentsCall(in: updates, of: fixture.sessionId) else { return false }
      return updates.contains { $0.sessionId == fixture.sessionId && isFinal($0.update, of: call) }
    }
    let call = try #require(agentsCall(in: updates, of: fixture.sessionId))
    return Wire(
      fixture: fixture, child: try #require(firstChild(in: updates)), agentsCall: call,
      updates: updates)
  }

  /// The `runCode` calls that the root makes before its `agents` call.
  ///
  /// - Parameter count: The number of calls.
  /// - Returns: The steps.
  /// - Throws: The arguments-encoding error.
  private static func warmup(_ count: Int) throws -> [ScriptedPassStep] {
    try (0..<count).map { _ in try ScriptedPromptFixture.makeRunCodeCall(code: warmupSnippet) }
  }

  /// The child that makes two tool calls and answers.
  ///
  /// - Returns: The steps.
  /// - Throws: The arguments-encoding error.
  private static func toolCallingChild() throws -> [ScriptedPassStep] {
    try (0..<toolCallsOfTheChild).map { _ in try codeCall() } + [.textDelta(childText), .endPass]
  }

  // MARK: The child under its own id

  /// A child with two tool calls sends two tool calls under the child id,
  /// after its announcement.
  @Test
  func theToolCallsOfAChildGoOutUnderTheChildIdAfterItsAnnouncement() async throws {
    let wire = try await Self.run(childPlay: Self.toolCallingChild())
    let announcement = try #require(wire.announcement)

    let calls = wire.toolCallIds(of: wire.child)

    #expect(calls.count >= Self.toolCallsOfTheChild)
    let first = try #require(wire.updates.firstIndex { $0.sessionId == wire.child })
    #expect(first > announcement)
    await wire.fixture.close()
  }

  /// The text of the child goes out under the child id.
  /// The root stream holds no text of the child.
  @Test
  func theTextOfAChildGoesOutUnderTheChildIdOnly() async throws {
    let wire = try await Self.run(childPlay: Self.toolCallingChild())

    let childText = ScriptedPromptFixture.agentText(in: wire.updates(of: wire.child))
    let rootText = ScriptedPromptFixture.agentText(in: wire.updates(of: wire.root))

    #expect(childText == Self.childText)
    #expect(!rootText.contains(Self.childText))
    await wire.fixture.close()
  }

  /// The root stream holds no tool call of the child.
  /// The snippet of the child is in the stream of the child only.
  @Test
  func theRootStreamHoldsNoToolCallOfTheChild() async throws {
    let wire = try await Self.run(childPlay: Self.toolCallingChild())

    func mentionsSnippet(_ notifications: [UpdateSessionNotification]) -> Bool {
      notifications.contains { String(describing: $0.update).contains(Self.snippet) }
    }

    #expect(mentionsSnippet(wire.updates(of: wire.child)))
    #expect(!mentionsSnippet(wire.updates(of: wire.root)))
    await wire.fixture.close()
  }

  // MARK: The state of the child

  /// The child reports `running` first and `idle` with the stop reason last.
  @Test
  func theChildGoesRunningAndEndsIdleWithItsStopReason() async throws {
    let wire = try await Self.run(childPlay: Self.toolCallingChild())

    let states = wire.childStates

    #expect(states.first == .running(RunningStateUpdate()))
    #expect(Self.stopReason(of: states.last) == .endTurn)
    await wire.fixture.close()
  }

  /// A child that fails ends `idle` with the error.
  @Test
  func aChildThatFailsEndsIdleWithTheError() async throws {
    let wire = try await Self.run(childPlay: [.fail(.guardrailViolation), .endPass])

    #expect(Self.idle(of: wire.childStates.last)?.error != nil)
    await wire.fixture.close()
  }

  // MARK: The link

  /// The `agents` call carries the id of the child in `_meta.sah.agentRun`,
  /// after the announcement of the child.
  @Test
  func theAgentsCallCarriesTheLinkToTheChild() async throws {
    let wire = try await Self.run(childPlay: Self.toolCallingChild())
    let announcement = try #require(wire.announcement)

    let linked = wire.updates.indices.first { index in
      let notification = wire.updates[index]
      guard notification.sessionId == wire.root,
        case .toolCallUpdate(let call) = notification.update,
        call.toolCallId == wire.agentsCall, case .value(let meta) = call.meta
      else {
        return false
      }
      return SAH.AgentRun.extract(from: meta)?.sessionId == wire.child
    }

    #expect(try #require(linked) > announcement)
    await wire.fixture.close()
  }

  // MARK: The end

  /// The final status of the `agents` call comes after the last update of
  /// the child, and after its final `idle`.
  ///
  /// A foreground call returns after its child ends, so this order holds without the hold too.
  /// This test does not prove the hold. ``aBackgroundRunKeepsTheFinalStatusOfItsCallUntilTheChildEnds()``
  /// proves the hold on the wire. `AgentCallHoldsTests` proves it for a foreground call that
  /// returns before the child ends.
  @Test
  func theFinalStatusOfTheAgentsCallComesAfterTheLastUpdateOfTheChild() async throws {
    let wire = try await Self.run(
      childPlay: Self.toolCallingChild(), rootWarmupCalls: Self.rootWarmupCalls)

    let last = try #require(wire.updates.lastIndex { $0.sessionId == wire.child })

    #expect(try #require(wire.finalAgentsCall) > last)
    await wire.fixture.close()
  }

  /// The wire of the run follows the rules for sub-agent sessions. This is a check of the rules.
  /// It does not prove the hold (see the test of the final status above).
  @Test
  func theWireOfARunFollowsTheRulesForSubagentSessions() async throws {
    let wire = try await Self.run(
      childPlay: Self.toolCallingChild(), rootWarmupCalls: Self.rootWarmupCalls)

    let violations = SubagentWireTraceValidator().validate(wire.trace)

    #expect(violations.isEmpty, "\(violations)")
    await wire.fixture.close()
  }

  /// A run that goes to the background, and holds in its child until the test releases it.
  private struct HeldBackgroundRun {
    /// The fixture.
    let fixture: ScriptedPromptFixture

    /// The id of the child.
    let child: SessionId

    /// The id of the `agents` call.
    let call: ToolCallId

    /// The notifications while the child holds.
    let held: [UpdateSessionNotification]
  }

  /// Starts a run that goes to the background after the settle period, with its child held.
  ///
  /// - Parameters:
  ///   - hold: The hold that the child waits on.
  ///   - name: The label of the folders of the fixture.
  /// - Returns: The run, after the `agents` call returned and the child is still held.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startHeldBackgroundRun(hold: ScriptedHold, label name: String) async throws
    -> HeldBackgroundRun
  {
    let clock = ManualRunClock()
    let cwd = makeResolvedDirectory(label: "\(label)-\(name)")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childPrompt,
        play: [.textDelta(startedText), .holdUntilReleased(hold), .textDelta(childText), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd, runClock: clock)
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: rootPrompt))
    }
    _ = try await fixture.collector.wait(for: "the first text of the child") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != fixture.sessionId })
        .contains(startedText)
    }
    await clock.waitForSleepers(atLeast: 1)
    clock.advance(by: .seconds(pastTheSettlePeriod))
    _ = try await prompt.value
    await fixture.harness.agent.historySink(for: fixture.sessionId)(
      SessionSetupNestedTests.makeMessageUpdate())
    let held = try await fixture.collector.wait(for: "the barrier message") { updates in
      updates.contains { $0.sessionId == fixture.sessionId && isMessage($0.update) }
    }
    return HeldBackgroundRun(
      fixture: fixture, child: try #require(firstChild(in: held)),
      call: try #require(agentsCall(in: held, of: fixture.sessionId)), held: held)
  }

  /// A run that goes to the background ends the `agents` call before the child ends. The
  /// final status of the call waits for the end of the child, and goes out after its last
  /// update. The client removes the child at the final status, so the child must be done.
  @Test
  func aBackgroundRunKeepsTheFinalStatusOfItsCallUntilTheChildEnds() async throws {
    let hold = ScriptedHold()
    let run = try await Self.startHeldBackgroundRun(hold: hold, label: "background")
    let fixture = run.fixture
    #expect(
      !run.held.contains {
        $0.sessionId == fixture.sessionId && Self.isFinal($0.update, of: run.call)
      })

    hold.release()
    let updates = try await fixture.collector.wait(for: "the final status of the agents call") {
      updates in
      updates.contains {
        $0.sessionId == fixture.sessionId && Self.isFinal($0.update, of: run.call)
      }
    }

    let wire = Wire(fixture: fixture, child: run.child, agentsCall: run.call, updates: updates)
    let last = try #require(updates.lastIndex { $0.sessionId == run.child })
    #expect(try #require(wire.finalAgentsCall) > last)
    #expect(SubagentWireTraceValidator().validate(wire.trace).isEmpty)
    await fixture.close()
  }

  // MARK: A chain of three sessions

  /// The root starts a child, and the child starts a leaf. The leaf is announced on the child
  /// and sends its text under its own id. The wire follows the rules at each link.
  @Test
  func aChainOfThreeSessionsFollowsTheSameRuleAtEachLink() async throws {
    let wire = try await Self.run(
      childPlay: [
        AgentsToolTests.startAgentCall(agent: Self.leafAgent, prompt: Self.leafPrompt),
        .textDelta(Self.childText), .endPass,
      ], rootWarmupCalls: Self.rootWarmupCalls, childTools: AgentsToolTests.agentsToolName)

    let announced = wire.updates.compactMap {
      notification -> (parent: SessionId, child: SessionId)? in
      if case .subagentUpdate(let update) = notification.update {
        return (notification.sessionId, update.sessionId)
      }
      return nil
    }
    let leaf = try #require(announced.first { $0.parent == wire.child }?.child)

    #expect(ScriptedPromptFixture.agentText(in: wire.updates(of: leaf)) == Self.leafText)
    #expect(
      !ScriptedPromptFixture.agentText(in: wire.updates(of: wire.child)).contains(Self.leafText))
    let violations = SubagentWireTraceValidator().validate(wire.trace)
    #expect(violations.isEmpty, "\(violations)")
    await wire.fixture.close()
  }

  /// The child ends with two `idle` updates: the first has no stop reason, and the second has it.
  /// The wire validator accepts the pair. The client removes the child at the final status
  /// of its call. So the test reads the stop reason on the wire.
  @Test
  func theTwoIdleUpdatesAtTheEndOfTheChildAreAccepted() async throws {
    let wire = try await Self.run(
      childPlay: Self.toolCallingChild(), rootWarmupCalls: Self.rootWarmupCalls)

    let idles = wire.childStates.compactMap { Self.idle(of: $0) }

    #expect(idles.count == 2)
    #expect(idles.first?.stopReason == nil)
    #expect(idles.last?.stopReason == .endTurn)
    #expect(SubagentWireTraceValidator().validate(wire.trace).isEmpty)
    await wire.fixture.close()
  }

  /// The child has an entry and a link in the tree while its run works. When the run ends and
  /// the final status is out, the entry and the link are gone.
  @Test
  func theChildIsRetiredWhenItsRunEnds() async throws {
    let hold = ScriptedHold()
    let run = try await Self.startHeldBackgroundRun(hold: hold, label: "retire")
    let agent = run.fixture.harness.agent

    #expect(await agent.sessions[run.child] != nil)
    #expect(agent.sessionTree.children(of: run.fixture.sessionId) == [run.child])

    hold.release()
    _ = try await run.fixture.collector.wait(for: "the final status of the agents call") {
      updates in
      updates.contains {
        $0.sessionId == run.fixture.sessionId && Self.isFinal($0.update, of: run.call)
      }
    }

    #expect(await agent.sessions[run.child] == nil)
    #expect(agent.sessionTree.children(of: run.fixture.sessionId).isEmpty)
    await run.fixture.close()
  }
}
