import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The state that a cold `session/resume` gives a restored nested run that the agent drives
/// again (decision of testudoapp-75). The first agent records a chain of three sessions (root,
/// child, grandchild) and stops while the child and the grandchild work: with the orderly
/// shutdown, or with a kill. A second agent resumes the root, and drives the restored runs again.
///
/// A restored run that the agent drives again is work. So its snapshot after the response says
/// `running`, and no `idle` comes on its own stream before its `running`. The sessions that wait
/// for it (its callers, up to the root) are not idle with noWork either. A session that has really
/// no work still gets idle with noWork.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct RestoredRunStateTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "RestoredRunStateTests"

  /// The seconds that a read of the wire waits for its last event. A read that does not settle
  /// in this time fails the test, and the test does not wait for the time limit of the suite.
  private static let readWaitSeconds = 30

  /// How the first agent stopped while the child and the grandchild worked.
  enum Stop: CaseIterable, Sendable {
    /// The orderly shutdown of the process.
    case shutDown

    /// A hard kill of the process.
    case kill

    /// Records the chain and stops the first agent this way.
    ///
    /// - Returns: The chain.
    /// - Throws: Whatever the fixture or a wait throws.
    func record() async throws -> ResumeNestedSessionsTests.Recording {
      switch self {
      case .shutDown:
        return try await ResumeNestedSessionsTests.recordShutDownChain()
      case .kill:
        return try await ResumeNestedSessionsTests.recordInterruptedChain()
      }
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

    /// The position of the response.
    var responsePosition: Int {
      trace.firstIndex(where: \.isResumeResponse) ?? trace.count
    }

    /// The trace in words, one line for each event. A failed expectation shows it.
    var traceDescription: String {
      trace.enumerated().map { position, event in
        "\(position): \(event)"
      }.joined(separator: "\n")
    }

    /// The state of the first announcement of `child` after the response: its snapshot.
    ///
    /// - Parameter child: The child.
    /// - Returns: The state, or `nil` when the wire holds no such snapshot.
    func snapshotState(of child: SessionId) -> StateUpdate? {
      trace[responsePosition...].lazy.compactMap { $0.announcedState(of: child) }.first
    }

    /// Every `state_update` on the stream of `session`, in wire order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The states.
    func ownStates(of session: SessionId) -> [StateUpdate] {
      trace.compactMap { $0.ownState(of: session) }
    }

    /// Every state on the wire that tells the state of `session`: its own `state_update`s and the
    /// states of its announcements, in wire order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The states.
    func states(of session: SessionId) -> [StateUpdate] {
      trace.compactMap { event in
        event.ownState(of: session) ?? event.announcedState(of: session)
      }
    }
  }

  // MARK: - Fixtures

  /// Resumes the root of `recording` in a second agent, and reads the wire up to the first event
  /// after the response that `settledBy` accepts. The model of the second agent ends each pass at
  /// once, so the restored runs end on their own.
  ///
  /// - Parameters:
  ///   - recording: The chain that the first agent recorded.
  ///   - settledBy: Tells the last event of the read.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resume(
    _ recording: ResumeNestedSessionsTests.Recording,
    settledBy: (@Sendable (WireTraceEvent) -> Bool)?
  ) async throws -> Wire {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-second", workingDirectory: recording.cwd)
    let connection = fixture.harness.connection
    let subscription = connection.subscribeToAllSessions()
    let first = WireTraceEvent.resumeRequest(id: .number(1), sessionId: recording.root)
    let request = ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root)
    let trace = try await subscription.readResumeTrace(
      startingWith: [first], settledBy: settledBy, timeout: .seconds(readWaitSeconds)
    ) {
      _ = try await connection.resumeSession(request)
    }
    return Wire(fixture: fixture, recording: recording, trace: trace)
  }

  /// Records the chain, resumes it, and reads the wire up to the own `state_update` of the
  /// grandchild: the last send of the sync of the children.
  ///
  /// - Parameter stop: How the first agent stopped.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeUpToTheSync(after stop: Stop) async throws -> Wire {
    let recording = try await stop.record()
    let leaf = recording.leaf
    return try await resume(recording) { $0.ownState(of: leaf) != nil }
  }

  /// Records the chain, resumes it, and reads the wire until the root says idle with noWork and
  /// lists no background work: the whole tree has no work.
  ///
  /// - Parameter stop: How the first agent stopped.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeUntilTheTreeHasNoWork(after stop: Stop) async throws -> Wire {
    let recording = try await stop.record()
    let root = recording.root
    return try await resume(recording) { event in
      guard let state = event.ownState(of: root) else {
        return false
      }
      return state.saysNoWork && state.backgroundList.isEmpty
    }
  }

  // MARK: - A restored run that the agent drives again

  /// The snapshot of a restored run after the response says `running`.
  @Test(arguments: Stop.allCases, [false, true])
  func theSnapshotOfARestoredRunSaysRunning(after stop: Stop, isLeaf: Bool) async throws {
    let wire = try await Self.resumeUpToTheSync(after: stop)
    let run = isLeaf ? wire.recording.leaf : wire.recording.child

    let state = try #require(wire.snapshotState(of: run), "\(wire.traceDescription)")

    #expect(state.isRunning, "\(wire.traceDescription)")
    await wire.fixture.close()
  }

  /// The first own `state_update` of a restored run is `running`: no `idle` comes before it.
  @Test(arguments: Stop.allCases, [false, true])
  func aRestoredRunSendsNoIdleBeforeItsRunning(after stop: Stop, isLeaf: Bool) async throws {
    let wire = try await Self.resumeUpToTheSync(after: stop)
    let run = isLeaf ? wire.recording.leaf : wire.recording.child

    let first = try #require(wire.ownStates(of: run).first, "\(wire.traceDescription)")

    #expect(first.isRunning, "\(wire.traceDescription)")
    await wire.fixture.close()
  }

  /// The root waits for its restored child. No state of the root says idle with noWork while the
  /// restored runs wait for their re-drive: before the response, and in the sync after it.
  @Test(arguments: Stop.allCases)
  func theRootThatWaitsForARestoredRunIsNotIdleWithNoWork(after stop: Stop) async throws {
    let wire = try await Self.resumeUpToTheSync(after: stop)

    let states = wire.states(of: wire.recording.root)
    try #require(!states.isEmpty, "\(wire.traceDescription)")

    let noWork = states.filter(\.saysNoWork)

    #expect(noWork.isEmpty, "\(wire.traceDescription)")
    await wire.fixture.close()
  }

  // MARK: - A session with no work

  /// When the re-driven runs end, the grandchild says idle with noWork: it has no work now.
  @Test(arguments: Stop.allCases)
  func aRestoredRunThatEndedSaysIdleWithNoWork(after stop: Stop) async throws {
    let wire = try await Self.resumeUntilTheTreeHasNoWork(after: stop)

    let last = try #require(
      wire.ownStates(of: wire.recording.leaf).last, "\(wire.traceDescription)")

    #expect(last.saysNoWork, "\(wire.traceDescription)")
    await wire.fixture.close()
  }

  /// When the re-driven runs end, the root that waited for them says idle with noWork and lists
  /// no work: the hold of the restore ended with the work of the root.
  @Test(arguments: Stop.allCases)
  func theRootSaysIdleWithNoWorkWhenTheRedrivenRunsEnd(after stop: Stop) async throws {
    let wire = try await Self.resumeUntilTheTreeHasNoWork(after: stop)

    let last = try #require(
      wire.ownStates(of: wire.recording.root).last, "\(wire.traceDescription)")

    #expect(last.saysNoWork && last.backgroundList.isEmpty, "\(wire.traceDescription)")
    await wire.fixture.close()
  }

  /// A resumed root with no interrupted run has no work: its state before the response says idle
  /// with noWork. The user closed the root in the first agent, so the call of the child is final
  /// and nothing is driven again.
  @Test
  func aResumedRootWithNoRestoredRunSaysIdleWithNoWork() async throws {
    let recording = try await ResumeNestedSessionsTests.recordClosedChain()
    let wire = try await Self.resume(recording, settledBy: nil)

    let state = try #require(wire.ownStates(of: recording.root).last, "\(wire.traceDescription)")

    #expect(state.saysNoWork, "\(wire.traceDescription)")
    await wire.fixture.close()
  }
}

