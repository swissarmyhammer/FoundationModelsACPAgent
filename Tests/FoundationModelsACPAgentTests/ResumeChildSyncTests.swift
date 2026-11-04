import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The sync of the children after a `session/resume` of a tree of three sessions (root, child,
/// grandchild). The first agent records the chain and is killed while the child and the grandchild
/// work. A second agent resumes the root. Each child gets its current `subagent_update` and its
/// own current `state_update` after the response, the parent before the child, with or without
/// `replayFrom`. The response is the freshness boundary: the history comes before it, and the
/// current state comes after it.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ResumeChildSyncTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ResumeChildSyncTests"

  /// The id of the resume request in the trace of the validator.
  private static let requestId = RequestId.number(1)

  /// The seconds that a test waits for the sync after the response. A sync that does not come
  /// in this time fails the test, and the test does not wait for the time limit of the suite.
  private static let syncWaitSeconds = 20

  /// The most polls of a ledger in a test.
  private static let workPollLimit = 500

  /// The time between two polls of a ledger.
  private static let workPollInterval = Duration.milliseconds(10)

  /// One update on the wire, with its place in the trace.
  private struct Sent {
    /// The position in the trace.
    let position: Int

    /// The stream that carried the update.
    let sessionId: SessionId

    /// The update.
    let update: SessionUpdate

    /// The announcement that the update holds, or `nil` for any other update.
    var announcement: SubagentUpdate? {
      update.announcement
    }

    /// The update as an event of the trace.
    var event: WireTraceEvent {
      .update(sessionId: sessionId, update: update)
    }
  }

  /// The wire of one resume.
  private struct Wire {
    /// The second agent.
    let fixture: ScriptedPromptFixture

    /// The chain that the first agent recorded.
    let recording: ResumeNestedSessionsTests.Recording

    /// The request, the updates and the response, in wire order.
    let trace: [WireTraceEvent]

    /// The trace in words, one line for each event: the position, the event and the stream
    /// that carried it. A failed expectation shows it, so the update that breaks a rule
    /// of the validator has a name.
    var traceDescription: String {
      trace.enumerated().map { position, event in
        "\(position): \(event.summary)"
      }.joined(separator: "\n")
    }

    /// The position of the response.
    var responsePosition: Int {
      trace.firstIndex { event in
        if case .resumeResponse = event {
          return true
        }
        return false
      } ?? trace.count
    }

    /// Every update of the trace.
    var updates: [Sent] {
      trace.enumerated().compactMap { position, event in
        guard case .update(let sessionId, let update) = event else {
          return nil
        }
        return Sent(position: position, sessionId: sessionId, update: update)
      }
    }

    /// The updates before the response.
    var beforeResponse: [Sent] {
      updates.filter { $0.position < responsePosition }
    }

    /// The updates after the response.
    var afterResponse: [Sent] {
      updates.filter { $0.position > responsePosition }
    }

    /// The first announcement of `child` after the response: its current snapshot.
    ///
    /// - Parameter child: The child.
    /// - Returns: The update, or `nil` when the wire holds none.
    func snapshot(of child: SessionId) -> Sent? {
      afterResponse.first { $0.update.announces(child) }
    }

    /// The first `state_update` of `child` on its own stream after the response.
    ///
    /// - Parameter child: The child.
    /// - Returns: The update, or `nil` when the wire holds none.
    func ownState(of child: SessionId) -> Sent? {
      afterResponse.first { $0.event.isOwnState(of: child) }
    }
  }

  // MARK: - Fixtures

  /// The resume request of the root of `recording`.
  ///
  /// - Parameters:
  ///   - recording: The chain that the first agent recorded.
  ///   - replayFrom: The replay cursor of the request, or `nil` for none.
  /// - Returns: The request.
  private static func request(
    _ recording: ResumeNestedSessionsTests.Recording, replayFrom: ReplayFrom?
  ) -> ResumeSessionRequest {
    ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root,
      replayFrom: replayFrom)
  }

  /// The replay cursor of a test.
  ///
  /// - Parameter replays: Whether the request asks for a replay.
  /// - Returns: The cursor, or `nil` for none.
  private static func cursor(replays: Bool) -> ReplayFrom? {
    replays ? .start(ReplayFromStart()) : nil
  }

  /// Resumes the root of `recording` in a second agent, and reads the wire until the sync after
  /// the response is complete.
  ///
  /// - Parameters:
  ///   - recording: The chain that the first agent recorded.
  ///   - replays: Whether the request asks for a replay.
  ///   - settledBy: Tells the last event of the sync: the read ends after it.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resume(
    _ recording: ResumeNestedSessionsTests.Recording, replays: Bool,
    settledBy: @escaping @Sendable (WireTraceEvent) -> Bool
  ) async throws -> Wire {
    let fixture = try await secondAgent(for: recording)
    let connection = fixture.harness.connection
    let subscription = connection.subscribeToAllSessions()
    let first = WireTraceEvent.resumeRequest(id: requestId, sessionId: recording.root)
    let reader = Task {
      await subscription.readResumeTrace(startingWith: [first], settledBy: settledBy)
    }
    let call = request(recording, replayFrom: cursor(replays: replays))
    let resumeCall = Task { try await connection.resumeSession(call) }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(syncWaitSeconds))
      reader.cancel()
    }
    let trace = await reader.value
    timeout.cancel()
    _ = try await resumeCall.value
    return Wire(fixture: fixture, recording: recording, trace: trace)
  }

  /// Records the chain, and resumes it as ``resume(_:replays:settledBy:)`` does. The read ends
  /// after the own `state_update` of the grandchild: the last send of the sync.
  ///
  /// - Parameter replays: Whether the request asks for a replay.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeChain(replays: Bool) async throws -> Wire {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    let leaf = recording.leaf
    return try await resume(recording, replays: replays) { $0.isOwnState(of: leaf) }
  }

  /// Records the chain with the orderly shutdown of the process, and resumes it with a replay.
  /// The read ends after the own `state_update` of the grandchild: the last send of the sync.
  ///
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeShutDownChain() async throws -> Wire {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    let leaf = recording.leaf
    return try await resume(recording, replays: true) { $0.isOwnState(of: leaf) }
  }

  /// Records the chain, removes the definition of the child agent, and resumes it. The child and
  /// the grandchild do not restore. The read ends after the announcement of the grandchild.
  ///
  /// - Parameter replays: Whether the request asks for a replay.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeChainWithoutTheChildAgent(replays: Bool) async throws -> Wire {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    try AgentsToolTests.removeAgent(
      named: ResumeNestedSessionsTests.childAgent, in: recording.cwd)
    let leaf = recording.leaf
    return try await resume(recording, replays: replays) { $0.announces(leaf) }
  }

  /// Resumes the chain with no wire request, so the sync after the response does not run. The
  /// children are restored, and no client has seen them.
  ///
  /// - Returns: The second agent and the chain.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeWithoutSync() async throws -> (
    fixture: ScriptedPromptFixture, recording: ResumeNestedSessionsTests.Recording
  ) {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    return (try await resumeWithoutWire(recording), recording)
  }

  /// Starts the second agent over the working directory of `recording`.
  ///
  /// - Parameter recording: The chain that the first agent recorded.
  /// - Returns: The second agent.
  /// - Throws: Whatever the fixture throws.
  private static func secondAgent(
    for recording: ResumeNestedSessionsTests.Recording
  ) async throws -> ScriptedPromptFixture {
    try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-second", workingDirectory: recording.cwd)
  }

  /// Starts the second agent and resumes `recording` with no replay and no wire reader.
  ///
  /// - Parameter recording: The chain that the first agent recorded.
  /// - Returns: The second agent, with the resumed root.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeWithoutWire(
    _ recording: ResumeNestedSessionsTests.Recording
  ) async throws -> ScriptedPromptFixture {
    let fixture = try await secondAgent(for: recording)
    _ = try await fixture.harness.routedConnection.resumeSession(
      request(recording, replayFrom: nil))
    return fixture
  }

  /// Starts work in the session of `child` and returns when the ledger of the child notes it.
  /// The gate of the child holds the update of the change until the sync opens it, and the call
  /// that made the change waits with it, so the call runs in a task of its own.
  ///
  /// - Parameter child: The entry of the restored child.
  /// - Returns: The task of the call. The test awaits it after the sync, and cancels it when the
  ///   test ends early.
  /// - Throws: An issue when the ledger does not note the work in time.
  private static func startWork(of child: ActiveSession) async throws -> Task<Void, Never> {
    let work = Task { await child.stateLedger.workStarted(on: ULID()) }
    try await pollUntil(limit: workPollLimit, interval: workPollInterval) {
      await !child.stateLedger.isIdle
    }
    try #require(await !child.stateLedger.isIdle)
    return work
  }

  /// Waits until the background list of `session` is `expected`.
  ///
  /// - Parameters:
  ///   - expected: The list that the test waits for.
  ///   - session: The entry whose ledger is read.
  /// - Returns: The last list that the ledger gave.
  /// - Throws: Whatever the sleep throws.
  private static func backgroundList(
    becoming expected: [BackgroundWork], of session: ActiveSession
  ) async throws -> [BackgroundWork] {
    try await pollUntil(limit: workPollLimit, interval: workPollInterval) {
      await session.stateLedger.backgroundList == expected
    }
    return await session.stateLedger.backgroundList
  }

  // MARK: - With a replay

  /// A replay sends the history of the children before the response. It sends no capabilities
  /// then: they are a current fact, and the snapshot after the response gives them.
  @Test
  func aReplaySendsNoChildCapabilitiesBeforeTheResponse() async throws {
    let wire = try await Self.resumeChain(replays: true)

    let announced = wire.beforeResponse.compactMap(\.announcement)
    try #require(!announced.isEmpty)

    #expect(announced.allSatisfy { $0.capabilities == .unchanged })
    await wire.fixture.close()
  }

  /// A replay sends no `state_update` of a child before the response.
  @Test
  func aReplaySendsNoChildStateBeforeTheResponse() async throws {
    let wire = try await Self.resumeChain(replays: true)
    let root = wire.recording.root

    let childStates = wire.beforeResponse.filter { $0.sessionId != root && $0.update.isStateUpdate }

    #expect(childStates.isEmpty)
    await wire.fixture.close()
  }

  // MARK: - With and without a replay

  /// A child that the replay announced gets its current snapshot as the first update after the
  /// response, and so does a child that nothing announced.
  @Test(arguments: [true, false])
  func eachChildGetsACurrentSnapshotAfterTheResponse(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)
    let recording = wire.recording

    let child = try #require(wire.snapshot(of: recording.child)?.announcement)
    let leaf = try #require(wire.snapshot(of: recording.leaf)?.announcement)

    #expect(child.capabilities == .value(SubagentAnnouncer.childCapabilities))
    #expect(leaf.capabilities == .value(SubagentAnnouncer.childCapabilities))
    await wire.fixture.close()
  }

  /// The snapshot carries the working directory of the child.
  @Test(arguments: [true, false])
  func theSnapshotCarriesTheWorkingDirectoryOfTheChild(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)

    let child = try #require(wire.snapshot(of: wire.recording.child)?.announcement)

    #expect(child.cwd == .value(AbsolutePath(rawValue: wire.recording.cwd.path)))
    await wire.fixture.close()
  }

  /// A child that has a session of its own sends its own current `state_update` after the
  /// response too.
  @Test(arguments: [true, false])
  func eachChildSendsItsOwnCurrentStateAfterTheResponse(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)
    let recording = wire.recording

    #expect(wire.ownState(of: recording.child) != nil)
    #expect(wire.ownState(of: recording.leaf) != nil)
    await wire.fixture.close()
  }

  /// The chain of three: the root announces the child, and the child announces the grandchild
  /// on its own stream, after the child was announced.
  @Test(arguments: [true, false])
  func eachParentIsAnnouncedBeforeItsChild(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)
    let recording = wire.recording

    let child = try #require(wire.snapshot(of: recording.child))
    let leaf = try #require(wire.snapshot(of: recording.leaf))

    #expect(child.sessionId == recording.root)
    #expect(leaf.sessionId == recording.child)
    #expect(child.position < leaf.position)
    await wire.fixture.close()
  }

  /// A session sends its own state after the snapshot that announces it.
  @Test(arguments: [true, false])
  func aChildSendsItsOwnStateAfterItsSnapshot(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)
    let recording = wire.recording

    let snapshot = try #require(wire.snapshot(of: recording.child))
    let own = try #require(wire.ownState(of: recording.child))

    #expect(snapshot.position < own.position)
    await wire.fixture.close()
  }

  /// A child that came back from the disk is idle. Nothing starts it here.
  @Test(arguments: [true, false])
  func aColdRestoredChildIsIdleInItsSnapshot(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)

    let states = [wire.recording.child, wire.recording.leaf].map {
      wire.snapshot(of: $0)?.announcement?.state
    }

    #expect(
      states.allSatisfy { state in
        if case .value(.idle)? = state {
          return true
        }
        return false
      })
    await wire.fixture.close()
  }

  // MARK: - Without a replay

  /// A resume with no replay sends no update of a child before the response.
  @Test
  func noChildUpdateComesBeforeTheResponseWithoutAReplay() async throws {
    let wire = try await Self.resumeChain(replays: false)
    let root = wire.recording.root
    try #require(wire.snapshot(of: wire.recording.child) != nil)

    let beforeResponse = wire.beforeResponse.filter {
      $0.sessionId != root || $0.announcement != nil
    }

    #expect(beforeResponse.isEmpty)
    await wire.fixture.close()
  }

  // MARK: - A running child

  /// A child that works in this process shows `running` in its snapshot, and not `idle`.
  @Test
  func aRunningChildShowsRunningInItsSnapshot() async throws {
    let (fixture, recording) = try await Self.resumeWithoutSync()
    let agent = fixture.harness.agent
    let child = try #require(await agent.sessions[recording.child])
    let work = try await Self.startWork(of: child)
    defer { work.cancel() }

    await agent.syncChildren(of: recording.root)
    let updates = try await fixture.collector.wait(for: "the snapshot of the child") { updates in
      updates.contains { $0.sessionId == recording.root && $0.update.announces(recording.child) }
    }

    let snapshot = try #require(
      updates.first { $0.sessionId == recording.root && $0.update.announces(recording.child) }?
        .update.announcement)
    var isRunning = false
    if case .value(.running) = snapshot.state {
      isRunning = true
    }
    #expect(isRunning)
    await work.value
    await fixture.close()
  }

  /// A snapshot of a child comes before any later update of the same child: the update that the
  /// child made while the client did not know it waits for the snapshot.
  @Test
  func theSnapshotOfAChildComesBeforeItsRunningUpdate() async throws {
    let (fixture, recording) = try await Self.resumeWithoutSync()
    let agent = fixture.harness.agent
    let child = try #require(await agent.sessions[recording.child])
    let work = try await Self.startWork(of: child)
    defer { work.cancel() }

    await agent.syncChildren(of: recording.root)
    let updates = try await fixture.collector.wait(for: "the running update of the child") {
      updates in
      updates.contains { $0.sessionId == recording.child && $0.update.isStateUpdate }
    }

    let snapshot = updates.firstIndex {
      $0.sessionId == recording.root && $0.update.announces(recording.child)
    }
    let first = updates.firstIndex { $0.sessionId == recording.child }
    #expect(try #require(snapshot) < #require(first))
    await work.value
    await fixture.close()
  }

  /// The parent lists a child that works while it works: the sync tells the ledger of the parent
  /// that the client knows the child.
  @Test
  func theParentListsARunningChildInItsBackgroundList() async throws {
    let (fixture, recording) = try await Self.resumeWithoutSync()
    let agent = fixture.harness.agent
    let child = try #require(await agent.sessions[recording.child])
    let work = try await Self.startWork(of: child)
    defer { work.cancel() }

    await agent.syncChildren(of: recording.root)
    let root = try #require(await agent.sessions[recording.root])
    let listed = try await Self.backgroundList(
      becoming: [.subagent(BackgroundSubagent(sessionId: recording.child))], of: root)

    #expect(listed == [.subagent(BackgroundSubagent(sessionId: recording.child))])
    await work.value
    await fixture.close()
  }

  /// A listed child that the history holds is sent before the response without its capabilities.
  /// They are a current fact, and the snapshot after the response gives them.
  @Test
  func theListedChildOfTheSyncBeforeTheResponseCarriesNoCapabilities() throws {
    let child = SessionId(rawValue: "child")
    var history = SessionMergeEngine()
    history.apply(
      .subagentUpdate(
        SubagentUpdate(
          sessionId: child, capabilities: .value(SubagentAnnouncer.childCapabilities),
          state: .value(.running(RunningStateUpdate())))))

    let update = history.currentUpdate(of: .subagent(BackgroundSubagent(sessionId: child)))

    let sent = try #require(update?.announcement)
    #expect(sent.capabilities == .unchanged)
  }

  // MARK: - A child that does not restore

  /// The reason that the restore gives for a child whose agent definition is gone: the text of
  /// the restore error `unknownAgent`.
  private static let missingChildAgentReason = String(
    describing: AgentRunRestoreError.unknownAgent(ResumeNestedSessionsTests.childAgent))

  /// A child that does not restore is announced after the response with no state, no
  /// capabilities, and the reason. The root still resumes.
  @Test(arguments: [true, false])
  func aChildThatDoesNotRestoreIsAnnouncedWithTheReason(replays: Bool) async throws {
    let wire = try await Self.resumeChainWithoutTheChildAgent(replays: replays)

    let announced = try #require(wire.snapshot(of: wire.recording.child)?.announcement)
    let failure = SAH.RestoreFailure.extract(from: announced.metaValue)

    #expect(announced.state == .cleared)
    #expect(announced.capabilities == .cleared)
    #expect(failure?.reason.isEmpty == false)
    #expect(failure?.reason == Self.missingChildAgentReason)
    #expect(await wire.fixture.harness.agent.sessions[wire.recording.root] != nil)
    await wire.fixture.close()
  }

  /// The descendant of a child that does not restore is announced the same way, after its
  /// parent, on the stream of its parent, with the reason that an ancestor did not restore.
  @Test(arguments: [true, false])
  func theDescendantOfAFailedChildIsAnnouncedWithTheAncestorReason(replays: Bool) async throws {
    let wire = try await Self.resumeChainWithoutTheChildAgent(replays: replays)
    let recording = wire.recording

    let child = try #require(wire.snapshot(of: recording.child))
    let leaf = try #require(wire.snapshot(of: recording.leaf))
    let failure = SAH.RestoreFailure.extract(from: leaf.announcement?.metaValue)

    #expect(leaf.sessionId == recording.child)
    #expect(child.position < leaf.position)
    #expect(failure?.reason == FailedChild.ancestorReason)
    #expect(leaf.announcement?.state == .cleared)
    #expect(leaf.announcement?.capabilities == .cleared)
    await wire.fixture.close()
  }

  // MARK: - After an orderly shutdown

  /// An orderly shutdown pauses the open `agents` call of each session. The replay sends the
  /// merged call of the root and of the child, and both read `paused`.
  @Test
  func aShutdownLeavesEachAgentsCallPausedInTheReplay() async throws {
    let wire = try await Self.resumeShutDownChain()

    let calls = AgentsToolTests.agentsCalls(in: wire.beforeResponse.map(\.update))

    #expect(calls.map(\.status) == [.value(.paused), .value(.paused)])
    await wire.fixture.close()
  }

  /// A call that the shutdown paused has no final status, so the resume restores its child: the
  /// child and the grandchild get their current snapshot after the response.
  @Test
  func aShutdownRestoresTheChildrenAfterTheResume() async throws {
    let wire = try await Self.resumeShutDownChain()

    let restored = [wire.recording.child, wire.recording.leaf].map { wire.snapshot(of: $0) != nil }

    #expect(restored == [true, true])
    await wire.fixture.close()
  }

  /// The wire of the resume after an orderly shutdown follows the rules of the validator.
  @Test
  func theWireAfterAShutdownFollowsTheRulesOfTheValidator() async throws {
    let wire = try await Self.resumeShutDownChain()
    try #require(wire.snapshot(of: wire.recording.leaf) != nil)

    #expect(SubagentWireTraceValidator().validate(wire.trace) == [])
    await wire.fixture.close()
  }

  /// The prompt of the root was interrupted, and no prompt of it is completed. The state snapshot
  /// of the root goes out before the response. It is `idle` with no stop reason: it reports
  /// neither `end_turn` nor `cancelled`.
  @Test
  func theRootAfterAShutdownReportsNoCompletedPrompt() async throws {
    let wire = try await Self.resumeShutDownChain()

    let idles = wire.beforeResponse.compactMap { sent -> IdleStateUpdate? in
      if sent.sessionId == wire.recording.root, case .stateUpdate(.idle(let idle)) = sent.update {
        return idle
      }
      return nil
    }
    try #require(idles.count == 1)

    #expect(idles.first?.stopReason == nil)
    await wire.fixture.close()
  }

  // MARK: - A child whose call is final

  /// The text of the update that marks the end of the sync on the wire.
  private static let syncEndMarker = "SYNC-END-MARKER"

  /// Resumes the chain that a user close recorded, with no wire request, runs the sync, and then
  /// posts a marker on the stream of the root. The connection keeps the order of its posts, so the
  /// marker tells that every update of the sync is out. The history of the resumed root holds a
  /// final status for the `agents` call of the child: the call is the rule that the sync reads.
  ///
  /// - Returns: The updates up to the marker, and the chain.
  /// - Throws: Whatever the fixture, the request or the wait throws.
  private static func syncOfTheClosedChain() async throws -> (
    updates: [UpdateSessionNotification], recording: ResumeNestedSessionsTests.Recording
  ) {
    let recording = try await ResumeNestedSessionsTests.recordClosedChain()
    let fixture = try await resumeWithoutWire(recording)
    let agent = fixture.harness.agent
    try #require(await agent.sessions[recording.root]?.history.endsCall(of: recording.child) == true)
    await agent.syncChildren(of: recording.root)
    let connection = try #require(agent.connections.path(forSession: recording.root)?.connection)
    await connection.post(
      .agentMessageChunk(
        ContentChunk(
          content: .text(TextContent(text: syncEndMarker)),
          messageId: ACPEventTranslator.makeMessageId())),
      in: recording.root)
    let updates = try await fixture.collector.wait(for: "the end marker of the sync") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId == recording.root })
        .contains(syncEndMarker)
    }
    await fixture.close()
    return (updates, recording)
  }

  /// A child whose `agents` call has a final status in the history is not restored as a live
  /// child: it gets no snapshot after the response.
  @Test
  func aChildWhoseCallIsFinalGetsNoSnapshotAfterTheResponse() async throws {
    let (updates, recording) = try await Self.syncOfTheClosedChain()

    let announced = updates.filter { notification in
      notification.update.announces(recording.child)
        || notification.update.announces(recording.leaf)
    }

    #expect(announced.isEmpty)
  }

  /// A child whose `agents` call has a final status in the history sends no `state_update` of its
  /// own after the response.
  @Test
  func aChildWhoseCallIsFinalSendsNoOwnStateAfterTheResponse() async throws {
    let (updates, recording) = try await Self.syncOfTheClosedChain()

    let states = updates.filter { notification in
      [recording.child, recording.leaf].contains(notification.sessionId)
        && notification.update.isStateUpdate
    }

    #expect(states.isEmpty)
  }

  // MARK: - The validator

  /// The trace of a resume follows the rules of the validator for sub-agent sessions, with or
  /// without a replay.
  @Test(arguments: [true, false])
  func theWireOfTheResumeFollowsTheRulesOfTheValidator(replays: Bool) async throws {
    let wire = try await Self.resumeChain(replays: replays)
    try #require(wire.snapshot(of: wire.recording.leaf) != nil)

    let violations = SubagentWireTraceValidator().validate(wire.trace)

    #expect(violations == [])
    await wire.fixture.close()
  }

  /// A hard kill leaves the `agents` call open in the recording. The resume of that recording
  /// replays no final status of the call, and its wire follows the rules of the validator, with
  /// the snapshots after the response.
  @Test
  func aHardKillKeepsTheAgentsCallOpenAndTheResumeWireIsValid() async throws {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    let leaf = recording.leaf
    let wire = try await Self.resume(recording, replays: true) { $0.isOwnState(of: leaf) }

    let calls = AgentsToolTests.agentsCalls(in: wire.beforeResponse.map(\.update))
    try #require(!calls.isEmpty)
    try #require(wire.snapshot(of: recording.leaf) != nil)

    #expect(calls.allSatisfy { !BackgroundWatch.isFinal($0.status) })
    #expect(SubagentWireTraceValidator().validate(wire.trace) == [])
    await wire.fixture.close()
  }

  /// The trace of a resume with a child that does not restore follows the rules of the
  /// validator, with or without a replay.
  @Test(arguments: [true, false])
  func theWireOfAResumeWithAFailedChildFollowsTheRulesOfTheValidator(replays: Bool) async throws {
    let wire = try await Self.resumeChainWithoutTheChildAgent(replays: replays)
    try #require(wire.snapshot(of: wire.recording.leaf) != nil)

    let violations = SubagentWireTraceValidator().validate(wire.trace)

    #expect(violations == [], Comment(rawValue: wire.traceDescription))
    await wire.fixture.close()
  }
}

