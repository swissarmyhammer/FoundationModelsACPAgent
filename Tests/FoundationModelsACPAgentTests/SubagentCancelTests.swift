import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The cancel rules of the sessions of a family. `session/cancel` on the id of a child ends only
/// the run of that child and the runs that it waits for. `session/cancel` on the parent stops the
/// foreground work only, and a listed background child goes on. `session/close` on the parent
/// cancels all the runs below it, nested ones too.
///
/// Each family here has a root session and real agent runs of its runner. The announcer registers
/// the session of each run as a nested session of the root.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SubagentCancelTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SubagentCancelTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The agent that the child starts.
  private static let leafAgent = "leaf"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-CANCEL-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-CANCEL-MARKER"

  /// The marker of the prompt of the grandchild.
  private static let leafPrompt = "LEAF-CANCEL-MARKER"

  /// The first text of the grandchild. The chain works when it is out.
  private static let leafStartedText = "LEAF-STARTED-CANCEL-TEXT"

  /// How long a negative check waits for an update that must not come.
  private static let quietWindow = Duration.milliseconds(300)

  /// A root session with host runs that wait on one hold. The announcer lists each run.
  private struct Family {
    let fixture: ScriptedPromptFixture
    let hold: ScriptedHold
    let first: AgentRun
    let second: AgentRun
    let firstId: SessionId
    let secondId: SessionId
  }

  /// A root session whose prompt waits for a child that waits for a grandchild.
  private struct Chain {
    let fixture: ScriptedPromptFixture
    let hold: ScriptedHold
    let prompt: Task<PromptResponse, any Error>
    let child: SessionId
    let leaf: SessionId

    /// The run of a session of the chain.
    func run(of session: SessionId) async throws -> AgentRun {
      let runner = try #require(
        await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents?.runner)
      return try #require(await runner.run(id: ULID(ulidString: session.rawValue)!))
    }
  }

  /// Makes a root session and two host runs, and waits until the root lists both.
  private static func makeFamily() async throws -> Family {
    let hold = ScriptedHold()
    let cwd = makeResolvedDirectory(label: "\(label)-family-repo")
    try AgentsToolTests.writeAgent(named: AgentsToolTests.slowAgent, in: cwd)
    let fixture = try await ScriptedPromptFixture.make(
      script: AgentsToolTests.startAgentScript(hold: hold), label: "\(label)-family",
      workingDirectory: cwd, runClock: ManualRunClock())
    let runner = try #require(
      await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents?.runner)
    let first = try await runner.start(
      AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt)
    let second = try await runner.start(
      AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt)
    let firstId = SessionId(rawValue: first.id.description)
    let secondId = SessionId(rawValue: second.id.description)
    _ = try await fixture.collector.wait(for: "the root lists both runs") { updates in
      [firstId, secondId].allSatisfy { child in
        updates.contains { listsChild(child, in: $0) }
      }
    }
    return Family(
      fixture: fixture, hold: hold, first: first, second: second, firstId: firstId,
      secondId: secondId)
  }

  /// Makes a chain of three sessions whose runs wait inline, and waits until the grandchild works.
  private static func makeChain() async throws -> Chain {
    let cwd = makeResolvedDirectory(label: "\(label)-chain-repo")
    try AgentsToolTests.writeAgent(
      named: childAgent, in: cwd, tools: AgentsToolTests.agentsToolName)
    try AgentsToolTests.writeAgent(named: leafAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: leafPrompt,
        play: [.textDelta(leafStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: childPrompt,
        play: [AgentsToolTests.startAgentCall(agent: leafAgent, prompt: leafPrompt), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass]),
      .endPass,
    ]
    // The tool layers of the live loader make the Router see the run that a call waits for.
    let fixture = try await ScriptedPromptFixture.make(
      loader: makeHookLayeredModelLoader(script: script), label: "\(label)-chain",
      workingDirectory: cwd, runClock: ManualRunClock())
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    }
    let updates = try await fixture.collector.wait(for: "the first text of the grandchild") {
      updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(leafStartedText)
    }
    let child = try #require(AnnouncedChild.first(in: updates, on: root))
    let leaf = try #require(AnnouncedChild.first(in: updates, on: child))
    return Chain(fixture: fixture, hold: hold, prompt: prompt, child: child, leaf: leaf)
  }

  /// Waits until the runner holds a run, and gives it.
  private static func firstRun(of runner: AgentRunner) async -> AgentRun {
    var run = await runner.runs.first
    while run == nil {
      await Task.yield()
      run = await runner.runs.first
    }
    return run!
  }

  /// Whether a notification is a state of the root that lists `child` as background work.
  private static func listsChild(_ child: SessionId, in notification: UpdateSessionNotification)
    -> Bool
  {
    BackgroundListTests.list(of: notification.update)?.contains(
      .subagent(BackgroundSubagent(sessionId: child))) ?? false
  }

  /// Whether a notification is the `idle` of `sessionId` with the stop reason `cancelled`.
  private static func isCancelledIdle(
    _ notification: UpdateSessionNotification, of sessionId: SessionId
  ) -> Bool {
    guard notification.sessionId == sessionId else { return false }
    return idleState(of: notification.update)?.stopReason == .cancelled
  }

  /// The count of the `idle` updates of `sessionId` with the stop reason `cancelled`.
  private static func cancelledIdleCount(
    in updates: [UpdateSessionNotification], of sessionId: SessionId
  ) -> Int {
    updates.filter { isCancelledIdle($0, of: sessionId) }.count
  }

  // MARK: - A cancel of a child

  @Test
  func aCancelOfAChildEndsOnlyItsRun() async throws {
    let family = try await Self.makeFamily()

    try await family.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: family.firstId))
    _ = try? await family.first.result()

    #expect(family.first.state == .cancelled)
    #expect(family.second.state == .running)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCancelOfAChildLeavesTheParentOpen() async throws {
    let family = try await Self.makeFamily()

    try await family.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: family.firstId))
    _ = try? await family.first.result()

    let root = await family.fixture.harness.agent.sessions[family.fixture.sessionId]
    #expect(root?.isClosed == false)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func theClientSeesIdleWithTheCancelledStopReasonForTheChild() async throws {
    let family = try await Self.makeFamily()

    try await family.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: family.firstId))

    let updates = try await family.fixture.collector.wait(for: "the cancelled idle of the child") {
      updates in
      updates.contains { Self.isCancelledIdle($0, of: family.firstId) }
    }
    #expect(Self.cancelledIdleCount(in: updates, of: family.secondId) == 0)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func theCancelledRunMarksItsSessionEndedAsCancelled() async throws {
    let family = try await Self.makeFamily()

    try await family.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: family.firstId))
    _ = try? await family.first.result()
    let marker = try await family.fixture.harness.agent.sessionDirectory.endMarker(
      of: family.first.id)

    #expect(marker?.reason == .cancelled)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCancelOfAChildWithNoActiveWorkSendsNoNewIdle() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let childId = try await SessionSetupNestedTests.openNestedSession(
      in: fixture, below: fixture.sessionId)
    let child = try #require(await fixture.harness.agent.sessions[childId])
    await child.announcement.open()

    try await fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: childId))
    await fixture.harness.agent.awaitPromptsFinished(of: childId)
    try await Task.sleep(for: Self.quietWindow)

    let updates = await fixture.collector.updates
    #expect(Self.cancelledIdleCount(in: updates, of: childId) == 0)
    await fixture.close()
  }

  @Test
  func aCancelOfAChildCancelsTheGrandchildItWaitsFor() async throws {
    let chain = try await Self.makeChain()
    let leafRun = try await chain.run(of: chain.leaf)

    try await chain.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: chain.child))
    _ = try? await leafRun.result()

    #expect(leafRun.state == .cancelled)
    chain.hold.release()
    _ = try? await chain.prompt.value
    await chain.fixture.close()
  }

  // MARK: - A cancel of the parent

  @Test
  func aCancelOfTheParentLeavesABackgroundChildRunning() async throws {
    let hold = ScriptedHold()
    let cwd = makeResolvedDirectory(label: "\(Self.label)-background-repo")
    try AgentsToolTests.writeAgent(named: AgentsToolTests.slowAgent, in: cwd)
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "\(Self.label)-background-cache"),
      recordingsDirectory: makeResolvedDirectory(label: "\(Self.label)-background-recordings"),
      userDirectory: makeResolvedDirectory(label: "\(Self.label)-background-user"),
      loader: makeScriptedModelLoader(script: AgentsToolTests.startAgentScript(hold: hold)),
      inlineSettleGrace: 0)
    _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
    let response = try await agent.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))
    let entry = try #require(await agent.sessions[response.sessionId])
    _ = try await entry.session.respond(to: AgentsToolTests.rootSlowPrompt, maxTokens: nil)
    let runner = try #require(entry.surface.agents?.runner)
    let run = await Self.firstRun(of: runner)

    await agent.sessionCancel(CancelSessionNotification(sessionId: response.sessionId))
    try await Task.sleep(for: Self.quietWindow)

    #expect(run.state == .running)
    hold.release()
    await agent.shutdown()
  }

  @Test
  func aCancelOfTheParentCancelsTheChildThatItsPromptWaitsFor() async throws {
    let chain = try await Self.makeChain()
    let childRun = try await chain.run(of: chain.child)

    try await chain.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: chain.fixture.sessionId))
    _ = try? await childRun.result()
    _ = try await chain.prompt.value

    #expect(childRun.state == .cancelled)
    chain.hold.release()
    await chain.fixture.close()
  }

  // MARK: - A close of the parent

  @Test
  func aCloseOfTheParentCancelsEveryChildRun() async throws {
    let family = try await Self.makeFamily()

    _ = try await family.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: family.fixture.sessionId))
    _ = try? await family.first.result()
    _ = try? await family.second.result()

    #expect(family.first.state == .cancelled)
    #expect(family.second.state == .cancelled)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCloseOfTheParentCancelsTheNestedChildToo() async throws {
    let chain = try await Self.makeChain()
    let leafRun = try await chain.run(of: chain.leaf)

    _ = try await chain.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: chain.fixture.sessionId))
    _ = try? await leafRun.result()

    #expect(leafRun.state == .cancelled)
    chain.hold.release()
    _ = try? await chain.prompt.value
    await chain.fixture.close()
  }

  @Test
  func theClientSeesOneCancelledIdleForAChildOnTheCloseOfTheParent() async throws {
    let family = try await Self.makeFamily()

    _ = try await family.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: family.fixture.sessionId))
    _ = try? await family.first.result()
    try await Task.sleep(for: Self.quietWindow)

    let updates = await family.fixture.collector.updates
    #expect(Self.cancelledIdleCount(in: updates, of: family.firstId) == 1)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCloseOfTheParentSendsNoCancelledIdleForAChildThatEnded() async throws {
    let family = try await Self.makeFamily()
    family.hold.release()
    _ = try await family.first.result()
    _ = try await family.second.result()

    _ = try await family.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: family.fixture.sessionId))
    try await Task.sleep(for: Self.quietWindow)

    let updates = await family.fixture.collector.updates
    #expect(Self.cancelledIdleCount(in: updates, of: family.firstId) == 0)
    await family.fixture.close()
  }
}
