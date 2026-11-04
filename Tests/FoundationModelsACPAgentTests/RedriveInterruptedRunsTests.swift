import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// A cold `session/resume` starts the interrupted nested runs again, after the response and after
/// the snapshots of the children, the children before their callers. The first agent records a
/// chain of three sessions (root, child, grandchild) and ends with the orderly shutdown, so the
/// `agents` calls stay paused. A second agent resumes the root. Its model answers the first
/// message of a restored run with a marker text.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct RedriveInterruptedRunsTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "RedriveInterruptedRunsTests"

  /// The text that the model of the second agent plays when a restored run starts.
  private static let redriveText = "REDRIVEN-RUN-TEXT"

  /// The start of the first message of a restored run (the Agents package writes it).
  private static let restoredRunMessage = "The process stopped while you worked"

  /// The seconds that a test waits for the re-drive after the response.
  private static let redriveWaitSeconds = 30

  /// The most polls of a journal in a test.
  private static let journalPollLimit = 1000

  /// The time between two polls of a journal.
  private static let journalPollInterval = Duration.milliseconds(20)

  /// The wire of one resume with a re-drive.
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

    /// The position of the first re-drive text on the stream of `session`, or `nil`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The position in the trace.
    func firstRedriveText(of session: SessionId) -> Int? {
      trace.firstIndex {
        $0.isAgentText(containing: RedriveInterruptedRunsTests.redriveText, on: session)
      }
    }

    /// The position of the first announcement of `child` after the response, or `nil`.
    ///
    /// - Parameter child: The child.
    /// - Returns: The position in the trace.
    func snapshotPosition(of child: SessionId) -> Int? {
      trace.indices.first { position in
        position > responsePosition && trace[position].announces(child)
      }
    }

    /// The position of the first running `state_update` on the stream of `session`, or `nil`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The position in the trace.
    func firstRunning(of session: SessionId) -> Int? {
      trace.firstIndex { $0.isRunningState(on: session) }
    }

    /// The ids of the calls that completed on the stream of `session` with no earlier in-progress
    /// or paused update of the same call on that stream. Such a completion is a stray call for the
    /// client: the call it knows stays open.
    ///
    /// - Parameter session: The session.
    /// - Returns: The ids of the stray completions, in wire order.
    func strayCompletions(on session: SessionId) -> [ToolCallId] {
      var open: Set<ToolCallId> = []
      var stray: [ToolCallId] = []
      for event in trace {
        guard case .update(session, .toolCallUpdate(let call)) = event else {
          continue
        }
        switch call.status {
        case .value(.completed):
          if !open.contains(call.toolCallId) {
            stray.append(call.toolCallId)
          }
        case .value(.inProgress), .value(.paused):
          open.insert(call.toolCallId)
        default:
          break
        }
      }
      return stray
    }

    /// The position of the first `completed` update of any call on the stream of `session`, or
    /// `nil` when no call completed.
    ///
    /// - Parameter session: The session.
    /// - Returns: The position in the trace.
    func firstCompletion(on session: SessionId) -> Int? {
      trace.firstIndex { event in
        guard case .update(session, .toolCallUpdate(let call)) = event else {
          return false
        }
        return call.status == .value(.completed)
      }
    }

    /// The position of the first in-progress or paused update of any call on the stream of
    /// `session`, or `nil`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The position in the trace.
    func firstOpenCall(on session: SessionId) -> Int? {
      trace.firstIndex { event in
        guard case .update(session, .toolCallUpdate(let call)) = event else {
          return false
        }
        return call.status == .value(.inProgress) || call.status == .value(.paused)
      }
    }
  }

  /// What the read of the wire saw of the restored sessions.
  private struct RedriveSeen {
    /// The sessions that played the marker text.
    var spoken: Set<SessionId> = []

    /// The sessions that showed the state `running`.
    var running: Set<SessionId> = []

    /// Whether a call completed on the stream of the root.
    var rootCallCompleted = false

    /// Notes what `event` shows of `session`.
    ///
    /// - Parameters:
    ///   - event: The event of the wire.
    ///   - session: The session to look at.
    mutating func note(_ event: WireTraceEvent, on session: SessionId) {
      if event.isAgentText(containing: RedriveInterruptedRunsTests.redriveText, on: session) {
        spoken.insert(session)
      }
      if event.isRunningState(on: session) {
        running.insert(session)
      }
    }

    /// Notes that a call completed on the stream of `root`.
    ///
    /// - Parameters:
    ///   - event: The event of the wire.
    ///   - root: The root session.
    mutating func noteCompletion(_ event: WireTraceEvent, on root: SessionId) {
      if case .update(root, .toolCallUpdate(let call)) = event, call.status == .value(.completed) {
        rootCallCompleted = true
      }
    }

    /// Whether every one of `sessions` spoke and ran, and the call of the root completed when the
    /// read waits for it.
    ///
    /// - Parameters:
    ///   - sessions: The restored sessions.
    ///   - needsCompletion: Whether the read waits for the completion of a call of the root.
    /// - Returns: `true` when the read has all it needs.
    func isComplete(for sessions: [SessionId], needsCompletion: Bool = false) -> Bool {
      spoken.isSuperset(of: sessions) && running.isSuperset(of: sessions)
        && (rootCallCompleted || !needsCompletion)
    }
  }

  // MARK: - Fixtures

  /// Starts the second agent over the working directory of `recording`. The model plays the
  /// marker text when it gets the first message of a restored run.
  ///
  /// - Parameter recording: The chain that the first agent recorded.
  /// - Returns: The second agent.
  /// - Throws: Whatever the fixture throws.
  private static func secondAgent(
    for recording: ResumeNestedSessionsTests.Recording
  ) async throws -> ScriptedPromptFixture {
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: restoredRunMessage, play: [.textDelta(redriveText), .endPass]),
      .endPass,
    ]
    return try await ScriptedPromptFixture.make(
      script: script, label: "\(label)-second", workingDirectory: recording.cwd)
  }

  /// Resumes the root of `recording` in a second agent and reads the wire until both restored
  /// sessions played the marker text and showed the state `running`. A missing text ends the read at the timeout.
  ///
  /// - Parameters:
  ///   - recording: The chain that the first agent recorded.
  ///   - untilRootCallCompletes: Whether the read also waits for a completed call on the root.
  ///   - replaying: Whether the request asks for the replay of the history.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resumeAndRedrive(
    _ recording: ResumeNestedSessionsTests.Recording, untilRootCallCompletes: Bool = false,
    replaying: Bool = false
  ) async throws -> Wire {
    let fixture = try await secondAgent(for: recording)
    let connection = fixture.harness.connection
    let subscription = connection.subscribeToAllSessions()
    let first = WireTraceEvent.resumeRequest(id: .number(1), sessionId: recording.root)
    let sessions = [recording.child, recording.leaf]
    let seen = Mutex(RedriveSeen())
    var request = ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root)
    if replaying {
      request.replayFrom = .start(ReplayFromStart())
    }
    let sentRequest = request
    let trace = try await subscription.readResumeTrace(
      startingWith: [first], settledBy: { event in
        seen.withLock { seen in
          for session in sessions {
            seen.note(event, on: session)
          }
          seen.noteCompletion(event, on: recording.root)
          return seen.isComplete(for: sessions, needsCompletion: untilRootCallCompletes)
        }
      }, timeout: .seconds(redriveWaitSeconds)
    ) {
      _ = try await connection.resumeSession(sentRequest)
    }
    return Wire(fixture: fixture, recording: recording, trace: trace)
  }

  /// Records the chain with the orderly shutdown and resumes it with a re-drive.
  ///
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func redriveShutDownChain() async throws -> Wire {
    try await resumeAndRedrive(try await ResumeNestedSessionsTests.recordShutDownChain())
  }

  /// Waits until the journal of `session` holds the completed outcome of a call, and returns the
  /// outcomes of all the completed calls.
  ///
  /// - Parameters:
  ///   - session: The caller session.
  ///   - fixture: The second agent.
  ///   - isMet: Tells whether the outcomes are the ones that the test waits for.
  /// - Returns: The outcomes of the completed calls of the journal at the end of the wait.
  /// - Throws: An issue when `session` is no ULID, the read error of the journal, or the cancel of
  ///   the sleep.
  private static func completedOutcomes(
    of session: SessionId, on fixture: ScriptedPromptFixture,
    until isMet: ([OperationOutcome]) -> Bool
  ) async throws -> [OperationOutcome] {
    let id = try #require(ULID(ulidString: session.rawValue))
    let directory = fixture.harness.agent.sessionDirectory
    var outcomes: [OperationOutcome] = []
    for _ in 0..<journalPollLimit {
      let statuses = try await directory.runStatuses(of: id)
      outcomes = statuses.values.compactMap { status in
        if case .completed(let outcome) = status {
          return outcome
        }
        return nil
      }
      if isMet(outcomes) {
        break
      }
      try await Task.sleep(for: journalPollInterval)
    }
    return outcomes
  }

  /// Removes each retained history file under `directory`, as a kill during a prompt leaves the
  /// folders.
  ///
  /// - Parameter directory: The working directory of the chain.
  /// - Throws: Whatever the removal throws.
  private static func removeHistoryFiles(under directory: URL) throws {
    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      if file.lastPathComponent == SessionHistoryFile.fileName {
        try FileManager.default.removeItem(at: file)
      }
    }
  }

  // MARK: - The re-drive

  /// The restored child works again: it plays the first message of a restored run.
  @Test
  func theRestoredChildRunsAgain() async throws {
    let wire = try await Self.redriveShutDownChain()

    #expect(wire.firstRedriveText(of: wire.recording.child) != nil)
    await wire.fixture.close()
  }

  /// The restored grandchild works again too.
  @Test
  func theRestoredGrandchildRunsAgain() async throws {
    let wire = try await Self.redriveShutDownChain()

    #expect(wire.firstRedriveText(of: wire.recording.leaf) != nil)
    await wire.fixture.close()
  }

  /// A child starts before its caller: the grandchild shows `running` before the child plays its
  /// first text. (The first text of a session comes when its first pass ends, so it is the first
  /// sign of the work of a caller on the wire.)
  @Test
  func theChildrenStartBeforeTheirCallers() async throws {
    let wire = try await Self.redriveShutDownChain()
    let leafRuns = try #require(wire.firstRunning(of: wire.recording.leaf))
    let childWorks = try #require(wire.firstRedriveText(of: wire.recording.child))

    #expect(leafRuns < childWorks)
    await wire.fixture.close()
  }

  /// No re-driven session sends its work before the response of the resume.
  @Test
  func noRedrivenChildWorksBeforeTheResponse() async throws {
    let wire = try await Self.redriveShutDownChain()
    let first = try #require(
      [wire.recording.child, wire.recording.leaf].compactMap(wire.firstRedriveText(of:)).min())

    #expect(first > wire.responsePosition)
    await wire.fixture.close()
  }

  /// The snapshot of a child goes out before its work: a delayed snapshot cannot overwrite a newer
  /// state.
  @Test
  func theSnapshotOfAChildPrecedesItsWork() async throws {
    let wire = try await Self.redriveShutDownChain()
    let snapshot = try #require(wire.snapshotPosition(of: wire.recording.leaf))
    let work = try #require(wire.firstRedriveText(of: wire.recording.leaf))

    #expect(snapshot < work)
    await wire.fixture.close()
  }

  /// The client sees the state `running` on the stream of each re-driven session before the
  /// session plays its first text.
  @Test(arguments: [true, false])
  func eachRedrivenSessionShowsRunningBeforeItWorks(isLeaf: Bool) async throws {
    let wire = try await Self.redriveShutDownChain()
    let session = isLeaf ? wire.recording.leaf : wire.recording.child
    let running = try #require(wire.firstRunning(of: session))
    let works = try #require(wire.firstRedriveText(of: session))

    #expect(running < works)
    await wire.fixture.close()
  }

  // MARK: - The original call

  /// The end of the re-driven child completes its original `start agent` call in the journal of
  /// its caller. The call does not end as `lost`.
  @Test
  func theEndOfTheChildCompletesTheOriginalCall() async throws {
    let wire = try await Self.redriveShutDownChain()

    let outcomes = try await Self.completedOutcomes(of: wire.recording.root, on: wire.fixture) {
      $0.contains(.succeeded)
    }

    #expect(outcomes.contains(.succeeded))
    #expect(!outcomes.contains(.lost))
    await wire.fixture.close()
  }

  /// The original call on the wire (task acceptance 4): the client sees the `agents` call of the
  /// root open, and its completion comes on the id of that call. A completion on another id would
  /// leave the original call open for the client.
  @Test
  func theCompletionOfTheRootCallHasNoStrayId() async throws {
    let wire = try await Self.resumeAndRedrive(
      try await ResumeNestedSessionsTests.recordShutDownChain(), untilRootCallCompletes: true,
      replaying: true)

    _ = try #require(wire.firstCompletion(on: wire.recording.root))
    #expect(wire.strayCompletions(on: wire.recording.root).isEmpty)
    await wire.fixture.close()
  }

  /// The same, when the history file of the sessions is gone, as after a kill during the prompt
  /// (the file is written at the end of a prompt). The replay then builds the open call from the
  /// journal, and it comes before the response.
  @Test
  func theReplayOpensTheOriginalCallWhenNoHistoryWasWritten() async throws {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    try Self.removeHistoryFiles(under: recording.cwd)
    let wire = try await Self.resumeAndRedrive(recording, untilRootCallCompletes: true, replaying: true)
    let opened = try #require(wire.firstOpenCall(on: wire.recording.root))

    #expect(opened < wire.responsePosition)
    _ = try #require(wire.firstCompletion(on: wire.recording.root))
    #expect(wire.strayCompletions(on: wire.recording.root).isEmpty)
    #expect(SubagentWireTraceValidator().validate(wire.trace) == [])
    await wire.fixture.close()
  }

  // MARK: - A child that cannot be re-driven

  /// A child whose definition is gone cannot run again. Its original call ends as `lost`, and the
  /// root still resumes.
  @Test
  func aChildThatCannotRestoreEndsItsCallAsLost() async throws {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    try AgentsToolTests.removeAgent(named: ResumeNestedSessionsTests.childAgent, in: recording.cwd)
    let fixture = try await Self.secondAgent(for: recording)

    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)
    let outcomes = try await Self.completedOutcomes(of: recording.root, on: fixture) {
      $0.contains(.lost)
    }

    #expect(outcomes.contains(.lost))
    #expect(await fixture.harness.agent.sessions[recording.root] != nil)
    await fixture.close()
  }
}

extension WireTraceEvent {
  /// Whether this event is a running `state_update` on the stream of `session`.
  ///
  /// - Parameter session: The session.
  /// - Returns: `true` for a running state on that stream.
  fileprivate func isRunningState(on session: SessionId) -> Bool {
    guard case .update(let stream, let update) = self, stream == session,
      case .stateUpdate(.running) = update
    else {
      return false
    }
    return true
  }

  /// Whether this event is an announcement of `child`.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` for a `subagent_update` that names `child`.
  fileprivate func announces(_ child: SessionId) -> Bool {
    if case .update(_, let update) = self {
      return update.announces(child)
    }
    return false
  }
}
