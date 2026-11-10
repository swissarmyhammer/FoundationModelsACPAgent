import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// A cold `session/resume` restores a nested run that a kill cut after its announcement and
/// before the pump of its session took its task prompt (task ^yjj4mr5).
///
/// The Router records the first prompt of a session only when the pump of the session takes the
/// mail of the prompt (the `promptStarted` marker). The run is announced before that take. A kill
/// in that window leaves a session with no Router prompt. FoundationModelsAgents thus writes the
/// task prompt of a run to `task-prompt.md` in its session folder before the announcement, and
/// the restore reads that record. The record is under the recording root of the runs, which
/// ACPAgent gives to the runner through ``AgentRunHost``.
///
/// No seam holds the pump before the take. So the first agent holds the grandchild in its first
/// pass before any model output, kills the process, and the test removes the prompt records of
/// the Router from the transcript of the grandchild. That is the state on disk of a kill before
/// the take. The grandchild signals its first pass through a named pipe, so no wait uses a clock.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct TaskPromptRecordRestoreTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "TaskPromptRecordRestoreTests"

  /// The name of the named pipe that the grandchild writes when its first pass starts.
  private static let signalPipeName = "leaf-started.fifo"

  /// The text that the grandchild writes to the pipe.
  private static let signalText = "started"

  /// The name of the task prompt record of a run in its session folder (`AgentTaskPromptRecord`
  /// of FoundationModelsAgents).
  private static let taskPromptRecordName = "task-prompt.md"

  /// The body of the grandchild agent at the restore. `$ARGUMENTS` renders as the task prompt,
  /// so the instructions of the restored session show the prompt that the restore used.
  private static let leafBody = "Do the task: $ARGUMENTS"

  /// The kinds of the transcript events that hold a prompt for the Router: the marker that the
  /// pump writes when it takes the mail, and the entry at the end of the submission.
  private static let routerPromptKinds: Set<String> = [
    TranscriptEvent.Kind.promptStarted.rawValue, TranscriptEvent.Kind.prompt.rawValue,
  ]

  /// A resumed root in a second agent.
  private struct Resumed {
    /// The second agent, with its wire.
    let fixture: ScriptedPromptFixture

    /// The chain that the resume restored.
    let recording: ResumeNestedSessionsTests.Recording

    /// The table of the sessions of the second agent.
    var sessions: [SessionId: ActiveSession] {
      get async { await fixture.harness.agent.sessions }
    }

    /// The children that the restore of the root did not restore.
    var failed: [FailedChild]? {
      get async { await sessions[recording.root]?.nestedRestore?.failed }
    }
  }

  // MARK: - Fixtures

  /// Records the chain of three sessions, and kills the first agent after the announcement of the
  /// grandchild and before the grandchild played model output. Then the test removes the prompt
  /// records of the Router from the transcript of the grandchild, and gives the grandchild agent
  /// a body that shows its task prompt.
  ///
  /// - Returns: The chain.
  /// - Throws: Whatever the fixture, a wait or a file operation throws.
  private static func recordCutChain() async throws -> ResumeNestedSessionsTests.Recording {
    let gate = try NamedPipe.makeDirectory(holding: signalPipeName, label: "\(label)-gate")
    let pipe = gate.appendingPathComponent(signalPipeName)
    let signal = try NamedPipeSignal(pipe: pipe)
    let play = ResumeNestedSessionsTests.LeafPlay(
      steps: [
        .writeFile(path: pipe.path, text: signalText), .holdUntilReleased(ScriptedHold()), .endPass,
      ],
      sign: "the announcement of the grandchild"
    ) { updates, root in
      AnnouncedChild.first(in: updates, on: root)
        .flatMap { AnnouncedChild.first(in: updates, on: $0) } != nil
    }
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain(leafPlay: play) {
      try await signal.wait()
    }
    try removeRouterPrompts(of: recording.leaf, in: recording.cwd)
    try AgentsToolTests.writeAgent(
      named: ResumeNestedSessionsTests.leafAgent, in: recording.cwd, body: leafBody)
    return recording
  }

  /// The file `name` in the session folder of `session` under the project recording root.
  ///
  /// - Parameters:
  ///   - name: The name of the file.
  ///   - session: The session.
  ///   - cwd: The working directory of the chain.
  /// - Returns: The file URL, whether or not anything stands there.
  /// - Throws: When the dotfolder name of the harness is refused.
  private static func sessionFile(
    named name: String, of session: SessionId, in cwd: URL
  ) throws -> URL {
    RecordedSessionFiles.fileURL(
      named: name, ofSession: session.rawValue,
      under: try ResumeSessionFixture.projectRecordingRoot(of: cwd))
  }

  /// Removes each event that holds a prompt for the Router from the transcript of `session`.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - cwd: The working directory of the chain.
  /// - Throws: An issue when the transcript holds no such event, or the read, decode or write
  ///   error.
  private static func removeRouterPrompts(of session: SessionId, in cwd: URL) throws {
    let file = try sessionFile(named: RecordedTranscriptFile.fileName, of: session, in: cwd)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    let decoder = JSONDecoder()
    let kept = try lines.filter { line in
      let event = try decoder.decode(RecordedTranscriptLine.self, from: Data(line.utf8))
      return !routerPromptKinds.contains(event.kind)
    }
    try #require(kept.count < lines.count)
    try kept.map { "\($0)\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
  }

  /// Resumes the root of `recording` in a second agent over the same working directory.
  ///
  /// - Parameter recording: The chain that the first agent recorded.
  /// - Returns: The second agent with the resumed root.
  /// - Throws: Whatever the fixture or the resume throws.
  private static func resume(_ recording: ResumeNestedSessionsTests.Recording) async throws
    -> Resumed
  {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-second", workingDirectory: recording.cwd)
    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)
    return Resumed(fixture: fixture, recording: recording)
  }

  /// The instructions of the Router session of `session` in `resumed`.
  ///
  /// - Parameters:
  ///   - session: A restored session.
  ///   - resumed: The resumed root.
  /// - Returns: The instructions, or `nil` when the session has none.
  /// - Throws: An issue when the session is not restored.
  private static func instructions(
    of session: SessionId, in resumed: Resumed
  ) async throws -> String? {
    let entry = try #require(await resumed.sessions[session])
    return try #require(entry.session as? RoutedSessionActor).instructions
  }

  // MARK: - The record

  /// The run of the grandchild wrote its task prompt to its session folder before the kill.
  @Test
  func theTaskPromptRecordIsOnDiskAfterTheAnnouncement() async throws {
    let recording = try await Self.recordCutChain()
    let record = try Self.sessionFile(
      named: Self.taskPromptRecordName, of: recording.leaf, in: recording.cwd)

    #expect(try String(contentsOf: record, encoding: .utf8) == ResumeNestedSessionsTests.leafPrompt)
  }

  // MARK: - The restore

  /// The grandchild comes back as a session nested in the child.
  @Test
  func theCutRunIsRestored() async throws {
    let resumed = try await Self.resume(try await Self.recordCutChain())
    let recording = resumed.recording

    #expect(await resumed.sessions[recording.leaf]?.parentSessionId == recording.child)
    await resumed.fixture.close()
  }

  /// The restored grandchild has its task prompt: its instructions render the prompt as
  /// `$ARGUMENTS`.
  @Test
  func theCutRunIsRestoredWithItsTaskPrompt() async throws {
    let resumed = try await Self.resume(try await Self.recordCutChain())

    let instructions = try await Self.instructions(of: resumed.recording.leaf, in: resumed)

    #expect(instructions?.contains(ResumeNestedSessionsTests.leafPrompt) == true)
    await resumed.fixture.close()
  }

  /// The restore of the root records no failed child, thus no announcement carries a
  /// `restoreFailure` with ``FailedChild/promptNotRecordedReason``.
  @Test
  func theRestoreRecordsNoFailedChild() async throws {
    let resumed = try await Self.resume(try await Self.recordCutChain())

    #expect(await resumed.failed?.isEmpty == true)
    await resumed.fixture.close()
  }

  /// The control: with no task prompt record, the cut grandchild has no recorded prompt, and the
  /// restore fails it with ``FailedChild/promptNotRecordedReason``. So the record is the source
  /// of the prompt in the tests above.
  @Test
  func withoutTheRecordTheCutRunFailsWithNoPrompt() async throws {
    let recording = try await Self.recordCutChain()
    try FileManager.default.removeItem(
      at: try Self.sessionFile(
        named: Self.taskPromptRecordName, of: recording.leaf, in: recording.cwd))

    let resumed = try await Self.resume(recording)

    #expect(await resumed.failed?.map(\.reason) == [FailedChild.promptNotRecordedReason])
    await resumed.fixture.close()
  }
}
