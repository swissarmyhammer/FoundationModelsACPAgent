import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// A tool in a session of `RoutedACPAgent` reads the transcript of another session (task
/// ^zgqxj7z). Each test goes through the agent and its wire, so a call site of the agent that
/// gives no reader makes a test fail.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct AgentTranscriptWiringTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "AgentTranscriptWiringTests"

  /// The marker of the prompt whose answer calls the probe tool.
  private static let probeMarker = "PROBE-TRANSCRIPT-MARKER"

  /// The marker of the prompt that only records a session.
  private static let recordMarker = "RECORD-SESSION-MARKER"

  /// The text that ends each scripted answer.
  private static let answerText = "done"

  /// The script of every session: the answer to ``probeMarker`` calls the probe tool.
  private static let script: [ScriptedPassStep] = [
    .onPrompt(
      containing: probeMarker,
      play: [.toolCall(name: AgentTranscriptProbeTool.toolName, argumentsJSON: "{}"), .endPass]),
    .textDelta(answerText),
    .endPass,
  ]

  /// Makes an agent with one session and the probe tool.
  private static func makeFixture(
    probe: TranscriptProbe, workingDirectory: URL? = nil
  ) async throws -> ScriptedPromptFixture {
    try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: workingDirectory,
      hostTools: [AgentTranscriptProbeTool(probe: probe)])
  }

  /// Sends one prompt and waits until the prompt is done.
  private static func prompt(
    _ text: String, in sessionId: SessionId, on fixture: ScriptedPromptFixture
  ) async throws {
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text))
    await fixture.harness.agent.awaitPromptsFinished(of: sessionId)
  }

  /// Opens a second session in the working directory of the fixture and records it with one prompt.
  private static func recordSecondSession(on fixture: ScriptedPromptFixture) async throws
    -> SessionId
  {
    let second = try await fixture.harness.client.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
    let secondId = await MainActor.run { second.sessionId }
    try await prompt(recordMarker, in: secondId, on: fixture)
    return secondId
  }

  /// Makes the probe read a session.
  private static func aim(_ probe: TranscriptProbe, at sessionId: SessionId) throws {
    probe.target = try #require(ULID(ulidString: sessionId.rawValue))
  }

  // MARK: - session/new

  @Test("a tool in a new session reads another session")
  func newSessionGivesTheReader() async throws {
    let probe = TranscriptProbe()
    let fixture = try await Self.makeFixture(probe: probe)
    let other = try await Self.recordSecondSession(on: fixture)
    try Self.aim(probe, at: other)

    try await Self.prompt(Self.probeMarker, in: fixture.sessionId, on: fixture)

    #expect(probe.outcome.value?.kinds?.contains("prompt") == true)
    await fixture.close()
  }

  @Test("a session in a folder that the project store does not hold reads itself")
  func unregisteredFolderReadsItself() async throws {
    let probe = TranscriptProbe()
    let fixture = try await Self.makeFixture(probe: probe)
    try await Self.prompt(Self.recordMarker, in: fixture.sessionId, on: fixture)
    let projects = fixture.harness.agent.home.projectsDirectory
    for file in try FileManager.default.contentsOfDirectory(
      at: projects, includingPropertiesForKeys: nil)
    {
      try FileManager.default.removeItem(at: file)
    }
    try Self.aim(probe, at: fixture.sessionId)

    try await Self.prompt(Self.probeMarker, in: fixture.sessionId, on: fixture)

    #expect(probe.outcome.value?.kinds?.contains("prompt") == true)
    await fixture.close()
  }

  // MARK: - session/resume

  @Test("a tool in a session after a cold resume reads another session")
  func coldResumeGivesTheReader() async throws {
    let probe = TranscriptProbe()
    let first = try await Self.makeFixture(probe: probe)
    let other = try await Self.recordSecondSession(on: first)
    let resumedId = first.sessionId
    try Self.aim(probe, at: other)

    try await first.closeAndResume(
      makeSecond: { cwd in try await Self.makeFixture(probe: probe, workingDirectory: cwd) },
      read: { second, _ in
        try await Self.prompt(Self.probeMarker, in: resumedId, on: second)
      })

    #expect(probe.outcome.value?.kinds?.contains("prompt") == true)
  }

  // MARK: - The model-slot switch

  @Test("a tool in a session after a model-slot switch reads another session")
  func modelSlotSwitchGivesTheReader() async throws {
    let probe = TranscriptProbe()
    let fixture = try await Self.makeFixture(probe: probe)
    let other = try await Self.recordSecondSession(on: fixture)
    try Self.aim(probe, at: other)
    _ = try await fixture.harness.connection.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.modelOptionId, sessionId: fixture.sessionId,
        value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))

    try await Self.prompt(Self.probeMarker, in: fixture.sessionId, on: fixture)

    #expect(probe.outcome.value?.kinds?.contains("prompt") == true)
    await fixture.close()
  }
}

/// What the probe tool reads, and what it saw.
final class TranscriptProbe: Sendable {
  /// The session to read.
  private let aim = Mutex<ULID?>(nil)

  /// The outcome of the last call of the tool.
  let outcome = SessionTranscriptToolTests.OutcomeBox()

  /// The session that the tool reads next.
  var target: ULID? {
    get { aim.withLock { $0 } }
    set { aim.withLock { $0 = newValue } }
  }
}

/// A host tool that reads the transcript of the session of a probe through the tool context of
/// its call.
struct AgentTranscriptProbeTool: FoundationModels.Tool {
  /// The wire arguments; the tool reads nothing from them.
  @Generable
  struct Arguments {}

  /// The name of the tool.
  static let toolName = "probe_transcript"

  let name = Self.toolName

  let description = "reads the transcript of another session"

  /// What to read, and where to keep the outcome.
  let probe: TranscriptProbe

  /// Why the tool cannot read.
  enum ProbeError: Error {
    /// The test gave the probe no session to read.
    case noTarget
  }

  func call(arguments: Arguments) async throws -> String {
    do {
      guard let target = probe.target else { throw ProbeError.noTarget }
      let transcript = try await ToolContext.current?.transcript(of: target)
      probe.outcome.set(.kinds(transcript?.entries.map(\.kind) ?? []))
    } catch let error as SessionTranscriptError {
      probe.outcome.set(.failed(error))
    }
    return Self.toolName
  }
}
