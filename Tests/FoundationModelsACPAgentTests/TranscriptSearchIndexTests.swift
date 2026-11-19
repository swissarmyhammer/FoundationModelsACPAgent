import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The reusable index of the transcript search (D207 (b), Q66): one `MetadataSearcher` of the
/// registry in the `.retrieval` mode over the chunk items and the session items, with the
/// embedder of the profile or with none, one instance for each folder.
@Suite struct TranscriptSearchIndexTests {
  // MARK: - Constants

  /// The session that the tests index.
  private static let sessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// A second session, with no word of the queries.
  private static let otherSessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// A word that only the agent message of ``sessionId`` holds.
  private static let chunkWord = "quokka"

  /// A word that only the name of ``sessionId`` holds.
  private static let nameWord = "zebra"

  /// A word that only the agent message of ``otherSessionId`` holds.
  private static let otherWord = "tiles"

  /// The id of the session item of ``sessionId``.
  private static let sessionItemID = TranscriptSearchItem(
    session: sessionId, metadata: metadata
  ).id

  /// A session whose id is the start of the id of ``slashChildSessionId``.
  private static let slashParentSessionId = SessionId(rawValue: "a")

  /// A session whose id is the id of ``slashParentSessionId``, a "/" and the ordinal of a chunk
  /// of that session.
  private static let slashChildSessionId = SessionId(rawValue: "a/1")

  /// The metadata of ``sessionId``.
  private static let metadata = TranscriptSessionMetadata(
    name: "\(nameWord) research", slug: "\(nameWord)-research", tags: [],
    folder: URL(fileURLWithPath: "/projects/zoo", isDirectory: true), agentName: nil, recap: nil,
    lastSummary: nil)

  /// The metadata of ``otherSessionId``.
  private static let otherMetadata = TranscriptSessionMetadata(
    name: "Kitchen plans", slug: "kitchen-plans", tags: [],
    folder: URL(fileURLWithPath: "/projects/house", isDirectory: true), agentName: nil,
    recap: nil, lastSummary: nil)

  // MARK: - Fixtures

