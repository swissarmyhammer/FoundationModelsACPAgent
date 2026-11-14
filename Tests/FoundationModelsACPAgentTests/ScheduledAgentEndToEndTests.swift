import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A scheduled agent from end to end, through the ACP surface (task ^ybpc6ap). The client drives
/// the agent over the wire with the scripted model: the model of the root session calls the
/// `agents` tool with `schedule agent`, and the test reads only what the client sees. No test
/// calls the runner of FoundationModelsAgents.
///
/// Each schedule is one ISO date and time a few seconds after the `schedule agent` call, the
/// shortest schedule that the tool takes (an interval is 1 minute at least). The call reads its
/// arguments from a file that the test writes when the pass of the root reached the call, so a
/// slow pass under load cannot put the time in the past before the tool reads it. The firing run plays its first text,
/// holds until the test releases it, and plays its result text. The scheduler mails the report of
/// the run to the root session, and the client sees that mail as a `session_message` of the root.
///
/// Every wait is bounded by ``waitBound``, and the suite by its time limit.
@Suite(.closesHarnesses, .timeLimit(.minutes(1))) struct ScheduledAgentEndToEndTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ScheduledAgentEndToEndTests"

  /// The agent that each firing runs.
  private static let scheduledAgent = "ticker"

  /// The name of the scheduled task. A name that the creator gives keeps the prompt of the
  /// firing out of the mail header, so the mail of a firing never plays the firing branch.
  private static let taskTitle = "end-to-end ticker"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-SCHEDULES-A-TICKER"

  /// The marker of the prompt of each firing.
  private static let firingPrompt = "FIRING-OF-THE-TICKER"

  /// The first text of a firing, before its hold.
  private static let heldText = "FIRING-HELD-TEXT"

  /// The result text of a firing, after its hold. The report of the run holds it.
  private static let resultText = "FIRING-RESULT-TEXT"

  /// How long after the write of the arguments of the call the task fires. It leaves the prompt
  /// time to end first, so the session has no work before the firing.
  private static let leadTime: TimeInterval = 5

  /// How late a firing may start after its time.
  private static let firingLateness: TimeInterval = 10

  /// The longest wait for one condition on the wire.
  private static let waitBound = Duration.seconds(20)

  /// The format of the schedule text: an ISO 8601 date and time in UTC, to the second.
  private static let scheduleFormat = Date.ISO8601FormatStyle()

  /// A root session whose prompt scheduled the agent.
  private struct Scheduled {
    /// The fixture of the agent.
    let fixture: ScriptedPromptFixture

    /// The hold of each firing.
    let hold: ScriptedHold

    /// The time that the task fires, as the schedule text gives it.
    let fireDate: Date

    /// The file that saves the scheduled agents of the root.
    let savedSchedule: URL

    /// The root session.
    var root: SessionId { fixture.sessionId }
  }

  /// The two files of the `schedule agent` call of the root prompt.
  private struct CallFiles {
    /// The file that the pass of the root writes when it reached the call. It exists, empty,
    /// before the prompt.
    let reached: URL

    /// The file of the arguments of the call. The test writes it.
    let arguments: URL

    /// Makes the two paths in a new folder, and the empty file of the reach.
    ///
    /// - Returns: The files.
    /// - Throws: The error of the write of the empty file.
    static func make() throws -> CallFiles {
      let folder = makeResolvedDirectory(label: "\(label)-call")
      let files = CallFiles(
        reached: folder.appendingPathComponent("reached"),
        arguments: folder.appendingPathComponent("schedule-agent.json"))
      try Data().write(to: files.reached)
      return files
    }
  }

  // MARK: - Fixtures

  /// The script of each agent of the suite: a firing plays its text, its hold and its result; the
  /// root prompt schedules the agent when the script has the call files; a mail to the root ends
  /// the pass.
  ///
  /// - Parameters:
  ///   - hold: The hold of each firing.
  ///   - call: The files of the `schedule agent` call of the root prompt, or `nil` for an agent
  ///     that only resumes the root and runs its firings.
  /// - Returns: The script.
  private static func script(hold: ScriptedHold, call: CallFiles? = nil) -> [ScriptedPassStep] {
    let firing = ScriptedPassStep.onPrompt(
      containing: firingPrompt,
      play: [.textDelta(heldText), .holdUntilReleased(hold), .textDelta(resultText), .endPass])
    guard let call else {
      return [firing, .endPass]
    }
    let schedule: [ScriptedPassStep] = [
      .writeFile(path: call.reached.path, text: rootPrompt),
      .toolCallFromFile(name: AgentsToolTests.agentsToolName, path: call.arguments.path),
      .endPass,
    ]
    return [firing, .onPrompt(containing: rootPrompt, play: schedule), .endPass]
  }

  /// Waits until the pass of the root reached the call, and writes the arguments of the call with
  /// a schedule ``leadTime`` from now.
  ///
  /// - Parameter call: The files of the call.
  /// - Returns: The time that the task fires, as the schedule text gives it.
  /// - Throws: ``ConditionWaitCancelled`` when the pass does not reach the call in time, or the
  ///   error of the write.
  private static func writeScheduleCall(_ call: CallFiles) async throws -> Date {
    let reached = call.reached
    try await bounded {
      try await FileWriteWatch.wait(on: reached, for: "the pass of the root reached the call") {
        (try? Data(contentsOf: reached).isEmpty == false) ?? false
      }
    }
    let schedule = scheduleFormat.format(Date().addingTimeInterval(leadTime))
    let arguments = #"""
      {"op":"schedule agent","agent":"\#(scheduledAgent)","schedule":"\#(schedule)",\#
      "prompt":"\#(firingPrompt)","title":"\#(taskTitle)"}
      """#
    try arguments.write(to: call.arguments, atomically: true, encoding: .utf8)
    return try scheduleFormat.parse(schedule)
  }

  /// Opens a root session over a working directory with the scheduled agent, sends the prompt
  /// that schedules it, and waits until the root says no work: the prompt ended, and a pending
  /// task holds no work. That comes before the task fires.
  ///
  /// - Parameter holdsFiring: Whether each firing holds until the test releases the hold.
  /// - Returns: The scheduled root session.
  /// - Throws: Whatever the fixture or the prompt throws.
  private static func makeScheduled(holdsFiring: Bool = false) async throws -> Scheduled {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: scheduledAgent, in: cwd)
    let hold = ScriptedHold()
    if !holdsFiring {
      hold.release()
    }
    let call = try CallFiles.make()
    let fixture = try await ScriptedPromptFixture.make(
      script: script(hold: hold, call: call), label: label, workingDirectory: cwd)
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    let owner = try #require(ULID(ulidString: fixture.sessionId.rawValue))
    let saved = ScheduleFileStore.file(
      of: owner, in: entry.transcriptDirectory.deletingLastPathComponent())
    let root = fixture.sessionId
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    let fireDate = try await writeScheduleCall(call)
    _ = try await wait(for: "the end of the work of the prompt", in: fixture.collector) {
      lastStateSaysNoWork(of: root, in: $0)
    }
    return Scheduled(fixture: fixture, hold: hold, fireDate: fireDate, savedSchedule: saved)
  }

  /// Resumes the root of `scheduled` in a second agent over the same working directory, with no
  /// replay. The model of the second agent plays the firings with the same hold.
  ///
  /// - Parameter scheduled: The scheduled root, whose first agent stopped.
  /// - Returns: The second agent.
  /// - Throws: Whatever the fixture or the resume throws.
  private static func resume(_ scheduled: Scheduled) async throws -> ScriptedPromptFixture {
    let cwd = scheduled.fixture.cwd
    let second = try await ScriptedPromptFixture.make(
      script: script(hold: scheduled.hold), label: "\(label)-second",
      workingDirectory: cwd)
    _ = try await second.harness.connection.resumeSession(
      ResumeSessionRequest(cwd: AbsolutePath(rawValue: cwd.path), sessionId: scheduled.root))
    return second
  }

  // MARK: - Waits

  /// Runs the wait `body`, and cancels it when it did not end after ``waitBound``.
  ///
  /// - Parameter body: The wait. A cancel ends it with an error.
  /// - Returns: The value of `body`.
  /// - Throws: The error of `body`, for example ``ConditionWaitCancelled`` after the bound.
  @discardableResult
  private static func bounded<Value: Sendable>(
    _ body: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let work = Task { try await body() }
    let limit = Task {
      do {
        try await Task.sleep(for: waitBound)
        work.cancel()
      } catch {
        // The sleep throws only when the wait ended in time and cancelled the limit.
        return
      }
    }
    defer { limit.cancel() }
    return try await work.value
  }

  /// Waits until `isMet` accepts the updates of `collector`, for at most ``waitBound``.
  ///
  /// - Parameters:
  ///   - condition: The name of the condition, for the error of a wait that does not end.
  ///   - collector: The collector of the agent.
  ///   - isMet: Tells if the condition is true for the updates.
  /// - Returns: The first updates that `isMet` accepts.
  /// - Throws: ``ConditionWaitCancelled`` when the bound comes first.
  private static func wait(
    for condition: String, in collector: UpdateCollector,
    until isMet: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
  ) async throws -> [UpdateSessionNotification] {
    try await bounded { try await collector.wait(for: condition, until: isMet) }
  }

  /// Waits until a firing played its first text on a session other than `root`, and gives the
  /// time that the client first saw it.
  ///
  /// - Parameters:
  ///   - root: The root session.
  ///   - collector: The collector of the agent.
  /// - Returns: The time of the first text of the firing.
  /// - Throws: ``ConditionWaitCancelled`` when no firing starts in time.
  private static func waitForFiring(
    of root: SessionId, in collector: UpdateCollector
  ) async throws -> Date {
    let seen = WatchedValue<Date?>(nil)
    _ = try await wait(for: "the first text of the firing", in: collector) { updates in
      let fired = ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(heldText)
      if fired {
        seen.update { $0 = $0 ?? Date() }
      }
      return fired
    }
    return try #require(seen.value)
  }

  /// The `session_message` updates of `root` that hold the result text of a firing.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - root: The root session.
  /// - Returns: The messages, in wire order.
  private static func resultMessages(
    in updates: [UpdateSessionNotification], of root: SessionId
  ) -> [FoundationModelsACP.SessionMessage] {
    updates.filter { $0.sessionId == root }.compactMap(\.update.sessionMessagePayload)
      .filter { $0.firstText?.contains(resultText) ?? false }
  }

  /// Waits until the result of a firing reached `root` as a `session_message`.
  ///
  /// - Parameters:
  ///   - root: The root session.
  ///   - collector: The collector of the agent.
  /// - Returns: The messages of the result.
  /// - Throws: ``ConditionWaitCancelled`` when no result comes in time.
  private static func waitForResult(
    of root: SessionId, in collector: UpdateCollector
  ) async throws -> [FoundationModelsACP.SessionMessage] {
    let updates = try await wait(for: "the result message of the firing", in: collector) {
      !resultMessages(in: $0, of: root).isEmpty
    }
    return resultMessages(in: updates, of: root)
  }

  /// Whether the last own `state_update` of `session` is an `idle` that says no work.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - updates: The notifications.
  /// - Returns: `true` when the last state of `session` says no work.
  private static func lastStateSaysNoWork(
    of session: SessionId, in updates: [UpdateSessionNotification]
  ) -> Bool {
    let last = updates.last { notification in
      guard notification.sessionId == session, case .stateUpdate = notification.update else {
        return false
      }
      return true
    }
    return idleState(of: last?.update)?.saysNoWork ?? false
  }

  /// Waits until the last own state of `root` is not an `idle` that says no work.
  ///
  /// - Parameters:
  ///   - root: The root session.
  ///   - collector: The collector of the agent.
  /// - Returns: The updates at that point.
  /// - Throws: ``ConditionWaitCancelled`` when the root stays with no work.
  private static func waitForWork(
    of root: SessionId, in collector: UpdateCollector
  ) async throws -> [UpdateSessionNotification] {
    try await wait(for: "a state of the root with work", in: collector) {
      !lastStateSaysNoWork(of: root, in: $0)
    }
  }

  // MARK: - Schedule and fire

  /// The `schedule agent` call of the root completes. The first update of the call names the
  /// tool, and a later update of the same call id gives its final status.
  @Test func theScheduleAgentCallOfTheRootCompletes() async throws {
    let scheduled = try await Self.makeScheduled()
    let root = scheduled.root
    let rootUpdates = await scheduled.fixture.collector.updates.filter { $0.sessionId == root }.map(\.update)
    let call = try #require(AgentsToolTests.agentsCalls(in: rootUpdates).first)

    let statuses = rootUpdates.compactMap { update -> PatchField<FoundationModelsACP.ToolCallStatus>? in
      guard case .toolCallUpdate(let patch) = update, patch.toolCallId == call.toolCallId else {
        return nil
      }
      return patch.status
    }

    #expect(statuses.contains(.value(.completed)))
    await scheduled.fixture.close()
  }

  /// The task fires at its time: not before it, and soon after it.
  @Test func theScheduledAgentFiresAtItsTime() async throws {
    let scheduled = try await Self.makeScheduled()

    let firedAt = try await Self.waitForFiring(
      of: scheduled.root, in: scheduled.fixture.collector)

    #expect(firedAt >= scheduled.fireDate)
    #expect(firedAt.timeIntervalSince(scheduled.fireDate) < Self.firingLateness)
    await scheduled.fixture.close()
  }

  /// The result of the firing reaches the root session as a `session_message`.
  @Test func theResultOfTheFiringReachesTheRootAsAMessage() async throws {
    let scheduled = try await Self.makeScheduled()

    let messages = try await Self.waitForResult(
      of: scheduled.root, in: scheduled.fixture.collector)

    #expect(messages.contains { $0.recipientSessionId == .value(scheduled.root) })
    await scheduled.fixture.close()
  }

  // MARK: - The work state of the root

  /// While the firing runs, the root is out of the no-work state: the lease of the firing holds
  /// work in the root.
  @Test func aFiringHoldsTheRootOutOfTheNoWorkState() async throws {
    let scheduled = try await Self.makeScheduled(holdsFiring: true)
    let collector = scheduled.fixture.collector
    _ = try await Self.waitForFiring(of: scheduled.root, in: collector)

    let updates = try await Self.waitForWork(of: scheduled.root, in: collector)

    #expect(!Self.lastStateSaysNoWork(of: scheduled.root, in: updates))
    scheduled.hold.release()
    await scheduled.fixture.close()
  }

  /// When the firing ends and its result is in, the root says no work again: the lease ended.
  @Test func theRootSaysNoWorkAgainWhenTheFiringEnds() async throws {
    let scheduled = try await Self.makeScheduled(holdsFiring: true)
    let root = scheduled.root
    let collector = scheduled.fixture.collector
    _ = try await Self.waitForFiring(of: root, in: collector)
    _ = try await Self.waitForWork(of: root, in: collector)
    scheduled.hold.release()

    let updates = try await Self.wait(for: "the no-work idle after the firing", in: collector) {
      !Self.resultMessages(in: $0, of: root).isEmpty && Self.lastStateSaysNoWork(of: root, in: $0)
    }

    #expect(Self.lastStateSaysNoWork(of: root, in: updates))
    await scheduled.fixture.close()
  }

  // MARK: - A cancel

  /// A `session/cancel` of the root before the firing keeps the schedule: the task still fires,
  /// and its result reaches the root.
  @Test func aCancelOfTheRootKeepsTheScheduleAndItFires() async throws {
    let scheduled = try await Self.makeScheduled()

    try await scheduled.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: scheduled.root))
    try #require(Date() < scheduled.fireDate, "the cancel came after the time of the firing")
    let messages = try await Self.waitForResult(
      of: scheduled.root, in: scheduled.fixture.collector)

    #expect(!messages.isEmpty)
    await scheduled.fixture.close()
  }

  // MARK: - A cold resume

  /// After an orderly shutdown of the first agent, a cold resume of the root in a second agent
  /// restores the schedule, and the task fires: its result reaches the resumed root.
  @Test func aScheduleSurvivesAShutdownAndAColdResumeAndFires() async throws {
    let scheduled = try await Self.makeScheduled()
    await scheduled.fixture.harness.agent.shutdown()
    await scheduled.fixture.harness.close()

    let second = try await Self.resume(scheduled)
    let messages = try await Self.waitForResult(of: scheduled.root, in: second.collector)

    #expect(!messages.isEmpty)
    await second.close()
  }

  /// A firing of a schedule that a cold resume restored holds the resumed root out of the
  /// no-work state while it runs (the lease of ``RoutedACPAgent/scheduledAgentWorkSite(of:)``).
  @Test func aRestoredFiringHoldsTheResumedRootOutOfTheNoWorkState() async throws {
    let scheduled = try await Self.makeScheduled(holdsFiring: true)
    await scheduled.fixture.harness.agent.shutdown()
    await scheduled.fixture.harness.close()
    let second = try await Self.resume(scheduled)
    _ = try await Self.waitForFiring(of: scheduled.root, in: second.collector)

    let updates = try await Self.waitForWork(of: scheduled.root, in: second.collector)

    #expect(!Self.lastStateSaysNoWork(of: scheduled.root, in: updates))
    scheduled.hold.release()
    await second.close()
  }

  /// After a user `session/close` of the root, a cold resume of the root in a second agent
  /// restores the schedule, and the task fires: its result reaches the resumed root.
  ///
  /// A known issue of FoundationModelsAgents: `AgentRunner.cancelRuns(caller:)`, which the close
  /// of a session calls, ends each scheduled agent of the caller (`AgentScheduler.endTasks`) and
  /// saves an empty list, so `ScheduleFileStore` removes `schedules.json`. The resume then has no
  /// schedule to restore. The check of the file fails at once, so the test does not wait for a
  /// firing that cannot come.
  @Test func aScheduleSurvivesACloseAndAColdResumeAndFires() async throws {
    let scheduled = try await Self.makeScheduled()
    _ = try await scheduled.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: scheduled.root))
    await scheduled.fixture.close()

    await withKnownIssue(
      "FoundationModelsAgents: a session close ends the scheduled agents of the session"
    ) {
      try #require(
        FileManager.default.fileExists(atPath: scheduled.savedSchedule.path),
        "the close removed the saved schedule of the root")
      let second = try await Self.resume(scheduled)
      let messages = try await Self.waitForResult(of: scheduled.root, in: second.collector)

      #expect(!messages.isEmpty)
      await second.close()
    }
  }
}
