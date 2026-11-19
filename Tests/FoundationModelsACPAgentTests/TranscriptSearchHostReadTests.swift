import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

/// A host reads the changes of the transcript search index of the server (D207, ^twh8ceh): the
/// change stream, the turns of one session and all turns, through `TranscriptSearchChanges` of
/// `RoutedACPAgent` and of `ComposedAgent`.
///
/// The suite uses the public surface only. It does not use `@testable`, so a pass shows that a
/// package which links the library (the Mac app) can do the same.
@Suite struct TranscriptSearchHostReadTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchHostReadTests"

  /// The dotfolder name of the host in this suite.
  private static let dotfolderName = "transcript-search-host"

  /// A word that only the prompt holds. The stub model echoes the prompt, so the answer holds
  /// it too.
  private static let promptWord = "wombat"

  /// The text of the prompt of each test.
  private static let promptText = "Where does the \(promptWord) live?"

  /// The most polls of a wait for the index. The updates run with a low priority, so a full
  /// parallel test run can keep them back for many seconds.
  private static let pollLimit = 3600

  /// The time between two polls of a wait for the index.
  private static let pollInterval = Duration.milliseconds(25)

  // MARK: - Fixtures

  /// Composes a stub agent in a new workspace, runs one prompt in a new session, and gives
  /// the session to `read` while the wire is open.
  ///
  /// - Parameters:
  ///   - label: The label of the folders of the test.
  ///   - read: The read of the host after the prompt. It gets the composition and the session.
  /// - Returns: The value that `read` gives.
  /// - Throws: Whatever the composition, the handshake, the prompt or `read` throws.
  private static func afterOnePrompt<Value: Sendable>(
    label: String, _ read: (ComposedAgent, SessionId) async throws -> Value
  ) async throws -> Value {
    let workspace = makeResolvedDirectory(label: "\(Self.label)-\(label)-repo")
    let composed = try await composeStubAgent(
      name: dotfolderName, label: "\(Self.label)-\(label)", workspace: workspace)
    return try await ComposedClientWire.withSession(of: composed, in: workspace) {
      connection, sessionId in
      _ = try await PromptUpdateRead.onePrompt(over: connection, in: sessionId, text: promptText)
      return try await read(composed, sessionId)
    }
  }

  /// Whether a turn of a session holds ``promptWord``.
  ///
  /// - Parameters:
  ///   - turns: The turns.
  ///   - session: The session.
  /// - Returns: `true` when a chunk of a turn of the session holds the word.
  private static func holdThePrompt(_ turns: [TranscriptSearchTurn], of session: SessionId)
    -> Bool
  {
    turns.contains { turn in
      turn.sessionId == session && turn.chunks.contains { $0.text.contains(promptWord) }
    }
  }

  /// The turns of the first change of a stream that indexed a session with ``promptWord``.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - stream: The change stream.
  /// - Returns: The turns of the change, or none when the stream ended first.
  private static func indexedTurns(
    of session: SessionId, in stream: AsyncStream<TranscriptSearchChange>
  ) async -> [TranscriptSearchTurn] {
    for await change in stream {
      if case .indexed(let indexed, let turns) = change, indexed == session,
        holdThePrompt(turns, of: session)
      {
        return turns
      }
    }
    return []
  }

  /// Polls a read of the host until it gives a turn of a session with ``promptWord``.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - read: The read of the turns.
  /// - Returns: The last turns that `read` gave.
  /// - Throws: The cancel of the wait.
  private static func polledTurns(
    of session: SessionId, _ read: () async -> [TranscriptSearchTurn]
  ) async throws -> [TranscriptSearchTurn] {
    try await pollUntil(limit: pollLimit, interval: pollInterval) {
      holdThePrompt(await read(), of: session)
    }
    return await read()
  }

  // MARK: - The change stream

  /// The change stream of the server index of `RoutedACPAgent` gives the turns of a session
  /// after a prompt.
  @Test(.timeLimit(.minutes(3))) func theAgentGivesTheTurnsOfAPromptInTheChangeStream()
    async throws
  {
    let (session, turns) = try await Self.afterOnePrompt(label: "agent-stream") {
      composed, sessionId in
      let stream = composed.agent.transcriptSearchChanges.changes()
      return (sessionId, await Self.indexedTurns(of: sessionId, in: stream))
    }

    #expect(Self.holdThePrompt(turns, of: session))
  }

  /// The change stream of the server index of `ComposedAgent` gives the turns of a session
  /// after a prompt.
  @Test(.timeLimit(.minutes(3))) func theComposedAgentGivesTheTurnsOfAPromptInTheChangeStream()
    async throws
  {
    let (session, turns) = try await Self.afterOnePrompt(label: "composed-stream") {
      composed, sessionId in
      let stream = composed.transcriptSearchChanges.changes()
      return (sessionId, await Self.indexedTurns(of: sessionId, in: stream))
    }

    #expect(Self.holdThePrompt(turns, of: session))
  }

  // MARK: - The reads of the state

  /// `turns(of:)` gives the turns of a server session after a prompt.
  @Test(.timeLimit(.minutes(3))) func theTurnsOfAServerSessionHoldThePrompt() async throws {
    let (session, turns) = try await Self.afterOnePrompt(label: "turns") { composed, sessionId in
      let changes = composed.transcriptSearchChanges
      return (sessionId, try await Self.polledTurns(of: sessionId) {
        await changes.turns(of: sessionId)
      })
    }

    #expect(Self.holdThePrompt(turns, of: session))
  }

  /// `allTurns()` gives the turns of the server sessions after a prompt.
  @Test(.timeLimit(.minutes(3))) func allTurnsHoldTheServerSession() async throws {
    let (session, turns) = try await Self.afterOnePrompt(label: "all-turns") {
      composed, sessionId in
      let changes = composed.transcriptSearchChanges
      return (sessionId, try await Self.polledTurns(of: sessionId) { await changes.allTurns() })
    }

    #expect(Self.holdThePrompt(turns, of: session))
  }
}
