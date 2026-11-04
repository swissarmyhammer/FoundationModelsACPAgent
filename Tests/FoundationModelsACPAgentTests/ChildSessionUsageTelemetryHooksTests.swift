import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsHooks
import FoundationModelsRouter
import MetricsTestKit
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPAgent

/// A child session is an ordinary session with a parent. It takes part in usage, hooks and the
/// snapshot timeline by the same rules as a root session. These tests show the rules for the
/// child: its usage goes out under its own session id and holds no cost, its hooks have the key
/// of its root, and its snapshot key is the key of its folder.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildSessionUsageTelemetryHooksTests {
  // MARK: - Constants

  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildSessionUsageTelemetryHooksTests"

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-USAGE-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-USAGE-MARKER"

  /// The first text of the child. The child holds after it.
  private static let startedText = "CHILD-USAGE-STARTED"

  /// The context window of the sessions in the usage tests, in tokens.
  private static let windowTokens = 1_000

  /// The fed tokens of the one call of the child.
  private static let childTokensIn = 300

  /// The generated tokens of the one call of the child.
  private static let childTokensOut = 50

  /// The fed tokens of the one call of the parent.
  private static let parentTokensIn = 100

  /// The generated tokens of the one call of the parent.
  private static let parentTokensOut = 20

  // MARK: - Usage fixtures

  /// The events of one submission: the report of its one generation call and its end.
  ///
  /// - Parameters:
  ///   - tokensIn: The fed tokens of the call.
  ///   - tokensOut: The generated tokens of the call.
  /// - Returns: The events.
  private static func submission(tokensIn: Int, tokensOut: Int) -> [SessionEvent] {
    let fill = Double(tokensIn + tokensOut) / Double(windowTokens)
    return [
      .generationCall(
        GenerationCallUsage(
          tokensIn: tokensIn, tokensOut: tokensOut, finishReason: .completed, entryKind: .text,
          contextFill: fill)),
      makeSubmissionEnded(TokenUsage(tokensIn: tokensIn, tokensOut: tokensOut, contextFill: fill)),
    ]
  }

  /// Runs a session that has no prompt, as the run of a child does, and ends it as the end of
  /// a run does.
  ///
  /// - Parameter events: The events of the session, in order.
  /// - Returns: The updates that the session sent.
  private static func updatesOfARun(_ events: [SessionEvent]) async -> [SessionUpdate] {
    let recorder = SinkRecorder()
    let projector = SessionProjector(
      sessionId: SessionId(rawValue: syntheticSessionIdValue), modelName: syntheticModelName,
      send: { update in await recorder.append(update) }, relay: nil,
      runCallJoins: RunCallJoinTable())
    let (outputs, input) = AsyncStream.makeStream(of: SessionOutput.self)
    let source = SessionProjector.Source(id: ULID.generate(), session: nil)
    await projector.attach(outputs, from: source)
    let origin = Origin.mail([MailID()])
    for event in events {
      input.yield(SessionOutput(origin: origin, event: event))
    }
    input.finish()
    await projector.end(with: IdleStateUpdate(stopReason: .endTurn))
    await projector.stop(after: [source.id])
    return await recorder.updates
  }

  /// The usage updates among some updates.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The usage updates, in order.
  private static func usageUpdates(in updates: [SessionUpdate]) -> [UsageUpdate] {
    updates.compactMap { update in
      if case .usageUpdate(let usage) = update { return usage }
      return nil
    }
  }

  // MARK: - Usage

  /// A session that has no prompt reports the context of its own session when its run ends.
  @Test
  func aRunWithNoPromptReportsTheContextOfItsOwnSession() async throws {
    let updates = await Self.updatesOfARun(
      Self.submission(tokensIn: Self.childTokensIn, tokensOut: Self.childTokensOut))

    let usage = try #require(Self.usageUpdates(in: updates).first)

    #expect(usage.used == Self.childTokensIn + Self.childTokensOut)
  }

  /// The window of the usage update of a run is the window that its calls measured.
  @Test
  func theUsageOfARunHasTheWindowThatItsCallsMeasured() async throws {
    let updates = await Self.updatesOfARun(
      Self.submission(tokensIn: Self.childTokensIn, tokensOut: Self.childTokensOut))

    let usage = try #require(Self.usageUpdates(in: updates).first)

    #expect(usage.size == Self.windowTokens)
  }

  /// The usage update of a child holds no cost: the cost of a child is unknown, not zero.
  @Test
  func theUsageOfARunHoldsNoCost() async throws {
    let updates = await Self.updatesOfARun(
      Self.submission(tokensIn: Self.childTokensIn, tokensOut: Self.childTokensOut))

    let usage = try #require(Self.usageUpdates(in: updates).first)

    #expect(usage.cost == .unchanged)
  }

  /// A run that made no call report has no window, so it sends no meter.
  @Test
  func aRunWithNoCallReportSendsNoUsage() async {
    let updates = await Self.updatesOfARun([
      makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan))
    ])

    #expect(Self.usageUpdates(in: updates).isEmpty)
  }

  /// A run reports the context that its last submission left, not the sum of its submissions.
  @Test
  func theUsageOfARunIsTheContextOfItsLastSubmission() async throws {
    let updates = await Self.updatesOfARun(
      Self.submission(tokensIn: Self.parentTokensIn, tokensOut: Self.parentTokensOut)
        + Self.submission(tokensIn: Self.childTokensIn, tokensOut: Self.childTokensOut))

    let usage = try #require(Self.usageUpdates(in: updates).first)

    #expect(usage.used == Self.childTokensIn + Self.childTokensOut)
  }

  /// The usage of a parent prompt holds no token of a child.
  @Test
  func theUsageOfTheParentPromptHoldsNoTokenOfTheChild() async throws {
    let child = await Self.updatesOfARun(
      Self.submission(tokensIn: Self.childTokensIn, tokensOut: Self.childTokensOut))
    try #require(Self.usageUpdates(in: child).count == 1)

    let parent = await SyntheticPrompt.sentUpdates(
      Self.submission(tokensIn: Self.parentTokensIn, tokensOut: Self.parentTokensOut))

    let usage = try #require(Self.usageUpdates(in: parent).first)
    #expect(usage.used == Self.parentTokensIn + Self.parentTokensOut)
  }

  // MARK: - Fixtures with a live child

  /// A root session with a child that holds in its model, and a recorder of the hooks.
  private struct LiveChild {
    /// The fixture.
    let fixture: ScriptedPromptFixture

    /// The id of the child.
    let child: SessionId

    /// The hold that keeps the child alive.
    let hold: ScriptedHold

    /// The prompt of the root, which ends after the child.
    let prompt: Task<Void, any Error>

    /// The recorder of the hook events.
    let recorder: RecordingHookVisitor

    /// The root session.
    var root: SessionId { fixture.sessionId }

    /// The key of the folder of the root.
    var folderKey: String { AgentHome.projectKey(of: fixture.cwd) }

    /// The `SessionStart` events that the recorder got for one session, after the hook queue
    /// drained.
    ///
    /// - Parameter session: The session.
    /// - Returns: The events.
    func starts(of session: SessionId) async -> [RecordedHookEvent] {
      await fixture.harness.agent.hooks.dispatcher.drain()
      return recorder.events.value.filter {
        $0.isSessionStart && $0.session.sessionID == session.rawValue
      }
    }

    /// Lets the child end, and waits for the final status of the `agents` call. The child
    /// retires before that status goes out.
    func finish() async throws {
      hold.release()
      try await prompt.value
      let root = root
      _ = try await fixture.collector.wait(for: "the final status of the agents call") { updates in
        guard let call = ChildSessionProjectionTests.agentsCall(in: updates, of: root)
        else { return false }
        return updates.contains {
          $0.sessionId == root && ChildSessionProjectionTests.isFinal($0.update, of: call)
        }
      }
    }
  }

  /// Starts a root session whose child holds after its first text.
  ///
  /// - Parameter tracer: The tracer of the agent, or `nil` for none.
  /// - Returns: The root and the live child.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startLiveChild(tracer: (any Tracer)? = nil) async throws -> LiveChild {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childPrompt,
        play: [.textDelta(startedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass]),
      .endPass,
    ]
    let recorder = RecordingHookVisitor()
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd, tracer: tracer, hookVisitors: [recorder])
    let root = fixture.sessionId
    let prompt = Task {
      _ = try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    }
    let updates = try await fixture.collector.wait(for: "the first text of the child") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(startedText)
    }
    let child = try #require(AnnouncedChild.first(in: updates, on: root))
    return LiveChild(fixture: fixture, child: child, hold: hold, prompt: prompt, recorder: recorder)
  }

  // MARK: - Hooks

  /// The `SessionStart` of a child has the origin of a sub-agent.
  @Test
  func aChildStartsItsHooksWithTheOriginOfASubagent() async throws {
    let run = try await Self.startLiveChild()

    let starts = await run.starts(of: run.child)

    #expect(starts.map(\.kind) == [.sessionStart(.subagent)])
    try await run.finish()
    await run.fixture.close()
  }

  /// The hooks of a child have the key of the folder of its root, so the root and the child
  /// share one snapshot timeline.
  @Test
  func theHooksOfAChildHaveTheKeyOfTheFolderOfItsRoot() async throws {
    let run = try await Self.startLiveChild()

    let starts = await run.starts(of: run.child)

    #expect(starts.map(\.session.sessionKey) == [run.folderKey])
    try await run.finish()
    await run.fixture.close()
  }

  /// The hooks of a child name the root as its parent and as its root.
  @Test
  func theHooksOfAChildNameTheirParentAndRoot() async throws {
    let run = try await Self.startLiveChild()

    let starts = await run.starts(of: run.child)

    #expect(starts.map(\.session.parentSessionID) == [run.root.rawValue])
    #expect(starts.map(\.session.rootSessionID) == [run.root.rawValue])
    try await run.finish()
    await run.fixture.close()
  }

  // MARK: - The snapshot timeline

  /// A live child has the snapshot key of its folder, as its root has, so the `snapshots` tool
  /// of the child reads the one timeline.
  @Test
  func aLiveChildHasTheSnapshotKeyOfItsFolder() async throws {
    let run = try await Self.startLiveChild()

    let key = SnapshotSessionKeys.shared.sessionKey(of: run.child.rawValue)

    #expect(key == run.folderKey)
    try await run.finish()
    await run.fixture.close()
  }

  /// A child that ended leaves no snapshot key behind.
  @Test
  func aChildThatEndedLeavesNoSnapshotKey() async throws {
    let run = try await Self.startLiveChild()
    try await run.finish()

    let key = SnapshotSessionKeys.shared.sessionKey(of: run.child.rawValue)

    #expect(key == nil)
    await run.fixture.close()
  }

  /// A delete of the root removes the snapshot key of its live child with the child.
  @Test
  func aDeleteOfTheRootLeavesNoSnapshotKeyOfItsChild() async throws {
    let run = try await Self.startLiveChild()

    _ = try await run.fixture.harness.connection.deleteSession(
      DeleteSessionRequest(sessionId: run.root))

    #expect(SnapshotSessionKeys.shared.sessionKey(of: run.child.rawValue) == nil)
    run.hold.release()
    _ = try? await run.prompt.value
    await run.fixture.close()
  }

  /// A delete of the root leaves the table with no entry of the child.
  @Test
  func aDeleteOfTheRootLeavesNoEntryOfItsChild() async throws {
    let run = try await Self.startLiveChild()

    _ = try await run.fixture.harness.connection.deleteSession(
      DeleteSessionRequest(sessionId: run.root))

    #expect(await run.fixture.harness.agent.sessions[run.child] == nil)
    run.hold.release()
    _ = try? await run.prompt.value
    await run.fixture.close()
  }

  // MARK: - Telemetry

  /// The id of a child in the telemetry tests.
  private static let telemetryChild = SessionId(rawValue: "01M6J4CHILD0000000000000000")

  /// The id of the parent of the child in the telemetry tests.
  private static let telemetryParent = SessionId(rawValue: "01M6J4PARENT000000000000000")

  /// The record that the translator writes for an answer that holds no text.
  private static let unsentEventMessage = "The translator sends nothing for a Router event."

  /// The key of the parent session id has the name that Router uses.
  @Test
  func theKeyOfTheParentSessionIdIsTheKeyOfTheRouter() {
    #expect(ACPAgentTelemetry.AttributeKey.parentSessionId == "session.parent_id")
  }

  /// A record about a child holds the id of its parent.
  @Test
  func aRecordOfAChildHoldsTheIdOfItsParent() {
    let metadata = ACPAgentTelemetry.sessionMetadata(
      Self.telemetryChild, parent: Self.telemetryParent)

    #expect(
      metadata[ACPAgentTelemetry.LogMetadataKey.parentSessionId]
        == "\(Self.telemetryParent.rawValue)")
  }

  /// A record about a child holds the id of the child.
  @Test
  func aRecordOfAChildHoldsItsOwnSessionId() {
    let metadata = ACPAgentTelemetry.sessionMetadata(
      Self.telemetryChild, parent: Self.telemetryParent)

    #expect(
      metadata[ACPAgentTelemetry.LogMetadataKey.sessionId] == "\(Self.telemetryChild.rawValue)")
  }

  /// A record about a root session holds no parent id.
  @Test
  func aRecordOfARootSessionHoldsNoParentId() {
    let metadata = ACPAgentTelemetry.sessionMetadata(Self.telemetryParent)

    #expect(metadata[ACPAgentTelemetry.LogMetadataKey.parentSessionId] == nil)
  }

  /// A record about the model work of a child holds the id of its parent.
  @Test
  func aModelRecordOfAChildHoldsTheIdOfItsParent() {
    let metadata = ACPAgentTelemetry.modelMetadata(
      sessionId: Self.telemetryChild, parent: Self.telemetryParent, modelRef: syntheticModelName)

    #expect(
      metadata[ACPAgentTelemetry.LogMetadataKey.parentSessionId]
        == "\(Self.telemetryParent.rawValue)")
  }

  /// The span of a request on a child holds the id of the child and the id of its parent.
  @Test
  func theSpanOfARequestOnAChildHoldsTheIdOfItsParent() async throws {
    let run = try await TelemetryCapture.run(forbidding: []) { context in
      let span = RequestTracing.startRequestSpan(
        ACPAgentTelemetry.SpanName.prompt, method: ACPMethod.sessionPrompt,
        sessionId: Self.telemetryChild, parentSessionId: Self.telemetryParent, meta: nil,
        logger: ACPAgentTelemetry.logger(.promptExecution))
      span.end()
      return TracedRun(sessionId: Self.telemetryChild.rawValue, context: context)
    }

    let span = try #require(run.spans(named: ACPAgentTelemetry.SpanName.prompt).first)

    #expect(
      span.attributes.get(ACPAgentTelemetry.AttributeKey.parentSessionId)
        == .string(Self.telemetryParent.rawValue))
  }

  /// The span of a request on a root session holds no parent id.
  @Test
  func theSpanOfARequestOnARootSessionHoldsNoParentId() async throws {
    let run = try await TelemetryCapture.run(forbidding: []) { context in
      let span = RequestTracing.startRequestSpan(
        ACPAgentTelemetry.SpanName.prompt, method: ACPMethod.sessionPrompt,
        sessionId: Self.telemetryParent, meta: nil,
        logger: ACPAgentTelemetry.logger(.promptExecution))
      span.end()
      return TracedRun(sessionId: Self.telemetryParent.rawValue, context: context)
    }

    let span = try #require(run.spans(named: ACPAgentTelemetry.SpanName.prompt).first)

    #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.parentSessionId) == nil)
  }

  /// The projection of a child writes its records with the id of its parent.
  @Test
  func aRecordOfTheProjectionOfAChildHoldsTheIdOfItsParent() async throws {
    let run = try await TelemetryCapture.run(forbidding: []) { context in
      await Self.projectAnAnswerWithNoText(of: Self.telemetryChild, parent: Self.telemetryParent)
      return TracedRun(sessionId: Self.telemetryChild.rawValue, context: context)
    }

    let record = try #require(run.logRecords.first { $0.message == Self.unsentEventMessage })

    #expect(
      record.metadata[ACPAgentTelemetry.LogMetadataKey.parentSessionId]
        == "\(Self.telemetryParent.rawValue)")
  }

  /// Projects one answer that holds no text through a projector, so the translator writes the
  /// record of an event that it does not send.
  ///
  /// - Parameters:
  ///   - session: The session of the projector.
  ///   - parent: The parent of the session.
  private static func projectAnAnswerWithNoText(of session: SessionId, parent: SessionId?) async {
    let projector = SessionProjector(
      sessionId: session, parentSessionId: parent, modelName: syntheticModelName, send: { _ in },
      relay: nil, runCallJoins: RunCallJoinTable())
    let (outputs, input) = AsyncStream.makeStream(of: SessionOutput.self)
    let source = SessionProjector.Source(id: ULID.generate(), session: nil)
    await projector.attach(outputs, from: source)
    let mailId = MailID()
    input.yield(
      SessionOutput(
        origin: Origin.mail([mailId]), event: .answered(.makeSynthetic(answering: mailId))))
    input.finish()
    await projector.stop(after: [source.id])
  }

  // MARK: - The gauge of the active sessions

  /// The gauge of the active sessions counts the root and not the live child. The count of the
  /// roots is the count that a client opened. A number that mixed roots and children would
  /// change each time a child starts or ends.
  @Test
  func theGaugeOfTheActiveSessionsDoesNotCountTheChild() async throws {
    let lastValue = try await TelemetryCapture.run(forbidding: []) { context in
      let run = try await Self.startLiveChild(tracer: context.tracer)
      await run.fixture.harness.agent.recordActiveSessions()
      let value = try context.metricsFactory.expectGauge(
        ACPAgentTelemetry.MetricName.activeSessions
      ).lastValue
      try await run.finish()
      await run.fixture.close()
      return value
    }

    #expect(lastValue == Self.oneOpenRoot)
  }

  /// The number of root sessions in the gauge test.
  private static let oneOpenRoot = 1.0

  // MARK: - A cold resume

  /// A cold `session/resume` restores a child with the hooks of a session that resumed: the
  /// key of the folder of its root, and the root as its parent.
  @Test
  func aRestoredChildFiresItsHooksWithTheKeyAndTheParentOfItsRoot() async throws {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    let recorder = RecordingHookVisitor()
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-second", workingDirectory: recording.cwd,
      hookVisitors: [recorder])
    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)
    await fixture.harness.agent.hooks.dispatcher.drain()

    let starts = recorder.events.value.filter {
      $0.isSessionStart && $0.session.sessionID == recording.child.rawValue
    }

    #expect(starts.map(\.session.sessionKey) == [AgentHome.projectKey(of: recording.cwd)])
    #expect(starts.map(\.session.parentSessionID) == [recording.root.rawValue])
    await fixture.close()
  }
}
