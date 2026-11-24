import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The changes of the transcript search index for Spotlight (D207 (i), ^5qbe4fb): the stream of
/// the turns that the index indexed and of the sessions that it removed, `turns(of:)` and
/// `allTurns()`.
@Suite struct TranscriptSearchChangesTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchChangesTests"

  /// The session that the tests index.
  private static let sessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// A second session.
  private static let otherSessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// The working folder of the sessions.
  private static let folder = URL(fileURLWithPath: "/projects/zoo", isDirectory: true)

  /// The date of the first turn.
  private static let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// The date of the second turn.
  private static let secondDate = Date(timeIntervalSince1970: 1_800_000_600)

  /// The longest time that a test waits for the changes of a stream. The update queue runs with
  /// a low priority, so a full parallel test run can keep it back for many seconds.
  private static let readTimeout = Duration.seconds(90)

  /// The facts of each session before a change.
  private static let metadata = TranscriptSessionMetadata(
    name: "Zebra research", slug: "zebra-research", tags: [], folder: folder, agentName: nil,
    recap: nil, lastSummary: nil)

  /// The facts of a session after a rename.
  private static let renamedMetadata = TranscriptSessionMetadata(
    name: "Quokka research", slug: "quokka-research", tags: [], folder: folder, agentName: nil,
    recap: nil, lastSummary: nil)

  /// The chunks of two turns: a prompt, a thought and an agent message in turn 1, a prompt and
  /// a tool call in turn 2. Each chunk of turn 1 after the first has no date.
  private static let chunks = [
    chunk(turn: 1, ordinal: 0, kind: .user, date: firstDate, text: "Where do they live?"),
    chunk(turn: 1, ordinal: 1, kind: .thought, date: nil, text: "Think about islands."),
    chunk(turn: 1, ordinal: 2, kind: .agent, date: nil, text: "On an island."),
    chunk(turn: 2, ordinal: 3, kind: .user, date: secondDate, text: "Show the map."),
    chunk(turn: 2, ordinal: 4, kind: .tool, date: secondDate, text: "Read map\nThe map."),
  ]

  /// The turns of ``chunks`` for ``sessionId``.
  private static let turns = [
    TranscriptSearchTurn(
      sessionId: sessionId, turn: 1, date: firstDate,
      chunks: [
        .init(kind: .user, text: "Where do they live?"),
        .init(kind: .thought, text: "Think about islands."),
        .init(kind: .agent, text: "On an island."),
      ]),
    TranscriptSearchTurn(
      sessionId: sessionId, turn: 2, date: secondDate,
      chunks: [
        .init(kind: .user, text: "Show the map."), .init(kind: .tool, text: "Read map\nThe map."),
      ]),
  ]

  // MARK: - Fixtures

  /// One chunk with no entry.
  ///
  /// - Parameters:
  ///   - turn: The turn of the chunk.
  ///   - ordinal: The place of the chunk in the session.
  ///   - kind: The kind of the chunk.
  ///   - date: The date of the chunk, or `nil`.
  ///   - text: The text of the chunk.
  /// - Returns: The chunk.
  private static func chunk(
    turn: Int, ordinal: Int, kind: SessionSearchChunk.Kind, date: Date?, text: String
  ) -> SessionSearchChunk {
    SessionSearchChunk(
      turn: turn, ordinal: ordinal, kind: kind, author: nil, date: date, title: "", text: text,
      entries: [])
  }

  /// The chunks of one prompt with its text.
  ///
  /// - Parameter text: The text of the prompt.
  /// - Returns: The chunks.
  private static func promptChunks(_ text: String) -> [SessionSearchChunk] {
    [chunk(turn: 1, ordinal: 0, kind: .user, date: firstDate, text: text)]
  }

  /// An empty index in a new folder.
  ///
  /// - Parameter label: The label of the folder.
  /// - Returns: The index.
  private static func makeIndex(label: String) async -> TranscriptSearchIndex {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "\(Self.label)-\(label)"), embedder: nil,
      modelID: nil, readableFolder: { _ in true })
    await index.load()
    return index
  }

  /// Reads the first changes of a new stream of an index while `request` runs.
  ///
  /// - Parameters:
  ///   - count: The number of changes to read.
  ///   - index: The index.
  ///   - request: The steps that change the index.
  /// - Returns: The changes that came before ``readTimeout``, at most `count`.
  /// - Throws: The error of `request`.
  private static func firstChanges(
    _ count: Int, of index: TranscriptSearchIndex, whileRunning request: () async throws -> Void
  ) async throws -> [TranscriptSearchChange] {
    try await firstChanges(count, of: index.changes(), whileRunning: request)
  }

  /// Reads the first changes of a stream while `request` runs.
  ///
  /// - Parameters:
  ///   - count: The number of changes to read.
  ///   - stream: The stream.
  ///   - request: The steps that change the index of the stream.
  /// - Returns: The changes that came before ``readTimeout``, at most `count`.
  /// - Throws: The error of `request`.
  private static func firstChanges(
    _ count: Int, of stream: AsyncStream<TranscriptSearchChange>,
    whileRunning request: () async throws -> Void = {}
  ) async throws -> [TranscriptSearchChange] {
    try await TimedRead.value(
      of: { await stream.prefix(count).reduce(into: []) { $0.append($1) } },
      timeout: readTimeout, whileRunning: request)
  }

  // MARK: - The stream

  /// A turn of a session gives one change with the turns of the session.
  @Test func anIndexedSessionGivesOneChangeWithItsTurns() async throws {
    let index = await Self.makeIndex(label: "indexed")

    let changes = try await Self.firstChanges(1, of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    }

    #expect(changes == [.indexed(session: Self.sessionId, turns: Self.turns)])
  }

  /// A delete gives one removal after the change of the index of the session.
  @Test func aDeleteGivesOneRemoval() async throws {
    let index = await Self.makeIndex(label: "removed")

    let changes = try await Self.firstChanges(2, of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
      await index.remove(session: Self.sessionId)
    }

    #expect(
      changes == [
        .indexed(session: Self.sessionId, turns: Self.turns), .removed(session: Self.sessionId),
      ])
  }

  /// A rename changes the session item only, so it gives no change: the next change of the
  /// stream after the index is the removal.
  @Test func aRenameGivesNoChange() async throws {
    let index = await Self.makeIndex(label: "rename")

    let changes = try await Self.firstChanges(2, of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
      await index.update(session: Self.sessionId, metadata: Self.renamedMetadata)
      await index.remove(session: Self.sessionId)
    }

    #expect(changes.last == .removed(session: Self.sessionId))
  }

  /// A second index of the same chunks gives no change: the reconcile at launch gives the same
  /// chunks of each session again.
  @Test func theSameChunksGiveNoChange() async throws {
    let index = await Self.makeIndex(label: "same-chunks")

    let changes = try await Self.firstChanges(2, of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
      await index.index(
        session: Self.sessionId, chunks: Self.chunks, metadata: Self.renamedMetadata)
      await index.remove(session: Self.sessionId)
    }

    #expect(changes.last == .removed(session: Self.sessionId))
  }

  /// A second index instance (the client folder of the app) has its own stream: the stream of
  /// the server index does not get the change of the client index.
  @Test func aSecondIndexHasItsOwnStream() async throws {
    let server = await Self.makeIndex(label: "server")
    let client = await Self.makeIndex(label: "client")

    let changes = try await Self.firstChanges(1, of: server) {
      await client.index(
        session: Self.otherSessionId, chunks: Self.promptChunks("Client prompt."),
        metadata: Self.metadata)
      await server.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    }

    #expect(changes == [.indexed(session: Self.sessionId, turns: Self.turns)])
  }

  /// Two subscribers of one index each get the change.
  @Test func eachSubscriberGetsTheChange() async throws {
    let index = await Self.makeIndex(label: "two-subscribers")
    let first = index.changes()

    let second = try await Self.firstChanges(1, of: index) {
      await index.remove(session: Self.sessionId)
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    }
    let firstRead = try await Self.firstChanges(1, of: first)

    let expected: [TranscriptSearchChange] = [.indexed(session: Self.sessionId, turns: Self.turns)]
    #expect([firstRead, second] == [expected, expected])
  }

  /// The stream ends when its index goes away.
  @Test func theStreamEndsWithItsIndex() async throws {
    let stream = await Self.makeIndex(label: "ends").changes()

    let ended = try await TimedRead.value(
      of: {
        for await _ in stream {}
        return !Task.isCancelled
      }, timeout: Self.readTimeout, whileRunning: {})

    #expect(ended)
  }

  /// A subscriber that does not read keeps the newest changes: the oldest change drops.
  @Test func aSlowSubscriberKeepsTheNewestChanges() async throws {
    let feed = TranscriptSearchChangeFeed(bufferLimit: 1)
    let stream = feed.subscribe()

    feed.publish([.removed(session: Self.sessionId), .removed(session: Self.otherSessionId)])
    let changes = try await Self.firstChanges(1, of: stream)

    #expect(changes == [.removed(session: Self.otherSessionId)])
  }

  // MARK: - The turns

  /// `turns(of:)` gives the same turns as the change of the session.
  @Test func theTurnsOfASessionAreTheTurnsOfItsChange() async throws {
    let index = await Self.makeIndex(label: "turns-of")

    let changes = try await Self.firstChanges(1, of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    }

    #expect(
      changes == [.indexed(session: Self.sessionId, turns: await index.turns(of: Self.sessionId))])
  }

  /// `allTurns()` gives the turns of each change, in the order of the session ids.
  @Test func allTurnsAreTheTurnsOfTheChanges() async throws {
    let index = await Self.makeIndex(label: "all-turns")

    let changes = try await Self.firstChanges(2, of: index) {
      await index.index(
        session: Self.otherSessionId, chunks: Self.promptChunks("Other prompt."),
        metadata: Self.metadata)
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    }

    let streamed = changes.reversed().flatMap { change -> [TranscriptSearchTurn] in
      guard case .indexed(_, let turns) = change else {
        return []
      }
      return turns
    }
    let expected =
      Self.turns + [
        TranscriptSearchTurn(
          sessionId: Self.otherSessionId, turn: 1, date: Self.firstDate,
          chunks: [.init(kind: .user, text: "Other prompt.")])
      ]
    #expect([await index.allTurns(), streamed] == [expected, expected])
  }

  // MARK: - The update queue

  /// A history from the update queue gives the change of its session.
  @Test func aQueuedHistoryGivesItsChange() async throws {
    let index = await Self.makeIndex(label: "queue")
    let summary = SessionSummary(
      id: try Self.sessionId.ulid(), agentID: "default", workingDirectory: Self.folder,
      title: "Zebra research", tags: [], kind: .root, state: .idle, origin: .client,
      createdAt: Self.firstDate, updatedAt: Self.firstDate, isLive: true)
    let updates = TranscriptSearchUpdates(index: index) { _ in summary }
    let history = SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "user-1"),
          content: .value([.text(TextContent(text: "Where do they live?"))])))
    ])

    let changes = try await Self.firstChanges(1, of: index) {
      updates.indexHistory(history, of: Self.sessionId)
    }

    #expect(
      changes == [
        .indexed(
          session: Self.sessionId,
          turns: [
            TranscriptSearchTurn(
              sessionId: Self.sessionId, turn: 1, date: nil,
              chunks: [.init(kind: .user, text: "Where do they live?")])
          ])
      ])
  }

  /// The reconcile at launch gives the removal of a session of a read folder that has no
  /// history file.
  @Test func theReconcileGivesItsRemoval() async throws {
    let index = await Self.makeIndex(label: "reconcile")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    let emptyRoot = makeResolvedDirectory(label: "\(Self.label)-reconcile-root")
    await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)

    let changes = try await Self.firstChanges(1, of: index) {
      await updates.reconcile(folders: [Self.folder], recordingRoot: { _ in emptyRoot })
    }

    #expect(changes == [.removed(session: Self.sessionId)])
  }
}
