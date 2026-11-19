import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// A resident echo model that keeps each backend that a restore makes.
///
/// Each factory forwards to ``EchoLLMContainer``, so the test reads the
/// real restore of the echo model. The container only keeps the backends
/// of `makeSession(transcript:)` and `makeSession(transcript:tools:)`, so a
/// test reads the transcript that a restored session holds.
final class RestoreKeepingEchoContainer: LoadedLLMContainer {
  /// The echo model that makes each backend.
  private let echo = EchoLLMContainer()

  /// Each backend that a restore made, in order.
  private let restored = Mutex<[any LanguageModelSessionBackend]>([])

  /// The counter of the echo model.
  var tokenCounter: any TokenCounter { echo.tokenCounter }

  /// Each backend that a restore made, in order.
  var restoredBackends: [any LanguageModelSessionBackend] {
    restored.withLock { $0 }
  }

  func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
    echo.makeSession(instructions: instructions)
  }

  func makeSession(
    instructions: String?, tools: [any Tool]
  ) -> any LanguageModelSessionBackend {
    echo.makeSession(instructions: instructions, tools: tools)
  }

  func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
    keep(echo.makeSession(transcript: transcript))
  }

  func makeSession(
    transcript: Transcript, tools: [any Tool]
  ) -> any LanguageModelSessionBackend {
    keep(echo.makeSession(transcript: transcript, tools: tools))
  }

  /// Keeps a restored backend, and gives it back.
  ///
  /// - Parameter backend: The backend that a restore made.
  /// - Returns: `backend`.
  private func keep(_ backend: any LanguageModelSessionBackend)
    -> any LanguageModelSessionBackend
  {
    restored.withLock { $0.append(backend) }
    return backend
  }
}

/// The transcript of the echo model (bug ^campexj): each write path of the
/// echo transcript has a read-back. An answer writes a prompt entry and a
/// response entry, a fork copies the entries, a restore gives them back,
/// and a session that the agent resumes holds the turns that it ran.
@Suite(.closesHarnesses) struct EchoTranscriptTests {
  /// The prompt of turn 1.
  private static let firstPrompt = "Plan step one"

  /// The prompt of turn 2.
  private static let secondPrompt = "Plan step two"

  /// The number of idle updates after two completed turns.
  private static let twoTurns = 2

  /// The transcript of two echo turns: for each prompt, a prompt entry
  /// and a response entry with the same text.
  private static let twoTurnEntries = EchoTurns(
    prompts: [firstPrompt, secondPrompt], responses: [firstPrompt, secondPrompt])

  /// The texts of the prompt entries and of the response entries of a
  /// transcript.
  struct EchoTurns: Equatable {
    /// The text of each prompt entry, in order.
    let prompts: [String]

    /// The text of each response entry, in order.
    let responses: [String]

    /// Reads the turns of `entries`.
    ///
    /// - Parameter entries: The transcript entries.
    init(of entries: [Transcript.Entry]) {
      prompts = entries.compactMap { entry in
        guard case .prompt = entry else { return nil }
        return CharacterCountTokenCounter.content(of: entry)
      }
      responses = entries.compactMap { entry in
        guard case .response = entry else { return nil }
        return CharacterCountTokenCounter.content(of: entry)
      }
    }

    /// Makes the turns from their texts.
    ///
    /// - Parameters:
    ///   - prompts: The text of each prompt entry.
    ///   - responses: The text of each response entry.
    init(prompts: [String], responses: [String]) {
      self.prompts = prompts
      self.responses = responses
    }
  }

  /// The factory of a restore of the echo model.
  enum Restore: CaseIterable, Sendable {
    /// `makeSession(transcript:)`.
    case transcript

    /// `makeSession(transcript:tools:)`.
    case transcriptAndTools

    /// Restores `entries` through the factory of the case.
    ///
    /// - Parameter entries: The transcript to restore.
    /// - Returns: The restored backend.
    func restore(_ entries: [Transcript.Entry]) -> any LanguageModelSessionBackend {
      let transcript = Transcript(entries: entries)
      switch self {
      case .transcript:
        return EchoLLMContainer().makeSession(transcript: transcript)
      case .transcriptAndTools:
        return EchoLLMContainer().makeSession(transcript: transcript, tools: [])
      }
    }
  }

  /// A backend after two turns of `respond(to:maxTokens:)`.
  ///
  /// - Returns: The backend.
  /// - Throws: Whatever an answer throws.
  private static func respondedTwice() async throws -> EchoSessionBackend {
    let backend = EchoSessionBackend()
    _ = try await backend.respond(to: firstPrompt, maxTokens: nil)
    _ = try await backend.respond(to: secondPrompt, maxTokens: nil)
    return backend
  }

  /// Two answers of `respond(to:maxTokens:)` write two echo turns.
  @Test func twoAnswersWriteTwoTurns() async throws {
    let backend = try await Self.respondedTwice()

    #expect(EchoTurns(of: backend.transcriptEntries()) == Self.twoTurnEntries)
  }

  /// Two streamed answers write two echo turns.
  @Test func twoStreamedAnswersWriteTwoTurns() async throws {
    let backend = EchoSessionBackend()
    for prompt in [Self.firstPrompt, Self.secondPrompt] {
      for try await _ in backend.streamResponse(to: prompt, maxTokens: nil) {}
    }

    #expect(EchoTurns(of: backend.transcriptEntries()) == Self.twoTurnEntries)
  }

  /// A fork holds the turns of its source.
  @Test func aForkHoldsTheTurnsOfItsSource() async throws {
    let source = try await Self.respondedTwice()

    let fork = source.makeFork()

    #expect(EchoTurns(of: fork.transcriptEntries()) == Self.twoTurnEntries)
  }

  /// A restore of the transcript of two turns holds the two turns.
  @Test(arguments: Restore.allCases)
  func aRestoreHoldsTheTurnsOfTheTranscript(through restore: Restore) async throws {
    let source = try await Self.respondedTwice()

    let restored = restore.restore(source.transcriptEntries())

    #expect(EchoTurns(of: restored.transcriptEntries()) == Self.twoTurnEntries)
  }

  /// A session of two echo turns that the agent resumes holds the two
  /// turns: the Router journal gives the transcript to the restore of the
  /// echo model, and the restored backend keeps it.
  @Test(.timeLimit(.minutes(1)))
  func aResumedSessionHoldsItsTwoTurns() async throws {
    let container = RestoreKeepingEchoContainer()
    let fixture = try await ScriptedPromptFixture.make(
      loader: StubModelLoader(makeLLMContainer: { _ in container }),
      label: "EchoTranscriptTests-resume")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstPrompt)
    try await ScriptedPromptFixture.runPrompt(
      on: fixture, text: Self.secondPrompt, count: Self.twoTurns)
    try await ResumeSessionFixture.waitForJournal(
      of: fixture.sessionId, in: fixture.harness.agent)
    await fixture.harness.agent.markSessionClosed(fixture.sessionId)

    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId))

    let restored = try #require(container.restoredBackends.last)
    #expect(EchoTurns(of: restored.transcriptEntries()) == Self.twoTurnEntries)
  }
}