extension WireTraceEvent {
  /// This event in words: an update, with the stream that carried it.
  fileprivate var summary: String {
    switch self {
    case .resumeRequest(_, let sessionId):
      return "resume request for \(sessionId.rawValue)"
    case .resumeResponse:
      return "resume response"
    case .agentRequest(_, let method, let sessionId):
      return "request \(method) for \(sessionId.rawValue)"
    case .update(let sessionId, let update):
      return "update in \(sessionId.rawValue): \(update)"
    }
  }

  /// Whether this event is an announcement of `child`, on any stream.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` for a `subagent_update` that names `child`.
  fileprivate func announces(_ child: SessionId) -> Bool {
    if case .update(_, let update) = self {
      return update.announces(child)
    }
    return false
  }

  /// Whether this event is the own `state_update` of `session`, on its own stream.
  ///
  /// - Parameter session: The session.
  /// - Returns: `true` for a `state_update` on the stream of `session`.
  fileprivate func isOwnState(of session: SessionId) -> Bool {
    if case .update(let stream, let update) = self {
      return stream == session && update.isStateUpdate
    }
    return false
  }
}

extension SubagentUpdate {
  /// The value of the `_meta` of this announcement, or `nil` when it carries none.
  fileprivate var metaValue: FoundationModelsACP.JSONValue? {
    if case .value(let value) = meta {
      return value
    }
    return nil
  }
}
