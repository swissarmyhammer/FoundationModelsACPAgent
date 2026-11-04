import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// A quit of the process pauses the open work and does not cancel it (task ^q4zy0hz).
///
/// The process closes its connection first, waits for the teardown of the connection, and only
/// then runs the orderly shutdown (``ComposedAgent/shutdownAfterConnectionTeardown()``). Each
/// test here drives that order in process: it ends the wire while a prompt of the root is open
/// and a child run works, waits for the teardown, and then shuts the agent down.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ProcessQuitShutdownTests {
  /// The two ways a process quits.
  enum Quit: CaseIterable, CustomTestStringConvertible {
    /// The client closes the standard input: the agent reads the end of its input.
    case closedInput

    /// A `SIGTERM`: the process closes its own end of the connection.
    case signal

    var testDescription: String {
      switch self {
      case .closedInput: "closed input"
      case .signal: "SIGTERM"
      }
    }
  }

  /// Ends the wire as `quit` does, waits for the teardown of the connection, and runs the
  /// shutdown.
  ///
  /// - Parameters:
  ///   - quit: How the process quits.
  ///   - working: The root session with a child run in operation.
  private static func perform(_ quit: Quit, on working: OrderlyShutdownTests.Working) async {
    let harness = working.fixture.harness
    switch quit {
    case .closedInput:
      await harness.connection.close()
    case .signal:
      await harness.agentConnection.close()
    }
    harness.wire.close()
    await harness.agent.shutdownAfterConnectionTeardown()
  }

  /// A quit with an open prompt pauses the `agents` call of the root: the history holds `paused`
  /// and no final status.
  @Test(arguments: Quit.allCases)
  func aQuitWithAnOpenPromptPausesTheAgentsCallOfTheRoot(quit: Quit) async throws {
    let working = try await OrderlyShutdownTests.startWorking(named: "quitPaused-\(quit)")

    await Self.perform(quit, on: working)
    working.hold.release()
    _ = await working.promptTask.result

    #expect(try await working.agentsCallStatuses() == [.paused])
  }

  /// A quit with an open prompt leaves the run of the child orphaned in the journal of the root,
  /// so a cold resume can restore it.
  @Test(arguments: Quit.allCases)
  func aQuitWithAnOpenPromptLeavesTheRunOrphanedInTheJournal(quit: Quit) async throws {
    let working = try await OrderlyShutdownTests.startWorking(named: "quitOrphan-\(quit)")

    await Self.perform(quit, on: working)
    working.hold.release()
    _ = await working.promptTask.result
    let statuses = try await working.directory.runStatuses(of: working.rootID)

    #expect(Array(statuses.values) == [.orphaned], "\(statuses)")
  }

  /// A quit with an open prompt does not mark the run of the child as ended.
  @Test(arguments: Quit.allCases)
  func aQuitWithAnOpenPromptSetsNoEndedMarkerOnTheWorkingRun(quit: Quit) async throws {
    let working = try await OrderlyShutdownTests.startWorking(named: "quitMarker-\(quit)")

    await Self.perform(quit, on: working)
    working.hold.release()
    _ = await working.promptTask.result
    let children = try await working.directory.recordedChildren(of: working.rootID)

    #expect(children.map(\.ended?.reason) == [nil])
  }

  // MARK: - A quit with no open prompt

  /// Waits until the prompt of the root ended: the `agents` call settled after the run grace and
  /// left the child in the background.
  ///
  /// - Parameter working: The root session with a child run in operation.
  /// - Throws: The error of the prompt.
  private static func waitForTheRootToBeIdle(_ working: OrderlyShutdownTests.Working) async throws {
    try await working.finishPrompt()
    await ScriptedPromptFixture.waitForPromptsFinished(
      working.fixture.harness.agent, working.fixture.sessionId)
  }

  /// A quit with no open prompt of the root does not mark the run of the child, which works in
  /// the background, as ended: the run grace does not cancel it.
  @Test(arguments: Quit.allCases)
  func aQuitWithNoOpenPromptSetsNoEndedMarkerOnTheBackgroundRun(quit: Quit) async throws {
    let working = try await OrderlyShutdownTests.startWorking(named: "noPrompt-\(quit)")
    try await Self.waitForTheRootToBeIdle(working)

    await Self.perform(quit, on: working)
    working.hold.release()
    let children = try await working.directory.recordedChildren(of: working.rootID)

    #expect(children.map(\.ended?.reason) == [nil])
  }
}
