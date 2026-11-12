import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// A `session/cancel` is a command, close to a kill: it stops everything the session started, at
/// once (task ^n8pcmtd). The child agent runs of the session and their background work stop, and
/// the `idle` with the stop reason `cancelled` comes within seconds. The one exception is a
/// scheduled agent of the session: it stays saved, and keeps its timer.
///
/// Seen live in the bench run oneplan24 (django__django-13964): the root got the cancel, its
/// child coder kept a full test suite running, no `cancelled` idle came, and the harness waited
/// its full 600 seconds before it killed the process.
///
/// Each test opens the root session with an inline settle period of zero, so each run goes to the
/// background at once: the root answer ends, and only the background work is left.
@Suite(.closesHarnesses, .timeLimit(.minutes(1))) struct SessionCancelStopsAllWorkTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SessionCancelStopsAllWorkTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The agent that the child starts.
  private static let leafAgent = "leaf"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-KILL-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-KILL-MARKER"

  /// The marker of the prompt of the grandchild.
  private static let leafPrompt = "LEAF-KILL-MARKER"

  /// The first text of the run that holds.
  private static let heldText = "HELD-KILL-TEXT"

  /// How long a cancel may take until the `cancelled` idle comes. A cancel that waits for the
  /// held work to end by itself never meets it: the work holds until the test releases it.
  private static let cancelBound = Duration.seconds(10)

  /// A root session with a background child agent run and a background command, both held.
  private struct Family {
    let fixture: ScriptedPromptFixture
    let hold: ScriptedHold
    let command: HeldBackgroundCommand
    let child: SessionId

    /// The runner of the surface of the root.
    func runner() async throws -> AgentRunner {
      try #require(
        await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents?.runner)
    }

    /// The run of a session of the family.
    func run(of session: SessionId) async throws -> AgentRun {
      try #require(await runner().run(id: ULID(ulidString: session.rawValue)!))
    }
  }

  /// Makes a root session whose prompt starts the child in the background and runs the held
  /// command in the background, and waits until both work.
  ///
  /// - Parameter nested: Whether the child starts a grandchild in the background, which holds in
  ///   place of the child.
  private static func makeFamily(nested: Bool = false) async throws -> (Family, SessionId?) {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    let hold = ScriptedHold()
    let command = HeldBackgroundCommand()
    let heldPlay: [ScriptedPassStep] = [
      .textDelta(heldText), .holdUntilReleased(hold), .endPass,
    ]
    var script: [ScriptedPassStep] = [
      .onPrompt(
        containing: rootPrompt,
        play: [
          AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt),
          .toolCall(name: HeldBackgroundCommand.toolName, argumentsJSON: "{}"),
          .endPass,
        ])
    ]
    if nested {
      try AgentsToolTests.writeAgent(
        named: childAgent, in: cwd, tools: AgentsToolTests.agentsToolName)
      try AgentsToolTests.writeAgent(named: leafAgent, in: cwd)
      script.insert(.onPrompt(containing: leafPrompt, play: heldPlay), at: 0)
      script.insert(
        .onPrompt(
          containing: childPrompt,
          play: [AgentsToolTests.startAgentCall(agent: leafAgent, prompt: leafPrompt), .endPass]),
        at: 1)
    } else {
      try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
      script.insert(.onPrompt(containing: childPrompt, play: heldPlay), at: 0)
    }
    script.append(.endPass)
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd, hostTools: [command],
      inlineSettleGrace: 0)
    let root = fixture.sessionId
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    let updates = try await fixture.collector.wait(for: "the first text of the held run") {
      updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(heldText)
    }
    _ = try await command.started.wait(for: "the start of the held command") { $0 }
    let child = try #require(AnnouncedChild.first(in: updates, on: root))
    let leaf = nested ? AnnouncedChild.first(in: updates, on: child) : nil
    return (Family(fixture: fixture, hold: hold, command: command, child: child), leaf)
  }

  /// Whether a notification is the `idle` of `sessionId` with the stop reason `cancelled`.
  private static func isCancelledIdle(
    _ notification: UpdateSessionNotification, of sessionId: SessionId
  ) -> Bool {
    guard notification.sessionId == sessionId else { return false }
    return idleState(of: notification.update)?.stopReason == .cancelled
  }

  /// Sends `session/cancel` for `sessionId`, and gives the time until its `cancelled` idle.
  private static func cancel(
    _ sessionId: SessionId, in family: Family
  ) async throws -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    try await family.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: sessionId))
    _ = try await family.fixture.collector.wait(for: "the cancelled idle") { updates in
      updates.contains { isCancelledIdle($0, of: sessionId) }
    }
    return clock.now - start
  }

  // MARK: - A cancel of the root

  @Test
  func aCancelOfTheRootSendsTheCancelledIdleWithinSeconds() async throws {
    let (family, _) = try await Self.makeFamily()

    let elapsed = try await Self.cancel(family.fixture.sessionId, in: family)

    #expect(elapsed < Self.cancelBound)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCancelOfTheRootCancelsItsBackgroundChildRun() async throws {
    let (family, _) = try await Self.makeFamily()
    let childRun = try await family.run(of: family.child)

    _ = try await Self.cancel(family.fixture.sessionId, in: family)
    _ = try? await childRun.result()

    #expect(childRun.state == .cancelled)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCancelOfTheRootStopsItsBackgroundCommand() async throws {
    let (family, _) = try await Self.makeFamily()

    _ = try await Self.cancel(family.fixture.sessionId, in: family)
    _ = try await family.command.cancelled.wait(for: "the cancel of the held command") { $0 }

    #expect(family.command.cancelled.value)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aCancelOfTheRootKeepsItsScheduledAgentSavedAndScheduled() async throws {
    let (family, _) = try await Self.makeFamily()
    let runner = try await family.runner()
    let entry = try #require(await family.fixture.harness.agent.sessions[family.fixture.sessionId])
    let owner = try #require(ULID(ulidString: family.fixture.sessionId.rawValue))
    let task = await runner.schedule(
      AgentScheduleRequest(
        agent: Self.childAgent, prompt: "Report the state.", spec: .interval(seconds: 3600),
        owner: owner))
    let saved = ScheduleFileStore.file(
      of: owner, in: entry.transcriptDirectory.deletingLastPathComponent())

    _ = try await Self.cancel(family.fixture.sessionId, in: family)

    #expect(await runner.scheduledTask(id: task.id)?.state == .active)
    #expect(await runner.scheduledTasks(owner: owner).map(\.id) == [task.id])
    #expect(FileManager.default.fileExists(atPath: saved.path))
    family.hold.release()
    await family.fixture.close()
  }

  // MARK: - A close and a shutdown

  @Test
  func aCloseOfTheRootStopsItsBackgroundChildRunAndCommandAtOnce() async throws {
    let (family, _) = try await Self.makeFamily()
    let childRun = try await family.run(of: family.child)

    _ = try await family.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: family.fixture.sessionId))
    _ = try? await childRun.result()
    _ = try await family.command.cancelled.wait(for: "the cancel of the held command") { $0 }

    #expect(childRun.state == .cancelled)
    #expect(family.command.cancelled.value)
    family.hold.release()
    await family.fixture.close()
  }

  @Test
  func aShutdownStopsTheBackgroundChildRunAndCommandAtOnce() async throws {
    let (family, _) = try await Self.makeFamily()
    let childRun = try await family.run(of: family.child)

    await family.fixture.harness.agent.shutdown()
    _ = try? await childRun.result()
    _ = try await family.command.cancelled.wait(for: "the cancel of the held command") { $0 }

    #expect(childRun.state == .cancelled)
    #expect(family.command.cancelled.value)
    family.hold.release()
    await family.fixture.close()
  }

  // MARK: - A cancel of a nested session

  @Test
  func aCancelOfAChildCancelsTheBackgroundGrandchildItStarted() async throws {
    let (family, leaf) = try await Self.makeFamily(nested: true)
    let leafRun = try await family.run(of: try #require(leaf))

    _ = try await Self.cancel(family.child, in: family)
    _ = try? await leafRun.result()

    #expect(leafRun.state == .cancelled)
    family.hold.release()
    await family.fixture.close()
  }
}

/// A background tool whose run holds, as a long shell command holds, until the task of the run
/// is cancelled. It records the start and the cancel of the run.
struct HeldBackgroundCommand: FoundationModels.Tool, BackgroundTool {
  /// The wire arguments; the tool reads nothing from them.
  @Generable
  struct Arguments {}

  /// The name of the tool.
  static let toolName = "held_command"

  let name = Self.toolName

  let description = "a scripted command that runs until it is cancelled"

  var mount: ToolMount? { ToolMount(mode: .background) }

  var inlineSettleGrace: TimeInterval { 0 }

  /// Whether the run started.
  let started = WatchedValue(false)

  /// Whether the run got a cancel.
  let cancelled = WatchedValue(false)

  /// The gate the run holds on. Nothing opens it: only a cancel ends the run.
  private let gate = WatchedValue(false)

  func call(arguments: Arguments) async throws -> String {
    started.update { $0 = true }
    do {
      _ = try await gate.wait(for: "the gate of the held command") { $0 }
    } catch {
      cancelled.update { $0 = true }
      throw CancellationError()
    }
    return Self.toolName
  }
}
