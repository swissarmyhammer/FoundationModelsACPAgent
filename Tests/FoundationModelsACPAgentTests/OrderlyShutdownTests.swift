import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// An orderly shutdown of the process leaves a working nested run restorable. A user
/// `session/close` is not a shutdown: it cancels the work and marks the run as ended.
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
  private struct Working {
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
  private static func startWorking(named name: String) async throws -> Working {
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
