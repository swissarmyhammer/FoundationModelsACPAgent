import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A model slot switch keeps the session id (task ^dtd9gcr). The ACP session
/// is backed by one Router session for its whole life. The switch suspends
/// the Router session and restores it onto the new slot with the same id, so
/// the recording of the session stays in one folder and holds one
/// `modelChanged` event.
///
/// The proofs drive the real agent over scripted models. No weights load.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ModelSlotSwitchSessionIdTests {
  /// The text that the scripted model plays when no test needs another text.
  private static let answer = "the answer"

  /// The text that the flash slot plays in the proof of the open prompt.
  private static let flashAnswer = "flash-answer"

  /// The text that the standard slot plays in the proof of the open prompt.
  private static let standardAnswer = "standard-answer"

  /// The factor that makes the recorded context of a session larger than the
  /// context that the live model resolves.
  private static let recordedContextFactor = 2

  /// The kind string of the event that a restore onto another model writes.
  private static let modelChangedKind = TranscriptEvent.Kind.modelChanged.rawValue

  // MARK: Fixtures

  /// Opens one session over a scripted model.
  ///
  /// - Parameter label: The directory label of the calling test.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction or the handshake throws.
  private static func makeFixture(label: String) async throws -> ScriptedPromptFixture {
    try await ScriptedPromptFixture.make(script: [.textDelta(answer), .endPass], label: label)
  }

  /// The table entry of the session of `fixture`.
  ///
  /// - Parameter fixture: The wired fixture.
  /// - Returns: The entry.
  /// - Throws: A failed requirement when the table has no such session.
  private static func entry(of fixture: ScriptedPromptFixture) async throws -> ActiveSession {
    try #require(await fixture.harness.agent.sessions[fixture.sessionId])
  }

  /// The recording root that holds the folder of the session of `entry`.
  ///
  /// - Parameter entry: The table entry.
  /// - Returns: The recording root.
  private static func recordingRoot(of entry: ActiveSession) -> URL {
    entry.transcriptDirectory.deletingLastPathComponent()
  }

  /// Whether two Router sessions are the same object.
  ///
  /// - Parameters:
  ///   - first: One session.
  ///   - second: The other session.
  /// - Returns: `true` for one object.
  private static func isSameSession(_ first: any RoutedSession, _ second: any RoutedSession)
    -> Bool
  {
    (first as AnyObject) === (second as AnyObject)
  }

  /// Writes a larger context into the `index.md` of the session, as if a
  /// larger model had recorded it.
  ///
  /// - Parameter entry: The table entry of the session.
  /// - Throws: The read or the write error, or a failed requirement when the
  ///   file holds no `context` key.
  private static func recordALargerContext(in entry: ActiveSession) throws {
    let file = RecordedSessionIndexFile.fileURL(
      ofSession: entry.session.id.description, under: recordingRoot(of: entry))
    let text = try String(contentsOf: file, encoding: .utf8)
    let pattern = try Regex(#"(?m)^context: (\d+)$"#)
    let match = try #require(text.firstMatch(of: pattern))
    let recorded = try #require(match.output[1].substring.flatMap { Int($0) })
    let larger = text.replacing(pattern) { _ in
      "context: \(recorded * recordedContextFactor)"
    }
    try larger.write(to: file, atomically: true, encoding: .utf8)
  }

  // MARK: The id

  /// After a switch, the Router session has the id of the ACP session.
  @Test
  func aSlotSwitchKeepsTheRouterSessionId() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-id")

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    await fixture.close()
    #expect(entry.session.id.description == fixture.sessionId.rawValue)
  }

  /// After a switch, the session directory of the router finds the new
  /// session by the id, not the replaced one.
  @Test
  func aSlotSwitchLeavesOnlyTheNewSessionLiveUnderTheId() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-live")
    let replaced = try await Self.entry(of: fixture).session

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    let live = try #require(fixture.harness.agent.sessionDirectory.session(id: replaced.id))
    await fixture.close()
    #expect(Self.isSameSession(live, entry.session))
    #expect(!Self.isSameSession(live, replaced))
  }

  /// The switch suspends the replaced session, so it writes no ended marker.
  @Test
  func aSlotSwitchSuspendsTheReplacedSession() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-suspend")
    let replaced = try await Self.entry(of: fixture).session

    try await fixture.switchModelSlot()

    await fixture.close()
    #expect(replaced.isSuspended)
  }

  // MARK: The commands

  /// After a switch, `/compact` and `/context` act on the restored session,
  /// not on the session that the switch closed.
  @Test
  func aSlotSwitchGivesTheBuiltinCommandsTheRestoredSession() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-commands")

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    let bound = try #require(entry.builtinContext?.binding?.session)
    await fixture.close()
    #expect(Self.isSameSession(bound, entry.session))
  }

  /// A context that no session bound reports that it took no session.
  @Test
  func anUnboundCommandContextReportsThatItTookNoSession() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-unbound")
    let session = try await Self.entry(of: fixture).session
    let context = BuiltinCommandContext(
      workingDirectory: fixture.cwd,
      configuration: AgentConfiguration.withoutMarketplaces,
      instructions: "", modelName: "", profileName: "",
      dotfolderName: try DotfolderName(AgentClientHarness.dotfolderName),
      userLayerRoot: fixture.cwd)

    let took = context.replaceSession(session)

    await fixture.close()
    #expect(!took)
  }

  // MARK: The recording

  /// After a switch, the recording root holds one folder for the session.
  @Test
  func aSlotSwitchKeepsOneRecordingFolder() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-folder")

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    let folders = try RecordedSessionFiles.files(
      named: RecordedSessionIndexFile.fileName, under: Self.recordingRoot(of: entry))
    await fixture.close()
    #expect(folders.count == 1)
  }

  /// After a switch, the transcript of the session holds one `modelChanged`
  /// event.
  @Test
  func aSlotSwitchRecordsOneModelChangedEvent() async throws {
    let fixture = try await Self.makeFixture(label: "ModelSlotSwitchSessionIdTests-event")

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    let lines = try RecordedTranscriptFile.lines(
      under: Self.recordingRoot(of: entry), sessionId: fixture.sessionId)
    await fixture.close()
    #expect(lines.filter { $0.kind == Self.modelChangedKind }.count == 1)
  }

  // MARK: The context

  /// A switch to a context that is smaller than the recorded one compacts
  /// the session: the restore runs no compaction.
  @Test
  func aSlotSwitchToASmallerContextCompacts() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      loader: CompactionStubBackend.makeLoader(shouldFail: false),
      label: "ModelSlotSwitchSessionIdTests-smaller")
    try Self.recordALargerContext(in: try await Self.entry(of: fixture))

    try await fixture.switchModelSlot()

    let updates = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "a compaction entry after the switch"
    ) { updates in
      updates.contains { $0.update.kind == .compactionUpdate }
    }
    await fixture.close()
    #expect(updates.contains { $0.update.kind == .compactionUpdate })
  }

  /// A switch to the same context compacts nothing.
  @Test
  func aSlotSwitchToTheSameContextCompactsNothing() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      loader: CompactionStubBackend.makeLoader(shouldFail: false),
      label: "ModelSlotSwitchSessionIdTests-same")

    try await fixture.switchModelSlot()
    _ = try await ScriptedPromptFixture.runPrompt(on: fixture, text: "after the switch")

    let compactions = await fixture.collector.updates(ofKind: .compactionUpdate)
    await fixture.close()
    #expect(compactions.isEmpty)
  }

  // MARK: The prompt in flight

  /// A switch while a prompt is open lets that prompt end on the session that
  /// took it. The switch then applies, and the session keeps the id.
  @Test
  func aSlotSwitchDuringAPromptKeepsTheIdAfterThePromptEnds() async throws {
    let hold = ScriptedHold()
    var loader = StubModelLoader()
    loader.makeLLMContainer = { slot in
      slot == .flash
        ? ScriptedLLMContainer(script: [.textDelta(Self.flashAnswer), .endPass])
        : ScriptedLLMContainer(script: [
          .holdUntilReleased(hold), .textDelta(Self.standardAnswer), .endPass,
        ])
    }
    let fixture = try await ScriptedPromptFixture.make(
      loader: loader, label: "ModelSlotSwitchSessionIdTests-open")
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "first"))
    try await ScriptedPromptFixture.waitForRunning(fixture.collector)

    try await fixture.switchModelSlot()
    hold.release()
    _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "second"))
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector, count: 2)

    let entry = try await Self.entry(of: fixture)
    await fixture.close()
    #expect(entry.session.id.description == fixture.sessionId.rawValue)
    #expect(ScriptedPromptFixture.agentText(in: updates).contains(Self.flashAnswer))
  }

  // MARK: The child sessions

  /// The agent that the root session starts.
  private static let childAgent = "worker"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-SWITCH-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-SWITCH-MARKER"

  /// The number of session folders of the proof of the child: the root and
  /// its child.
  private static let rootAndChildFolders = 2

  /// A child that ran before the switch stays in the recording tree of the
  /// root, and the root keeps its id: the restore reads the tree with its
  /// recorded child and moves nothing out of the folder of the root.
  @Test
  func aSlotSwitchKeepsTheRecordedChildInTheTreeOfTheRoot() async throws {
    let cwd = makeResolvedDirectory(label: "ModelSlotSwitchSessionIdTests-child-repo")
    try AgentsToolTests.writeAgent(named: Self.childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: Self.childPrompt, play: [.textDelta(Self.answer), .endPass]),
      .onPrompt(
        containing: Self.rootPrompt,
        play: [
          AgentsToolTests.startAgentCall(agent: Self.childAgent, prompt: Self.childPrompt),
          .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: "ModelSlotSwitchSessionIdTests-child", workingDirectory: cwd)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.rootPrompt))
    _ = try await fixture.collector.wait(for: "the final status of the agents call") { updates in
      guard let call = ChildSessionProjectionTests.agentsCall(in: updates, of: fixture.sessionId)
      else { return false }
      return updates.contains {
        $0.sessionId == fixture.sessionId && ChildSessionProjectionTests.isFinal($0.update, of: call)
      }
    }
    await fixture.harness.agent.awaitPromptsFinished(of: fixture.sessionId)

    try await fixture.switchModelSlot()

    let entry = try await Self.entry(of: fixture)
    let folders = try RecordedSessionFiles.files(
      named: RecordedSessionIndexFile.fileName, under: Self.recordingRoot(of: entry))
    await fixture.close()
    #expect(entry.session.id.description == fixture.sessionId.rawValue)
    #expect(folders.count == Self.rootAndChildFolders)
  }
}
