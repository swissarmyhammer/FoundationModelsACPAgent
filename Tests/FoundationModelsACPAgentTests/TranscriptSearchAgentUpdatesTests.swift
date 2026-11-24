import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The agent keeps its transcript search index current (D207, ^en1kt61): each turn, each fork
/// and each delete changes the items of its session, off the turn, and the reconcile reads the
/// history files of a folder.
@Suite(.closesHarnesses) struct TranscriptSearchAgentUpdatesTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchAgentUpdatesTests"

  /// A word that only the answer of the scripted model holds.
  private static let answerWord = "quokka"

  /// The script of each prompt: one answer with ``answerWord``.
  private static let script: [ScriptedPassStep] = [
    .textDelta("The \(answerWord) lives on an island."), .endPass,
  ]

  /// The most polls of a wait for the index. The updates run with a low priority, so a full
  /// parallel test run can keep them back for many seconds.
  private static let pollLimit = 3600

  /// The time between two polls of a wait for the index.
  private static let pollInterval = Duration.milliseconds(25)

  // MARK: - Fixtures

  /// A fixture that ran one prompt with the answer of ``script``.
  ///
  /// - Parameter label: The label of the folders of the test.
  /// - Returns: The fixture.
  /// - Throws: Whatever the fixture or the prompt throws.
  private static func fixtureAfterOnePrompt(label: String) async throws -> ScriptedPromptFixture {
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: "\(Self.label)-\(label)")
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: "Where does it live?")
    return fixture
  }

  /// Whether the items of a session hold a chunk with ``answerWord``.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - index: The index.
  /// - Returns: `true` when a chunk item of the session holds the word.
  private static func holdsTheAnswer(_ session: SessionId, in index: TranscriptSearchIndex) async
    -> Bool
  {
    await index.items(of: session).contains { item in
      guard case .chunk(let chunk) = item.content else {
        return false
      }
      return chunk.text.contains(answerWord)
    }
  }

  /// Waits until a condition over the index holds, or until the poll limit.
  ///
  /// - Parameter condition: Tells whether the wait is over.
  /// - Throws: The cancel of the wait.
  private static func waitUntil(_ condition: () async -> Bool) async throws {
    try await pollUntil(limit: pollLimit, interval: pollInterval) { await condition() }
  }

  // MARK: - The turn

  /// The end of a prompt gives the chunk items of its session to the index.
  @Test func aTurnGivesTheItemsOfItsSession() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "turn")
    let index = fixture.harness.agent.transcriptSearchIndex

    try await Self.waitUntil { await Self.holdsTheAnswer(fixture.sessionId, in: index) }
    await fixture.close()

    #expect(await Self.holdsTheAnswer(fixture.sessionId, in: index))
  }

  /// A summary of the directory that does not read does not stop the turn: the turn ends, and
  /// the end of the prompt writes its history with the user message of the response.
  @Test func aFailedIndexUpdateDoesNotStopTheTurn() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: Self.script, label: "\(Self.label)-failure")
    await fixture.harness.agent.transcriptSearchUpdates.useSummaryReader { id in
      throw SessionDirectoryError.unknownSession(id)
    }

    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: "Where does it live?")
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    await fixture.close()

    let written = try #require(try SessionHistoryFile.read(from: entry.transcriptDirectory))
    #expect(written.entry(withID: .userMessage(run.response.messageId)) != nil)
  }

  // MARK: - The shutdown

  /// The shutdown of the agent waits until the index applied and saved the last turn: a new
  /// index over the folder of the agent holds the turn (D207, ^y7nx1g3).
  @Test func theShutdownKeepsTheLastTurn() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "shutdown")
    let agentIndex = fixture.harness.agent.transcriptSearchIndex

    await fixture.harness.agent.shutdown()
    let restored = TranscriptSearchIndex(
      folder: agentIndex.folder, embedder: nil, modelID: agentIndex.modelID,
      readableFolder: { _ in true })
    await restored.load()
    await fixture.close()

    #expect(await Self.holdsTheAnswer(fixture.sessionId, in: restored))
  }

  // MARK: - The fork

  /// A fork is indexed as its own session, with the copy of the history of its source.
  @Test func aForkIsIndexedAsItsOwnSession() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "fork")
    let index = fixture.harness.agent.transcriptSearchIndex

    let fork = try await fixture.harness.connection.forkSession(
      ForkSessionRequest(
        cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId)
    ).sessionId
    try await Self.waitUntil { await Self.holdsTheAnswer(fork, in: index) }
    await fixture.close()

    #expect(await Self.holdsTheAnswer(fork, in: index))
  }

  // MARK: - The delete

  /// `session/delete` removes each item of the session.
  @Test func aDeleteRemovesTheItemsOfTheSession() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "delete")
    let index = fixture.harness.agent.transcriptSearchIndex
    try await Self.waitUntil { await Self.holdsTheAnswer(fixture.sessionId, in: index) }
    try #require(await Self.holdsTheAnswer(fixture.sessionId, in: index))

    _ = try await fixture.harness.connection.deleteSession(
      DeleteSessionRequest(sessionId: fixture.sessionId))
    try await Self.waitUntil { await index.items(of: fixture.sessionId).isEmpty }
    await fixture.close()

    #expect(await index.items(of: fixture.sessionId).isEmpty)
  }

  // MARK: - The reconcile

  /// The reconcile gives the chunks of the history file of a session that changed since the
  /// index read it.
  @Test func theReconcileGivesTheChunksOfAChangedFile() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "reconcile")
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    await fixture.close()
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "\(Self.label)-reconcile-index"), embedder: nil,
      modelID: nil, readableFolder: { _ in true })
    await index.load()
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    await index.index(
      session: fixture.sessionId, chunks: [],
      metadata: TranscriptSessionMetadata(
        name: "", slug: "", tags: [], folder: fixture.cwd, agentName: nil, recap: nil,
        lastSummary: nil))

    await updates.reconcile(folders: [fixture.cwd], recordingRoot: { _ in entry.transcriptRoot })
    try await Self.waitUntil { await Self.holdsTheAnswer(fixture.sessionId, in: index) }

    let written = try #require(try SessionHistoryFile.read(from: entry.transcriptDirectory))
    #expect(
      await index.items(of: fixture.sessionId).dropFirst().elementsEqual(
        written.searchChunks.map { TranscriptSearchItem(chunk: $0, session: fixture.sessionId) }))
  }

  /// The session item that the reconcile gives for a recorded session has the same facts as
  /// the summary of the session directory for the live session (D207, ^pqweam5).
  @Test func theReconcileGivesTheFactsOfTheLiveSummary() async throws {
    let fixture = try await Self.fixtureAfterOnePrompt(label: "reconcile-facts")
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    let live = try #require(
      try await fixture.harness.agent.sessionDirectory.summary(of: try fixture.sessionId.ulid()))
    await fixture.close()

    let item = try await Self.reconciledSessionItem(
      of: fixture, recordingRoot: entry.transcriptRoot, label: "reconcile-facts")

    #expect(
      item
        == TranscriptSearchItem(
          session: fixture.sessionId, metadata: TranscriptSessionMetadata(summary: live)))
  }

  /// A recorded session with no title gets the slug that the Router gives from its record: the
  /// short id (D207, ^pqweam5).
  ///
  /// The test removes the title from a copy of the session folder, in a recording root that no
  /// session directory reads. The session directory of the fixture gives a default name to a
  /// closed root session with no title when it reads its record, and writes that name to the
  /// record (D199). The index updates of the fixture read the summary of the closed session from
  /// that directory, and under load they can run after the close. Thus a title removed from the
  /// original record can come back before the reconcile reads it.
  @Test func aRecordWithNoTitleGetsTheSlugOfTheRouter() async throws {
    let label = "reconcile-no-title"
    let fixture = try await Self.fixtureAfterOnePrompt(label: label)
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    await fixture.close()
    let root = makeResolvedDirectory(label: "\(Self.label)-\(label)-root")
    let sessionFolder = try Self.copy(sessionFolder: entry.transcriptDirectory, into: root)
    try Self.removeTitle(fromRecordIn: sessionFolder)
    let recorded = try #require(
      try RouterSessionDirectory.recordedSummary(inSessionFolder: sessionFolder))
    try #require(recorded.title == nil)

    let item = try await Self.reconciledSessionItem(
      of: fixture, recordingRoot: root, label: label)

    #expect(item?.sessionMetadata?.slug == recorded.shortID)
  }

  /// Copies the folder of a closed session into a recording root, with the same folder name.
  ///
  /// - Parameters:
  ///   - sessionFolder: The folder of the session.
  ///   - root: The recording root that gets the copy.
  /// - Returns: The folder of the copy.
  /// - Throws: The error of the copy.
  private static func copy(sessionFolder: URL, into root: URL) throws -> URL {
    let copy = root.appendingPathComponent(sessionFolder.lastPathComponent, isDirectory: true)
    try FileManager.default.copyItem(at: sessionFolder, to: copy)
    return copy
  }

  /// Reconciles the folder of a closed fixture into a new empty index, and gives the session
  /// item of the session of the fixture.
  ///
  /// - Parameters:
  ///   - fixture: The closed fixture.
  ///   - recordingRoot: The recording root of the session of the fixture.
  ///   - label: The label of the folder of the index.
  /// - Returns: The session item, or `nil` when the index holds no item of the session.
  /// - Throws: The cancel of the wait.
  private static func reconciledSessionItem(
    of fixture: ScriptedPromptFixture, recordingRoot: URL, label: String
  ) async throws -> TranscriptSearchItem? {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "\(Self.label)-\(label)-index"), embedder: nil,
      modelID: nil, readableFolder: { _ in true })
    await index.load()
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }

    await updates.reconcile(folders: [fixture.cwd], recordingRoot: { _ in recordingRoot })
    try await waitUntil { await holdsTheAnswer(fixture.sessionId, in: index) }
    return await index.items(of: fixture.sessionId).first
  }

  /// Removes the title line from the record (`index.md`) of a closed session.
  ///
  /// - Parameter sessionFolder: The folder of the session.
  /// - Throws: The read or the write error, or a failed requirement when the record holds no
  ///   title line.
  private static func removeTitle(fromRecordIn sessionFolder: URL) throws {
    let file = sessionFolder.appendingPathComponent(
      RecordedSessionIndexFile.fileName, isDirectory: false)
    let lines = try String(contentsOf: file, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("title:") }
    try #require(kept.count < lines.count, "the index.md holds no title line")
    try kept.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
  }
}

extension TranscriptSearchItem {
  /// The facts of a session item, or `nil` for a chunk item.
  fileprivate var sessionMetadata: TranscriptSessionMetadata? {
    guard case .session(let metadata) = content else {
      return nil
    }
    return metadata
  }
}
