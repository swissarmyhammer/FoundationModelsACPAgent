import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// A tool in a session reads the transcript of a session through
/// `ToolContext.transcript(of:)` (task ^zgqxj7z): the sessions that the
/// agent vends and restores carry the reader of the agent.
@Suite struct SessionTranscriptToolTests {
  /// The prompt that records the session that the tool reads.
  private static let recordPrompt = "record this session"

  /// The prompt whose answer calls the probe tool.
  private static let probePrompt = "read the other session"

  /// The text that ends each scripted answer.
  private static let answerText = "done"

  /// The script of each session: the answer to ``probePrompt`` calls the
  /// probe tool; each other answer gives only ``answerText``.
  private static let script: [ScriptedPassStep] = [
    .onPrompt(
      containing: probePrompt,
      play: [.toolCall(name: TranscriptProbeTool.toolName, argumentsJSON: "{}")]),
    .textDelta(answerText),
    .endPass,
  ]

  /// What the probe tool saw: the transcript or the error of its read.
  enum Outcome {
    /// The entry kinds of the transcript that the tool read.
    case kinds([String])

    /// The error that the read threw.
    case failed(SessionTranscriptError)

    /// The entry kinds, or `nil` when the read failed.
    var kinds: [String]? {
      if case .kinds(let kinds) = self { return kinds }
      return nil
    }

    /// The error of the read, or `nil` when the read worked.
    var failure: SessionTranscriptError? {
      if case .failed(let error) = self { return error }
      return nil
    }
  }

  /// The outcome of the last call of the probe tool, shared by each copy
  /// of the tool.
  final class OutcomeBox: Sendable {
    /// The outcome, or `nil` before the first call.
    private let stored = Mutex<Outcome?>(nil)

    /// The outcome so far.
    var value: Outcome? { stored.withLock { $0 } }

    /// Keeps the outcome of a call.
    func set(_ outcome: Outcome) {
      stored.withLock { $0 = outcome }
    }
  }

  /// A tool that reads the transcript of a target session through the
  /// tool context of its call, and keeps the outcome.
  struct TranscriptProbeTool: FoundationModels.Tool {
    /// The wire arguments; the tool reads nothing from them.
    @Generable
    struct Arguments {}

    /// The name of the tool.
    static let toolName = "probe_transcript"

    let name = Self.toolName

    let description = "reads the transcript of another session"

    /// The session to read.
    let target: ULID

    /// The outcome of the last call.
    let outcome: OutcomeBox

    func call(arguments: Arguments) async throws -> String {
      do {
        let transcript = try await ToolContext.current?.transcript(of: target)
        outcome.set(.kinds(transcript?.entries.map(\.kind) ?? []))
      } catch let error as SessionTranscriptError {
        outcome.set(.failed(error))
      }
      return Self.toolName
    }
  }

  /// The recording root, the profile and the reader of one test.
  private struct Fixture {
    /// The temporary directory of the test.
    let directory: URL

    /// The profile whose model plays ``SessionTranscriptToolTests/script``.
    let profile: LanguageModelProfile

    /// The recording root of each session.
    var recordingRoot: URL { directory.appendingPathComponent("recordings", isDirectory: true) }

    /// The reader over the recording root.
    var reader: RecordedSessionTranscriptReader {
      let root = recordingRoot
      return RecordedSessionTranscriptReader { [root] }
    }

    /// Makes the fixture in a new temporary directory.
    static func make() async throws -> Fixture {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "SessionTranscriptToolTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let root = directory.appendingPathComponent("recordings", isDirectory: true)
      let profile = try await makeStubProfile(
        cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
        recordingsDirectory: root,
        loader: makeHookLayeredModelLoader(script: SessionTranscriptToolTests.script))
      return Fixture(directory: directory, profile: profile)
    }

    /// Vends a session through `makeBudgetedSession`.
    func makeSession(
      tools: [any FoundationModels.Tool], transcriptReader: (any SessionTranscriptReader)?
    ) -> any RoutedSession {
      profile.standard.makeBudgetedSession(
        instructions: "Do the task.",
        workingDirectory: directory,
        recordingRoot: recordingRoot,
        tools: tools,
        compaction: CompactionConfiguration(),
        repetition: RepetitionConfiguration(),
        inlineSettleGrace: CatalogContext.defaultInlineSettleGrace,
        transcriptReader: transcriptReader)
    }
  }

  /// Records one session, then runs the probe prompt in a second session
  /// that carries `reader`.
  ///
  /// - Parameters:
  ///   - target: Gives the id that the tool reads, from the id of the
  ///     recorded session.
  ///   - reader: Gives the reader of the second session from the fixture.
  /// - Returns: What the tool saw, and the id of the recorded session.
  private static func probe(
    target: (ULID) -> ULID = { $0 },
    reader: (Fixture) -> (any SessionTranscriptReader)? = { $0.reader }
  ) async throws -> (outcome: Outcome?, recorded: ULID) {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recorded = fixture.makeSession(tools: [], transcriptReader: fixture.reader)
    _ = try await recorded.respond(to: recordPrompt)
    await recorded.close()
    let outcome = OutcomeBox()
    let tool = TranscriptProbeTool(target: target(recorded.id), outcome: outcome)
    let reading = fixture.makeSession(tools: [tool], transcriptReader: reader(fixture))
    _ = try await reading.respond(to: probePrompt)
    await reading.close()
    return (outcome.value, recorded.id)
  }

  @Test("a tool in a new session reads the entries of another session")
  func toolReadsAnotherSession() async throws {
    let result = try await Self.probe()

    let kinds = try #require(result.outcome?.kinds)
    #expect(kinds.first == "session")
    #expect(kinds.contains("prompt"))
  }

  @Test("a tool that reads an unknown id gets notFound")
  func toolReadsUnknownID() async throws {
    let unknown = ULID()
    let result = try await Self.probe(target: { _ in unknown })

    let error = try #require(result.outcome?.failure)
    #expect(error == .notFound(unknown))
  }

  @Test("a session with no reader gives the tool noSource")
  func sessionWithNoReaderGivesNoSource() async throws {
    let result = try await Self.probe(reader: { _ in nil })

    let error = try #require(result.outcome?.failure)
    #expect(error == .noSource)
  }

  @Test("a restored session carries the reader that restore gives")
  func restoredSessionCarriesTheReader() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recorded = fixture.makeSession(tools: [], transcriptReader: fixture.reader)
    _ = try await recorded.respond(to: Self.recordPrompt)
    await recorded.close()
    let outcome = OutcomeBox()
    let tool = TranscriptProbeTool(target: recorded.id, outcome: outcome)

    let restored = try await fixture.profile.standard.restoreSessionWithHostChecks(
      id: recorded.id, recordingRoot: fixture.recordingRoot, instructions: "Do the task.",
      tools: [tool], userPresence: .interactive, transcriptReader: fixture.reader)
    _ = try await restored.session.respond(to: Self.probePrompt)
    await restored.session.close()

    let kinds = try #require(outcome.value?.kinds)
    #expect(kinds.contains("prompt"))
  }
}
