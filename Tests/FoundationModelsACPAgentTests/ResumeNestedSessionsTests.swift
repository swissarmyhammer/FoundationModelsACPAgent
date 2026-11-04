import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// A cold `session/resume` restores the recorded nested sessions of the root, not only the root.
/// The first agent records a chain of three sessions (root, child, grandchild) and stops while the
/// child and the grandchild work. A second agent resumes the root. The restored sessions come back
/// idle, and the re-drive starts their runs after the response (``RedriveInterruptedRunsTests``).
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ResumeNestedSessionsTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ResumeNestedSessionsTests"

  /// The agent that the root session starts.
  static let childAgent = "worker"

  /// The agent that the child starts.
  private static let leafAgent = "leaf"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-RESUME-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-RESUME-MARKER"

  /// The marker of the prompt of the grandchild.
  private static let leafPrompt = "LEAF-RESUME-MARKER"

  /// The first text of the grandchild. The recording of the chain is complete when it is out.
  private static let leafStartedText = "LEAF-STARTED-TEXT"

  /// A tool of the default tool set that the test denies to the grandchild after the recording.
  private static let deniedTool = "runCode"

  /// A tool that stays in the default tool set of the grandchild.
  private static let keptTool = "searchTools"

  /// The most polls of a ledger while a re-driven run ends.
  private static let idlePollLimit = 1000

  /// The time between two polls of a ledger.
  private static let idlePollInterval = Duration.milliseconds(20)

  /// The chain that the first agent recorded.
  struct Recording {
    /// The working directory of the chain.
    let cwd: URL

    /// The root session.
    let root: SessionId

    /// The session that the root started.
    let child: SessionId

    /// The session that the child started.
    let leaf: SessionId
  }

  /// A resumed root in a second agent.
  private struct Resumed {
    /// The second agent, with its wire.
    let fixture: ScriptedPromptFixture

    /// The chain that the resume restored.
    let recording: Recording

    /// The table of the sessions of the second agent.
    var sessions: [SessionId: ActiveSession] {
      get async { await fixture.harness.agent.sessions }
    }
  }

  // MARK: - Fixtures

  /// Records a chain of three sessions and kills the first agent while the child and the
  /// grandchild work. The history of each session is on disk as the end of a prompt writes it,
  /// with every `agents` call open. A hard kill ends the process at once: it ends no prompt and
  /// marks no call as final. The sessions are suspended, so the journal refuses a terminal event
  /// and the runs stay orphans. The first agent is never closed, so nothing writes after the kill.
  ///
  /// - Returns: The chain.
  /// - Throws: Whatever the fixture or a wait throws.
  static func recordInterruptedChain() async throws -> Recording {
    try await recordChain(endsPrompt: false) { fixture in
      let agent = fixture.harness.agent
      for sessionId in await agent.sessions.keys {
        await agent.writeHistory(of: sessionId)
      }
      await suspendAll(of: agent)
    }
  }

  /// Records the chain, and ends the first agent with the orderly shutdown of the process
  /// (``RoutedACPAgent/shutdown()``). The shutdown cancels nothing: it pauses the open `agents`
  /// call of each session, so the history of the chain holds no final status for them, and the
  /// journal of the run stays an orphan. The history of the chain is written, so a replay finds
  /// it.
  ///
  /// - Returns: The chain.
  /// - Throws: Whatever the fixture or a wait throws.
  static func recordShutDownChain() async throws -> Recording {
    try await recordChain { fixture in
      await fixture.harness.agent.shutdown()
      await fixture.harness.close()
    }
  }

  /// Records the chain, and ends the first agent with a user `session/close` of the root. The
  /// close cancels the open prompt, so the history of the root holds the final status
  /// `cancelled` for the `agents` call of the child. The history of the chain is written, so a
  /// replay finds it.
  ///
  /// - Returns: The chain.
  /// - Throws: Whatever the fixture or a wait throws.
  static func recordClosedChain() async throws -> Recording {
    try await recordChain { fixture in
      _ = try? await fixture.harness.connection.closeSession(
        CloseSessionRequest(sessionId: fixture.sessionId))
      await fixture.harness.close()
    }
  }

  /// Records the chain of three sessions, and ends the first agent while the child and the
  /// grandchild work.
  ///
  /// - Parameters:
  ///   - endsPrompt: Whether the prompt of the root ends with the stop. A killed process never
  ///     ends it, so the call does not wait for it.
  ///   - stopping: Ends the first agent.
  /// - Returns: The chain.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func recordChain(
    endsPrompt: Bool = true, stopping: (ScriptedPromptFixture) async -> Void
  ) async throws -> Recording {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(
      named: childAgent, in: cwd, tools: AgentsToolTests.agentsToolName)
    try AgentsToolTests.writeAgent(named: leafAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: leafPrompt,
        play: [.textDelta(leafStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: childPrompt,
        play: [AgentsToolTests.startAgentCall(agent: leafAgent, prompt: leafPrompt), .endPass]),
      .onPrompt(
        containing: rootPrompt,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childPrompt), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootPrompt))
    }
    let updates = try await fixture.collector.wait(for: "the first text of the grandchild") {
      updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(leafStartedText)
    }
    let child = try #require(AnnouncedChild.first(in: updates, on: root))
    let leaf = try #require(AnnouncedChild.first(in: updates, on: child))
    await stopping(fixture)
    if endsPrompt {
      _ = try? await prompt.value
    }
    return Recording(cwd: cwd, root: root, child: child, leaf: leaf)
  }

  /// Quits an agent in order: it suspends every live session, and then closes them. A suspended
  /// session gets no ended marker, so the runs that the quit stops stay restorable.
  ///
  /// - Parameter fixture: The agent to quit.
  private static func quit(_ fixture: ScriptedPromptFixture) async {
    await suspendAll(of: fixture.harness.agent)
    await fixture.close()
  }

  /// Suspends every live session of an agent. A suspended session gets no ended marker. It does
  /// not close the sessions.
  ///
  /// - Parameter agent: The agent whose sessions are suspended.
  private static func suspendAll(of agent: RoutedACPAgent) async {
    for entry in await agent.sessions.values {
      entry.session.suspend()
    }
  }

  /// Resumes the root of `recording` in a second agent over the same working directory.
  ///
  /// - Parameter recording: The chain that the first agent recorded.
  /// - Returns: The second agent with the resumed root.
  /// - Throws: Whatever the fixture or the resume throws.
  private static func resume(_ recording: Recording) async throws -> Resumed {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-second", workingDirectory: recording.cwd)
    try await resumeRoot(of: recording, on: fixture)
    return Resumed(fixture: fixture, recording: recording)
  }

  /// Sends `session/resume` for the root of `recording`.
  ///
  /// - Parameters:
  ///   - recording: The chain that the first agent recorded.
  ///   - fixture: The second agent.
  /// - Throws: Whatever the request throws.
  static func resumeRoot(
    of recording: Recording, on fixture: ScriptedPromptFixture
  ) async throws {
    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root))
  }

  /// Waits until the ledger of `session` reports idle. The re-driven run of the session ends
  /// on its own, so the wait uses a poll with a limit.
  ///
  /// - Parameter session: The restored session.
  /// - Throws: An issue when the ledger stays busy for the whole wait.
  private static func waitUntilIdle(_ session: ActiveSession) async throws {
    try await pollUntil(limit: idlePollLimit, interval: idlePollInterval) {
      await session.stateLedger.isIdle
    }
    try #require(await session.stateLedger.isIdle)
  }

  /// The names of the tools that the session offers to its model. The recorded names are in the
  /// `index.md` and in the transcript, so the test reads the tools that the restore gave the
  /// Router session.
  ///
  /// - Parameter session: The session.
  /// - Returns: The names.
  private static func toolNames(of session: ActiveSession) throws -> Set<String> {
    let actor = try #require(session.session as? RoutedSessionActor)
    return Set(actor.tools.map(\.name))
  }

  // MARK: - The tree

  /// The child and the grandchild come back as sessions, each with its parent.
  @Test
  func aColdResumeRestoresTheChainWithEachParent() async throws {
    let resumed = try await Self.resume(try await Self.recordInterruptedChain())
    let recording = resumed.recording

    let sessions = await resumed.sessions

    #expect(sessions[recording.child]?.parentSessionId == recording.root)
    #expect(sessions[recording.leaf]?.parentSessionId == recording.child)
    #expect(sessions[recording.root]?.children == [recording.child])
    await resumed.fixture.close()
  }

  /// Every restored session is idle again when its re-driven run ends: the ledger of the session
  /// does not stay busy after the re-drive.
  @Test
  func everyRestoredChildIsIdleWhenItsRedrivenRunEnds() async throws {
    let resumed = try await Self.resume(try await Self.recordInterruptedChain())
    let recording = resumed.recording

    let sessions = await resumed.sessions
    let child = try #require(sessions[recording.child])
    let leaf = try #require(sessions[recording.leaf])
    try await Self.waitUntilIdle(child)
    try await Self.waitUntilIdle(leaf)

    #expect(await child.stateLedger.isIdle)
    #expect(await leaf.stateLedger.isIdle)
    await resumed.fixture.close()
  }

  /// The ACP id of a restored child is its Router id, and it is the same in the next process: the
  /// second agent quits, and a third agent resumes the same root.
  @Test
  func theIdsOfTheChildrenAreTheSameAfterASecondResume() async throws {
    let recording = try await Self.recordInterruptedChain()
    await Self.quit(try await Self.resume(recording).fixture)

    let third = try await Self.resume(recording)
    let sessions = await third.sessions

    #expect(sessions[recording.child]?.parentSessionId == recording.root)
    #expect(sessions[recording.leaf]?.parentSessionId == recording.child)
    await third.fixture.close()
  }

  // MARK: - The tools

  /// A restored child has the tools of the current definition. The recording gave the grandchild
  /// all the default tools. The definition denies one of them before the resume.
  @Test
  func aRestoredChildFollowsTheCurrentDisallowedTools() async throws {
    let recording = try await Self.recordInterruptedChain()
    try AgentsToolTests.writeAgent(
      named: Self.leafAgent, in: recording.cwd, disallowedTools: Self.deniedTool)

    let resumed = try await Self.resume(recording)
    let leaf = try #require(await resumed.sessions[recording.leaf])
    let names = try Self.toolNames(of: leaf)

    #expect(!names.contains(Self.deniedTool))
    #expect(names.contains(Self.keptTool))
    await resumed.fixture.close()
  }

  // MARK: - A child that does not restore

  /// A child whose definition is gone is not restored, and the root still resumes. The
  /// grandchild of that child has no caller to return to, so it is not restored either.
  @Test
  func aChildWhoseDefinitionIsGoneIsNotRestoredAndTheRootResumes() async throws {
    let recording = try await Self.recordInterruptedChain()
    try AgentsToolTests.removeAgent(named: Self.childAgent, in: recording.cwd)

    let resumed = try await Self.resume(recording)
    let sessions = await resumed.sessions

    #expect(sessions[recording.root] != nil)
    #expect(sessions[recording.child] == nil)
    #expect(sessions[recording.leaf] == nil)
    await resumed.fixture.close()
  }

  /// The failure of the child is kept on the root for the child sync task.
  @Test
  func theFailureOfAChildIsKeptOnTheRoot() async throws {
    let recording = try await Self.recordInterruptedChain()
    try AgentsToolTests.removeAgent(named: Self.childAgent, in: recording.cwd)

    let resumed = try await Self.resume(recording)
    let failed = await resumed.sessions[recording.root]?.nestedRestore?.failed

    #expect(
      failed?.map(\.child.sessionID.description) == [
        recording.child.rawValue, recording.leaf.rawValue,
      ])
    await resumed.fixture.close()
  }

  // MARK: - The close

  /// `session/close` of the root closes the restored children.
  @Test
  func closingTheRootClosesTheRestoredChildren() async throws {
    let resumed = try await Self.resume(try await Self.recordInterruptedChain())
    let recording = resumed.recording
    try #require(await resumed.sessions[recording.child] != nil)
    try #require(await resumed.sessions[recording.leaf] != nil)

    _ = try await resumed.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: recording.root))
    let sessions = await resumed.sessions

    #expect(sessions[recording.child] == nil)
    #expect(sessions[recording.leaf] == nil)
    await resumed.fixture.close()
  }

  // MARK: - The snapshot timeline

  /// The root, the restored child and the restored grandchild share the one snapshot session key
  /// of the project, so the three sessions see one timeline.
  @Test
  func theRestoredSessionsShareTheSnapshotKeyOfTheRoot() async throws {
    let resumed = try await Self.resume(try await Self.recordInterruptedChain())
    let recording = resumed.recording
    let keys = SnapshotSessionKeys.shared

    let rootKey = try #require(keys.sessionKey(of: recording.root.rawValue))

    #expect(keys.sessionKey(of: recording.child.rawValue) == rootKey)
    #expect(keys.sessionKey(of: recording.leaf.rawValue) == rootKey)
    await resumed.fixture.close()
  }
}