  /// The chunks of a transcript of one user message and one agent message.
  ///
  /// - Parameters:
  ///   - question: The text of the user message.
  ///   - answer: The text of the agent message.
  /// - Returns: The chunks.
  private static func chunks(question: String, answer: String) -> [SessionSearchChunk] {
    SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "user-1"),
          content: .value([.text(TextContent(text: question))]))),
      .agentMessageChunk(
        ContentChunk(
          content: .text(TextContent(text: answer)), messageId: MessageId(rawValue: "agent-1"))),
    ]).searchChunks
  }

  /// An index in a new folder, with the two sessions in it.
  ///
  /// - Parameters:
  ///   - label: The label of the folder.
  ///   - embedder: The embedder of the index, or `nil` for the keyword signals only.
  /// - Returns: The index.
  private static func makeFilledIndex(label: String, embedder: (any PooledEmbedding)?) async
    -> TranscriptSearchIndex
  {
    let index = await makeIndex(label: label, embedder: embedder)
    await index.index(
      session: sessionId,
      chunks: chunks(
        question: "Where do they live?", answer: "The \(chunkWord) lives on an island."),
      metadata: metadata)
    await index.index(
      session: otherSessionId,
      chunks: chunks(question: "Which colour?", answer: "The blue \(otherWord) fit the wall."),
      metadata: otherMetadata)
    return index
  }

  /// An empty index in a new folder.
  ///
  /// - Parameters:
  ///   - label: The label of the folder.
  ///   - embedder: The embedder of the index, or `nil` for the keyword signals only.
  /// - Returns: The index.
  private static func makeIndex(label: String, embedder: (any PooledEmbedding)?) async
    -> TranscriptSearchIndex
  {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "TranscriptSearchIndexTests-\(label)"),
      embedder: embedder, modelID: nil, readableFolder: { _ in true })
    await index.load()
    return index
  }

  /// The id of the first match of a query.
  ///
  /// - Parameters:
  ///   - query: The query.
  ///   - index: The index.
  /// - Returns: The id, or `nil` when nothing matches.
  private static func firstMatchID(of query: String, in index: TranscriptSearchIndex) async throws
    -> String?
  {
    try await index.matches(for: query).first?.id
  }

  // MARK: - The keyword signals

  /// With no embedder, a word of a chunk finds the chunk item of that chunk first.
  @Test func aKeywordSearchFindsAWordOfAChunk() async throws {
    let index = await Self.makeFilledIndex(label: "keyword-chunk", embedder: nil)

    #expect(
      try await Self.firstMatchID(of: Self.chunkWord, in: index) == "\(Self.sessionId.rawValue)/1")
  }

  /// With no embedder, a word of the name of a session finds the session item first.
  @Test func aKeywordSearchFindsAWordOfASessionName() async throws {
    let index = await Self.makeFilledIndex(label: "keyword-name", embedder: nil)

    #expect(try await Self.firstMatchID(of: Self.nameWord, in: index) == Self.sessionItemID)
  }

  // MARK: - The embedder

  /// With an embedder, a word of a chunk finds the chunk item of that chunk first.
  @Test func anEmbeddedSearchFindsAWordOfAChunk() async throws {
    let index = await Self.makeFilledIndex(label: "embedded-chunk", embedder: WordBucketEmbedding())

    #expect(
      try await Self.firstMatchID(of: Self.chunkWord, in: index) == "\(Self.sessionId.rawValue)/1")
  }

  /// With an embedder, a word of the name of a session finds the session item first.
  @Test func anEmbeddedSearchFindsAWordOfASessionName() async throws {
    let index = await Self.makeFilledIndex(label: "embedded-name", embedder: WordBucketEmbedding())

    #expect(try await Self.firstMatchID(of: Self.nameWord, in: index) == Self.sessionItemID)
  }

  // MARK: - The catalog

  /// A removed session leaves no item: a query with a word of each session finds only the other
  /// session.
  @Test func aRemovedSessionLeavesNoItem() async throws {
    let index = await Self.makeFilledIndex(label: "remove", embedder: nil)

    await index.remove(session: Self.sessionId)

    #expect(
      Set(
        try await index.matches(for: "\(Self.chunkWord) \(Self.nameWord) \(Self.otherWord)").map(
          \.item.sessionId))
        == [Self.otherSessionId])
  }

  /// A second index of the same session replaces the chunk items of the session.
  @Test func aSecondIndexOfASessionReplacesItsChunkItems() async throws {
    let index = await Self.makeFilledIndex(label: "replace", embedder: nil)

    await index.index(
      session: Self.sessionId, chunks: Self.chunks(question: "Hello there?", answer: "Hi there."),
      metadata: Self.metadata)

    let matches = try await index.matches(for: "\(Self.chunkWord) hello hi there")
    #expect(
      Set(
        matches.filter { $0.item.sessionId == Self.sessionId && $0.id != Self.sessionItemID }
          .map(\.block))
        == ["Hello there?", "Hi there."])
  }

  /// Two sessions `a` and `a/1`, each with chunks, keep each item: a search with a word of the
  /// chunk 1 of `a`, of the name of `a/1` and of a chunk of `a/1` finds the three items
  /// (^8qsp7hb).
  @Test func sessionIdsWithASlashKeepEachItem() async throws {
    let index = await Self.makeIndex(label: "slash-ids", embedder: nil)
    let parentChunks = Self.chunks(
      question: "Where do they live?", answer: "The \(Self.chunkWord) lives on an island.")
    let childChunks = Self.chunks(
      question: "Which colour?", answer: "The blue \(Self.otherWord) fit the wall.")
    await index.index(
      session: Self.slashParentSessionId, chunks: parentChunks, metadata: Self.otherMetadata)
    await index.index(
      session: Self.slashChildSessionId, chunks: childChunks, metadata: Self.metadata)

    let matches = try await index.matches(
      for: "\(Self.chunkWord) \(Self.nameWord) \(Self.otherWord)")

    #expect(
      Set(matches.map(\.item)).isSuperset(of: [
        TranscriptSearchItem(chunk: parentChunks[1], session: Self.slashParentSessionId),
        TranscriptSearchItem(session: Self.slashChildSessionId, metadata: Self.metadata),
        TranscriptSearchItem(chunk: childChunks[1], session: Self.slashChildSessionId),
      ]))
  }

  /// New facts of a session that the index does not hold add no item: a session gets its items
  /// from its history.
  @Test func newFactsOfASessionThatTheIndexDoesNotHoldAddNoItem() async throws {
    let index = await Self.makeIndex(label: "facts-not-held", embedder: nil)

    await index.update(session: Self.sessionId, metadata: Self.metadata)

    #expect(await index.items(of: Self.sessionId).isEmpty)
  }

  /// Two indexes with different folders are independent: the server index finds a word of its
  /// session, and the client index finds nothing.
  @Test func twoIndexesWithDifferentFoldersAreIndependent() async throws {
    let server = await Self.makeFilledIndex(label: "server", embedder: nil)
    let client = await Self.makeIndex(label: "client", embedder: nil)

    #expect(
      [
        try await Self.firstMatchID(of: Self.chunkWord, in: server),
        try await Self.firstMatchID(of: Self.chunkWord, in: client),
      ]
        == ["\(Self.sessionId.rawValue)/1", nil])
  }
}
