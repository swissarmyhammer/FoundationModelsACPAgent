import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// An orderly shutdown of the process leaves a working nested run restorable, and it pauses the
/// open tool calls: the history holds no final status for them. A user `session/close` is not a
/// shutdown: it cancels the work, gives the open tool calls the final status `cancelled`, and
/// marks the run as ended.
///
/// Each test uses the real Router and a scripted model. The root session starts a child run
/// whose model holds, so the run works while the test ends the agent.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct OrderlyShutdownTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "OrderlyShutdownTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-SHUTDOWN-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-SHUTDOWN-MARKER"

  /// The first text of the child. The run is in operation when it is out.
  private static let childStartedText = "CHILD-STARTED-TEXT"

  /// A root session with a child run in operation.
  struct Working {
    /// The wired agent.
    let fixture: ScriptedPromptFixture

    /// The hold of the model of the child.
    let hold: ScriptedHold

    /// The id of the root session in the Router.
    let rootID: ULID

    /// The prompt of the root session. It ends when the test releases the hold.
    let promptTask: Task<Void, any Error>

    /// The directory of the Router sessions of the agent.
    var directory: RouterSessionDirectory { fixture.harness.agent.sessionDirectory }

    /// The history of the root session, as the agent retains it.
    var rootHistory: SessionMergeEngine {
      get async throws {
        try #require(await fixture.harness.agent.sessions[fixture.sessionId]).history
      }
    }

    /// The status of each `agents` call in the history of the root session, in the order of the
    /// calls.
    ///
    /// - Returns: The merged status of each call. A call with no status is not in the list.
    func agentsCallStatuses() async throws -> [FoundationModelsACP.ToolCallStatus] {
      try AgentsToolTests.agentsCalls(in: await rootHistory.transcriptUpdates).compactMap { call in
        guard case .value(let status) = call.status else {
          return nil
        }
        return status
      }
    }

    /// Waits for the end of the prompt of the root session. A failed prompt fails the test.
    ///
    /// - Throws: The error of the prompt.
    func finishPrompt() async throws {
      try await promptTask.value
    }
  }

  // MARK: - Fixtures

  /// Starts an agent whose root session has a child run in operation.
  ///
  /// - Parameter name: The label of the test, for the folders.
  /// - Returns: The working root session.
  /// - Throws: Whatever the fixture or a wait throws.
  static func startWorking(named name: String) async throws -> Working {
    let cwd = makeResolvedDirectory(label: "\(label)-\(name)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childPrompt,
        play: [.textDelta(childStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: "\(label)-\(name)", workingDirectory: cwd)
    let root = fixture.sessionId
    let promptTask = Task {
      _ = try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    }
    _ = try await fixture.collector.wait(for: "the first text of the child") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(childStartedText)
    }
    let entry = try #require(await fixture.harness.agent.sessions[root])
    return Working(
      fixture: fixture, hold: hold, rootID: entry.session.id, promptTask: promptTask)
  }

  // MARK: - The shutdown

  /// A shutdown leaves the run of the child with no ended marker.
  @Test
  func aShutdownSetsNoEndedMarkerOnTheWorkingRun() async throws {
    let working = try await Self.startWorking(named: "marker")

    await working.fixture.harness.agent.shutdown()
    working.hold.release()
    try await working.finishPrompt()
    let children = try await working.directory.recordedChildren(of: working.rootID)

    #expect(children.map(\.ended?.reason) == [nil])
  }

  /// A shutdown leaves the journal of the root with an orphaned run, so a restart can restore it.
  @Test
  func aShutdownLeavesTheRunOrphanedInTheJournal() async throws {
    let working = try await Self.startWorking(named: "orphan")

    await working.fixture.harness.agent.shutdown()
    working.hold.release()
    try await working.finishPrompt()
    let statuses = try await working.directory.runStatuses(of: working.rootID)

    #expect(Array(statuses.values) == [.orphaned])
  }

  /// A shutdown pauses the open `agents` call of the root. The history holds `paused` for it: the
  /// call is not final, so a resume restores the child.
  @Test
  func aShutdownPausesTheAgentsCallOfTheRoot() async throws {
    let working = try await Self.startWorking(named: "paused")

    await working.fixture.harness.agent.shutdown()
    working.hold.release()
    try await working.finishPrompt()

    #expect(try await working.agentsCallStatuses() == [.paused])
  }

  /// A shutdown ends the open prompt of the root as interrupted: the `idle` of the root carries
  /// the stop reason `_interrupted`, and never `cancelled`.
  @Test
  func aShutdownEndsThePromptOfTheRootAsInterrupted() async throws {
    let working = try await Self.startWorking(named: "interrupted")
    let root = working.fixture.sessionId

    await working.fixture.harness.agent.shutdown()
    working.hold.release()
    try await working.finishPrompt()
    let updates = try await working.fixture.collector.wait(for: "the idle of the root") { updates in
      updates.contains { $0.sessionId == root && $0.update.isStateUpdate }
    }
    let stopReasons = updates.compactMap { notification -> StopReason? in
      if notification.sessionId == root, case .stateUpdate(.idle(let idle)) = notification.update {
        return idle.stopReason
      }
      return nil
    }

    #expect(stopReasons == [.unknown(PromptExecution.interruptedStopReasonValue)])
  }

  /// A shutdown with no live session returns.
  @Test
  func aShutdownWithNoLiveSessionReturns() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-none")
    await fixture.close()

    await fixture.harness.agent.shutdown()

    #expect(await fixture.harness.agent.sessions.values.allSatisfy(\.isClosed))
  }

  // MARK: - The user close

  /// A user `session/close` gives the open `agents` call of the root the final status
  /// `cancelled`.
  @Test
  func aUserCloseCancelsTheAgentsCallOfTheRoot() async throws {
    let working = try await Self.startWorking(named: "closeCall")

    _ = try await working.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: working.fixture.sessionId))
    working.hold.release()
    try await working.finishPrompt()

    #expect(try await working.agentsCallStatuses() == [.cancelled])
  }

  /// A user `session/close` cancels the work and marks the run as ended with the reason
  /// cancelled.
  @Test
  func aUserCloseMarksTheRunEndedAsCancelled() async throws {
    let working = try await Self.startWorking(named: "close")

    _ = try await working.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: working.fixture.sessionId))
    working.hold.release()
    try await working.finishPrompt()
    let children = try await working.directory.recordedChildren(of: working.rootID)

    #expect(children.map(\.ended?.reason) == [.cancelled])
  }
}
