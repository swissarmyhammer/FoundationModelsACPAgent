import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The final status of an `agents` call of a root when a `session/cancel` of the root stops its
/// run (task ^vp86dcd).
///
/// A `session/cancel` of the root stops each run of the root (task ^n8pcmtd). Router drops the
/// settlement of each run that the stopped answer started: a run that its call still waits for
/// (an INLINE run), and a run that its call left in the background while the answer goes on. The
/// call must then get one final `tool_call_update` with the status `cancelled` and a short reason,
/// so a client that waits for the call to close does not wait forever. A run in the background of
/// an answer that ended before the cancel keeps its settlement, as before.
///
/// Each test uses the scripted stub model and the real Router in process.
@Suite(.closesHarnesses) struct RootCancelAgentsCallTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "RootCancelAgentsCallTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-INLINE-CANCEL-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-INLINE-CANCEL-MARKER"

  /// The first text of the child. The run works when it is out.
  private static let childStartedText = "CHILD-STARTED-INLINE-CANCEL-TEXT"

  /// The marker of the prompt of the second child, which keeps the answer of the root running.
  private static let secondChildPrompt = "SECOND-INLINE-CANCEL-MARKER"

  /// The first text of the second child. Its run works when it is out.
  private static let secondChildStartedText = "SECOND-STARTED-INLINE-CANCEL-TEXT"

  /// The reason that the final status of a call of a stopped run carries.
  private static let cancelledReason = "The run was cancelled."

  /// A time far past the settle period of a run, in seconds. The run then goes to the background.
  private static let pastTheSettlePeriod = 3600

  /// The longest time that a wait for an update can take.
  private static let updateWait = Duration.seconds(30)

  /// How long a check waits for an update that must not come.
  private static let quietWindow = Duration.milliseconds(300)

  /// A root session whose `agents` call starts one child that holds.
  private struct HeldRun {
    /// The fixture.
    let fixture: ScriptedPromptFixture

    /// The id of the `agents` call of the root.
    let call: ToolCallId

    /// The root session.
    var root: SessionId { fixture.sessionId }
  }

  /// Starts one `agents` call of a root. The child holds until the test releases it.
  ///
  /// - Parameters:
  ///   - name: The label of the folders of the fixture.
  ///   - hold: The hold that each child waits on. The test releases it also when it fails, so
  ///     the close of the harness does not wait for a held child.
  ///   - clock: The clock of the settle period of the run.
  ///   - secondCall: Whether the answer of the root makes a second `agents` call after the first.
  ///     The second child holds too, so the answer of the root goes on.
  /// - Returns: The run of the first call, after the first text of its child.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startHeldRun(
    label name: String, hold: ScriptedHold, clock: ManualRunClock, secondCall: Bool = false
  ) async throws -> HeldRun {
    let cwd = makeResolvedDirectory(label: "\(label)-\(name)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let secondStart = AgentsToolTests.startAgentCall(agent: childAgent, prompt: secondChildPrompt)
    let second: [ScriptedPassStep] = secondCall ? [secondStart] : []
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childPrompt,
        play: [.textDelta(childStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: secondChildPrompt,
        play: [.textDelta(secondChildStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt)] + second
          + [.endPass]),
      .endPass,
    ]
    // The tool layers of the live loader make the Router see the run that a call waits for.
    let fixture = try await ScriptedPromptFixture.make(
      loader: makeHookLayeredModelLoader(script: script), label: "\(label)-\(name)",
      workingDirectory: cwd, runClock: clock)
    let root = fixture.sessionId
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    let updates = try await waitForUpdates(of: fixture, for: "the first text of the child") {
      ScriptedPromptFixture.agentText(in: $0.filter { $0.sessionId != root })
        .contains(childStartedText)
    }
    let call = try #require(ChildSessionProjectionTests.agentsCall(in: updates, of: root))
    return HeldRun(fixture: fixture, call: call)
  }

  /// Ends the settle period of the run.
  ///
  /// - Parameter clock: The clock of the settle period of the run.
  private static func endTheSettlePeriod(of clock: ManualRunClock) async {
    await clock.waitForSleepers(atLeast: 1)
    clock.advance(by: .seconds(pastTheSettlePeriod))
  }

  /// Ends the settle period of the run, and waits until the root lists the call as background
  /// work.
  ///
  /// - Parameters:
  ///   - run: The run.
  ///   - clock: The clock of the settle period of the run.
  /// - Throws: Whatever a wait throws.
  private static func moveToTheBackground(_ run: HeldRun, clock: ManualRunClock) async throws {
    await endTheSettlePeriod(of: clock)
    _ = try await waitForUpdates(of: run.fixture, for: "the root lists the call") {
      $0.contains { notification in
        notification.sessionId == run.root
          && BackgroundListTests.list(of: notification.update)?.contains(
            .toolCall(BackgroundToolCall(toolCallId: run.call))) == true
      }
    }
  }

  /// Ends the settle period of the first run, and waits until the second child of the root
  /// works. The first call then returned its pending envelope, and the first run goes on in the
  /// background. The second call waits for its run, so the answer of the root goes on.
  ///
  /// - Parameters:
  ///   - run: The run of the first call.
  ///   - clock: The clock of the settle period of the run.
  /// - Throws: Whatever the wait throws.
  private static func moveToTheBackgroundOfARunningAnswer(_ run: HeldRun, clock: ManualRunClock)
    async throws
  {
    await endTheSettlePeriod(of: clock)
    _ = try await waitForUpdates(of: run.fixture, for: "the first text of the second child") {
      ScriptedPromptFixture.agentText(in: $0.filter { $0.sessionId != run.root })
        .contains(secondChildStartedText)
    }
  }

  /// Releases the hold of the run, and closes its fixture.
  ///
  /// - Parameters:
  ///   - run: The run.
  ///   - hold: The hold that each child waits on.
  private static func finish(_ run: HeldRun, hold: ScriptedHold) async {
    hold.release()
    await run.fixture.close()
  }

  /// Waits, with a time limit, until `isMet` is true for the updates of a fixture.
  ///
  /// - Parameters:
  ///   - fixture: The fixture.
  ///   - condition: The name of the condition.
  ///   - isMet: Tells if the condition is true for the updates.
  /// - Returns: The first updates for which `isMet` is true.
  /// - Throws: ``ConditionWaitCancelled`` when the time limit came first.
  private static func waitForUpdates(
    of fixture: ScriptedPromptFixture, for condition: String,
    until isMet: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
  ) async throws -> [UpdateSessionNotification] {
    try await bounded(by: updateWait) {
      try await fixture.collector.wait(for: condition, until: isMet)
    }
  }

  /// Cancels the root, waits for the first final status of the call, and then for a quiet window.
  ///
  /// - Parameter run: The run.
  /// - Returns: The updates of the call on the root that carry a final status, in wire order.
  /// - Throws: Whatever the cancel or a wait throws.
  private static func finalUpdatesAfterRootCancel(of run: HeldRun) async throws
    -> [ToolCallUpdate]
  {
    try await run.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: run.root))
    _ = try await waitForUpdates(of: run.fixture, for: "the final status of the agents call") {
      $0.contains { isFinal($0, of: run) }
    }
    try await Task.sleep(for: quietWindow)
    return await run.fixture.collector.updates.compactMap { notification in
      guard isFinal(notification, of: run), case .toolCallUpdate(let call) = notification.update
      else {
        return nil
      }
      return call
    }
  }

  /// Whether a notification is on the root and gives a final status to the `agents` call.
  ///
  /// - Parameters:
  ///   - notification: The notification.
  ///   - run: The run.
  /// - Returns: `true` for a final status of the call.
  private static func isFinal(_ notification: UpdateSessionNotification, of run: HeldRun) -> Bool {
    notification.sessionId == run.root
      && ChildSessionProjectionTests.isFinal(notification.update, of: run.call)
  }

  /// The text items of the last update of the `agents` call on the root that sets the content of
  /// the call. The hold of an `agents` call sends the content at once and the final status after
  /// the end of the child, so the reason and the status can come in two updates.
  ///
  /// - Parameters:
  ///   - run: The run.
  ///   - updates: The notifications.
  /// - Returns: The text items, or an empty list when no update set the content.
  private static func lastContentTexts(
    of run: HeldRun, in updates: [UpdateSessionNotification]
  ) -> [String] {
    let contents = updates.compactMap { notification -> [String]? in
      guard notification.sessionId == run.root,
        case .toolCallUpdate(let call) = notification.update,
        call.toolCallId == run.call, call.content != .unchanged
      else {
        return nil
      }
      return texts(in: call.content)
    }
    return contents.last ?? []
  }

  /// The statuses of tool-call updates.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The status of each update, or `nil` for an update with no status.
  private static func statuses(of updates: [ToolCallUpdate]) -> [ToolCallStatus?] {
    updates.map { update in
      if case .value(let status) = update.status { return status }
      return nil
    }
  }

  // MARK: - An inline run

  /// A root cancel while the run of the call is inline gives the call one final status:
  /// `cancelled`.
  @Test
  func aRootCancelGivesAnInlineAgentsCallOneCancelledFinalStatus() async throws {
    let hold = ScriptedHold()
    defer { hold.release() }
    let run = try await Self.startHeldRun(
      label: "inline-status", hold: hold, clock: ManualRunClock())

    let finals = try await Self.finalUpdatesAfterRootCancel(of: run)

    #expect(Self.statuses(of: finals) == [.cancelled])
    await Self.finish(run, hold: hold)
  }

  /// The final status of an inline call that a root cancel stopped tells the reason.
  @Test
  func theFinalStatusOfAnInlineAgentsCallTellsTheCancel() async throws {
    let hold = ScriptedHold()
    defer { hold.release() }
    let run = try await Self.startHeldRun(
      label: "inline-reason", hold: hold, clock: ManualRunClock())

    _ = try await Self.finalUpdatesAfterRootCancel(of: run)
    let updates = await run.fixture.collector.updates

    #expect(Self.lastContentTexts(of: run, in: updates).contains(Self.cancelledReason))
    await Self.finish(run, hold: hold)
  }

  // MARK: - A background run of an answer that goes on

  /// A root cancel while the run is in the background and the answer that started it goes on
  /// gives the call one final status: `cancelled`.
  @Test
  func aRootCancelGivesABackgroundAgentsCallOfARunningAnswerOneCancelledFinalStatus()
    async throws
  {
    let clock = ManualRunClock()
    let hold = ScriptedHold()
    defer { hold.release() }
    let run = try await Self.startHeldRun(
      label: "background-running", hold: hold, clock: clock, secondCall: true)
    try await Self.moveToTheBackgroundOfARunningAnswer(run, clock: clock)

    let finals = try await Self.finalUpdatesAfterRootCancel(of: run)

    #expect(Self.statuses(of: finals) == [.cancelled])
    await Self.finish(run, hold: hold)
  }

  /// The final status of a background call of a running answer that a root cancel stopped tells
  /// the reason.
  @Test
  func theFinalStatusOfABackgroundAgentsCallOfARunningAnswerTellsTheCancel() async throws {
    let clock = ManualRunClock()
    let hold = ScriptedHold()
    defer { hold.release() }
    let run = try await Self.startHeldRun(
      label: "background-reason", hold: hold, clock: clock, secondCall: true)
    try await Self.moveToTheBackgroundOfARunningAnswer(run, clock: clock)

    _ = try await Self.finalUpdatesAfterRootCancel(of: run)
    let updates = await run.fixture.collector.updates

    #expect(Self.lastContentTexts(of: run, in: updates).contains(Self.cancelledReason))
    await Self.finish(run, hold: hold)
  }

  // MARK: - A background run of an answer that ended

  /// A root cancel after the answer ended and its run went to the background keeps the
  /// settlement of the run: the call gets one final status, `completed`, as before.
  @Test
  func aRootCancelKeepsTheSettlementOfABackgroundAgentsCallOfAnEndedAnswer() async throws {
    let clock = ManualRunClock()
    let hold = ScriptedHold()
    defer { hold.release() }
    let run = try await Self.startHeldRun(
      label: "background-ended", hold: hold, clock: clock)
    try await Self.moveToTheBackground(run, clock: clock)
    // The prompt of the root ends before the cancel, so its answer ended in Router too.
    await run.fixture.harness.agent.awaitPromptsFinished(of: run.root)

    let finals = try await Self.finalUpdatesAfterRootCancel(of: run)

    #expect(Self.statuses(of: finals) == [.completed])
    await Self.finish(run, hold: hold)
  }
}
