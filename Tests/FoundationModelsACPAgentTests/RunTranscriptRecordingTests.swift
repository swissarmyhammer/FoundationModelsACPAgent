import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `run` subcommand records what it did, in the project: the events of its prompt go to
/// `<cwd>/.acp-agent/transcripts/<sessionId>/transcript.jsonl`, and `--resume` continues the
/// recorded session in the same file. The agent runs in this process over the stub model, the
/// same composition that the test-only `acp-agent-stub` binary serves.
///
/// The tests read `transcript.jsonl` and never the `index.md` of the session folder. Router
/// writes that record on a path that never touches the recorder of the transcript, so it stays
/// correct while every event drops.
@Suite(.stubModel) struct RunTranscriptRecordingTests {
  // MARK: - Constants

  /// The text of the first prompt. The stub model answers with the prompt it received.
  private static let promptText = "record this prompt"

  /// The text of the resumed prompt. It differs from ``promptText`` so the recorded file says
  /// which prompt wrote which line.
  private static let resumedPromptText = "record the second prompt too"

  /// How many sessions one `run` opens.
  private static let sessionsPerRun = 1

  /// The prefix of the folders of each test.
  private static let label = "RunTranscriptRecordingTests"

  // MARK: - Fixtures

  /// Parses `acp-agent run --cwd <workspace> <prompt>`, the way the shell hands the arguments
  /// over.
  ///
  /// - Parameters:
  ///   - fixture: The tree the run reads.
  ///   - prompt: The text of the prompt.
  /// - Returns: The parsed `run` command.
  /// - Throws: The parse error, or when the parse selects another subcommand.
  private static func parseRun(in fixture: ConfigCommandFixture, prompt: String) throws
    -> AcpAgentCommand.Run
  {
    try #require(
      try AcpAgentCommand.parseAsRoot(["run", "--cwd", fixture.workspace.path, prompt])
        as? AcpAgentCommand.Run)
  }

  /// The recording root of the project of `fixture`.
  ///
  /// - Parameter fixture: The tree the run reads.
  /// - Returns: The recording root.
  /// - Throws: The dotfolder name error.
  private static func recordingRoot(of fixture: ConfigCommandFixture) throws -> URL {
    try projectRecordingRoot(
      of: fixture.workspace, dotfolderName: AgentComposition.dotfolderName)
  }

  // MARK: - The contract

  /// `run` writes the events of its prompt to one file under the project recording root, and the
  /// recorded events name the session of that file.
  @Test
  func theRunRecordsThePromptUnderTheProjectTranscriptsRoot() async throws {
    let fixture = ConfigCommandFixture(label: "\(Self.label)-record")
    let capture = try AnswerCapture(label: "\(Self.label)-record-answer")

    _ = try await Self.parseRun(in: fixture, prompt: Self.promptText)
      .perform(environment: fixture.makeStubEnvironment(), into: capture.writer)

    let files = try RecordedTranscriptFile.fileURLs(under: try Self.recordingRoot(of: fixture))
    #expect(files.count == Self.sessionsPerRun)
    let file = try #require(files.first)
    let recorded = try String(contentsOf: file, encoding: .utf8)
    #expect(recorded.contains(Self.promptText))
    #expect(recorded.contains(file.deletingLastPathComponent().lastPathComponent))
  }

  /// `--resume` in a new composition over the same folders continues the session that the first
  /// run recorded: the second prompt runs in the same session, no second session opens, and the
  /// recorded file grows.
  @Test
  func aResumedRunAddsToTheTranscriptOfTheSessionTheFirstRunRecorded() async throws {
    let fixture = ConfigCommandFixture(label: "\(Self.label)-resume")
    let environment = try fixture.makeStubEnvironment()
    let first = try AnswerCapture(label: "\(Self.label)-resume-first")
    _ = try await Self.parseRun(in: fixture, prompt: Self.promptText)
      .perform(environment: environment, into: first.writer)
    let root = try Self.recordingRoot(of: fixture)
    let file = try #require(try RecordedTranscriptFile.fileURLs(under: root).first)
    let afterFirstPrompt = try String(contentsOf: file, encoding: .utf8)
    let recorded = SessionId(rawValue: file.deletingLastPathComponent().lastPathComponent)
    let second = try AnswerCapture(label: "\(Self.label)-resume-second")
    let composed = try await Self.parseRun(in: fixture, prompt: Self.resumedPromptText)
      .compose(environment: environment)

    let result = try await RunPrompt.answer(
      of: composed, in: .resumed(recorded), prompt: Self.resumedPromptText, into: second.writer)

    #expect(result.stopReason == .endTurn)
    #expect(try RecordedTranscriptFile.fileURLs(under: root).count == Self.sessionsPerRun)
    let afterSecondPrompt = try String(contentsOf: file, encoding: .utf8)
    #expect(afterSecondPrompt.count > afterFirstPrompt.count)
    #expect(afterSecondPrompt.contains(Self.resumedPromptText))
  }
}