extension WireTraceEvent {
  /// The state of this event when it is a `state_update` on the stream of `session`.
  ///
  /// - Parameter session: The session.
  /// - Returns: The state, or `nil` for any other event.
  fileprivate func ownState(of session: SessionId) -> StateUpdate? {
    guard case .update(session, .stateUpdate(let state)) = self else {
      return nil
    }
    return state
  }

  /// The state of this event when it is an announcement of `child` that carries a state.
  ///
  /// - Parameter child: The child.
  /// - Returns: The state, or `nil` for any other event.
  fileprivate func announcedState(of child: SessionId) -> StateUpdate? {
    guard case .update(_, let update) = self, let announcement = update.announcement,
      announcement.sessionId == child, case .value(let state) = announcement.state
    else {
      return nil
    }
    return state
  }
}

extension StateUpdate {
  /// Whether this state is `running`.
  fileprivate var isRunning: Bool {
    if case .running = self {
      return true
    }
    return false
  }

  /// Whether this state is an `idle` that says that the session has no work.
  fileprivate var saysNoWork: Bool {
    if case .idle(let idle) = self {
      return idle.saysNoWork
    }
    return false
  }

  /// The background list of this state, or an empty list for a state with none.
  fileprivate var backgroundList: [BackgroundWork] {
    switch self {
    case .running(let running):
      return running.background ?? []
    case .idle(let idle):
      return idle.background ?? []
    case .requiresAction(let action):
      return action.background ?? []
    case .unknown:
      return []
    }
  }
}
