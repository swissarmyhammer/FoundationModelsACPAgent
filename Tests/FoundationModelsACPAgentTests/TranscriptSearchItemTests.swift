import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The items of the transcript search (D207 (b) (1)): the chunk items of the retained history of
/// a session, with the date that the history recorded for each turn, and the session item of a
/// session of the directory.
@Suite struct TranscriptSearchItemTests {
  // MARK: - Constants

  /// The session of the sample history.
  private static let sessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// The date that the clock of the sample history gives for each new message.
  private static let turnDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// The id of the user message of the sample history.
  private static let userMessageId = MessageId(rawValue: "user-1")

  /// The id of the agent message of the sample history.
  private static let agentMessageId = MessageId(rawValue: "agent-1")

  /// The id of the tool call of the sample history.
  private static let toolCallId = ToolCallId(rawValue: "tool-1")

  /// The text of the user message of the sample history.
  private static let userText = "Where are the zebra notes?"

  /// The text of the agent message of the sample history.
  private static let agentText = "The notes are in the archive."

  /// The title of the tool call of the sample history.
  private static let toolTitle = "Read the notes"

  /// The text content of the tool call of the sample history.
  private static let toolText = "zebra stripes and quokka facts"

  /// One word of the long tool output. The output repeats it past the maximum length of a chunk.
  private static let longOutputWord = "pangolin "

  /// The number of repeats of ``longOutputWord`` in the long tool output: more characters than
  /// one chunk holds.
  private static let longOutputRepeats = 300

  /// The metadata of the sample session.
  private static let metadata = TranscriptSessionMetadata(
    name: "Zebra research",
    slug: "zebra-research",
    tags: ["notes", "animals"],
    folder: URL(fileURLWithPath: "/projects/zoo", isDirectory: true),
    agentName: "Librarian",
    recap: "Found the zebra notes in the archive.",
    lastSummary: "The notes are in the archive.")

  /// Session ids that hold a "/". Under the rule `<session id>/<ordinal>` for a chunk item and
  /// the session id for a session item, a session item of one of them has the id of a chunk item
  /// of another one.
  private static let slashSessionIDs = ["a", "a/1", "a/1/0"].map(SessionId.init(rawValue:))

  /// The number of chunk items of each session of ``slashSessionIDs``.
  private static let slashChunkCount = 2

  // MARK: - Fixtures

  /// A chunk with no text, at a place in its session.
  ///
  /// - Parameter ordinal: The place of the chunk in the session.
  /// - Returns: The chunk.
  private static func emptyChunk(ordinal: Int) -> SessionSearchChunk {
    SessionSearchChunk(
      turn: 0, ordinal: ordinal, kind: .agent, author: nil, date: nil, title: "", text: "",
      entries: [])
  }

  /// The updates of the sample history: a user message, an agent message and a tool call with
  /// its title and text content.
  private static let sampleUpdates: [SessionUpdate] = [
    .userMessage(
      UserMessage(messageId: userMessageId, content: .value([.text(TextContent(text: userText))]))),
    .agentMessageChunk(
      ContentChunk(content: .text(TextContent(text: agentText)), messageId: agentMessageId)),
    .toolCallUpdate(
      ToolCallUpdate(
        toolCallId: toolCallId,
        content: .value([.content(Content(content: .text(TextContent(text: toolText))))]),
        status: .value(.completed),
        title: .value(toolTitle))),
  ]

  /// The retained history of `updates`, as a live session records it, with a clock that always
  /// gives ``turnDate``.
  ///
  /// - Parameter updates: The updates that the agent sends.
  /// - Returns: The history.
  private static func recordedHistory(of updates: [SessionUpdate] = sampleUpdates)
    -> SessionMergeEngine
  {
    let retained = RetainedHistory(SessionMergeEngine(), now: { turnDate })
    for update in updates {
      retained.apply(update)
    }
    return retained.snapshot
  }

  /// The chunk items of a history.
  ///
  /// - Parameter history: The retained history.
  /// - Returns: The items, in the order of the chunks.
  private static func chunkItems(of history: SessionMergeEngine) -> [TranscriptSearchItem] {
    history.searchChunks.map { TranscriptSearchItem(chunk: $0, session: sessionId) }
  }

  /// The chunk of a chunk item.
  ///
  /// - Parameter item: The item.
  /// - Returns: The chunk. The test fails when the item is a session item.
  private static func chunk(of item: TranscriptSearchItem) throws -> SessionSearchChunk {
    let chunk: SessionSearchChunk? =
      if case .chunk(let chunk) = item.content {
        chunk
      } else {
        nil
      }
    return try #require(chunk)
  }

  // MARK: - The chunk items

  /// The id of each chunk item is the session id and the ordinal of the chunk.
  @Test func theIdOfAChunkItemIsTheSessionIdAndTheOrdinal() {
    let items = Self.chunkItems(of: Self.recordedHistory())

    #expect(
      items.map(\.id) == (0..<3).map { "\(Self.sessionId.rawValue)/\($0)" })
  }

  /// A chunk item keeps its session, its turn, its kind and the wire ids of its entries.
  @Test func aChunkItemKeepsTheFieldsOfItsChunk() throws {
    let items = Self.chunkItems(of: Self.recordedHistory())
    let agent = try Self.chunk(of: items[1])

    #expect(
      Fields(
        sessionId: items[1].sessionId, turn: agent.turn, kind: agent.kind,
        entries: agent.entries.map(\.id.searchHitID))
        == Fields(
          sessionId: Self.sessionId, turn: 1, kind: .agent,
          entries: ["agent:\(Self.agentMessageId.rawValue)"]))
  }

  /// Each chunk of a turn has the date that the retained history recorded for the turn.
  @Test func eachChunkOfATurnHasTheRecordedDateOfTheTurn() throws {
    let items = Self.chunkItems(of: Self.recordedHistory())

    #expect(
      try items.map { try Self.chunk(of: $0).date } == [
        Self.turnDate, Self.turnDate, Self.turnDate,
      ])
  }

  /// A history that recorded no date gives chunks with no date: the date comes from the history,
  /// never from the clock of the search.
  @Test func aHistoryWithNoRecordedDateGivesChunksWithNoDate() throws {
    let items = Self.chunkItems(of: SessionMergeEngine(replaying: Self.sampleUpdates))

    #expect(try items.map { try Self.chunk(of: $0).date } == [nil, nil, nil])
  }

  /// The block of a chunk item of a message is the text of its chunk.
  @Test func theBlockOfAMessageChunkIsItsText() {
    let items = Self.chunkItems(of: Self.recordedHistory())

    #expect(items[1].renderBlock() == Self.agentText)
  }

  /// The block of the chunk item of a tool call has the title of the call as its first line.
  @Test func theBlockOfAToolCallChunkStartsWithItsTitle() {
    let items = Self.chunkItems(of: Self.recordedHistory())

    #expect(items[2].renderBlock() == "\(Self.toolTitle)\n\(Self.toolText)")
  }

  /// A later piece of a long tool call has the title of the call as its first line too, though
  /// the text of that piece does not hold the title.
  @Test func aLaterPieceOfALongToolCallStartsWithTheTitle() throws {
    let longOutput = String(repeating: Self.longOutputWord, count: Self.longOutputRepeats)
    let history = Self.recordedHistory(of: [
      .toolCallUpdate(
        ToolCallUpdate(
          toolCallId: Self.toolCallId,
          content: .value([.content(Content(content: .text(TextContent(text: longOutput))))]),
          title: .value(Self.toolTitle)))
    ])
    let items = Self.chunkItems(of: history)
    let lastPiece = try #require(items.last)

    #expect(lastPiece.renderBlock() == "\(Self.toolTitle)\n\(try Self.chunk(of: lastPiece).text)")
  }

  /// The same history gives the same items, also after the history goes through its file: the
  /// recorded dates are in the file.
  @Test func theSameHistoryGivesTheSameItemsAfterItsFile() throws {
    let history = Self.recordedHistory()
    let directory = makeResolvedDirectory(label: "TranscriptSearchItemTests-file")
    try SessionHistoryFile.write(history, in: directory)
    let read = try #require(try SessionHistoryFile.read(from: directory))

    #expect(Self.chunkItems(of: read) == Self.chunkItems(of: history))
  }

  /// The replay of a history leaves out the recorded dates: no client gets them.
  @Test func theReplayLeavesOutTheRecordedDates() {
    let replay = Self.recordedHistory().replayUpdates(from: .start)

    #expect(replay.map(\.kind) == [.userMessage, .agentMessage, .toolCallUpdate])
  }

  // MARK: - The session item

  /// The id of a session item is the session id with a "/" at the end.
  @Test func theIdOfASessionItemIsTheSessionIdAndASlash() {
    let item = TranscriptSearchItem(session: Self.sessionId, metadata: Self.metadata)

    #expect(item.id == "\(Self.sessionId.rawValue)/")
  }

  /// The items of sessions whose ids hold a "/" have different ids: the session item of `a/1`
  /// and the chunk item 1 of `a`, and the session item of `a/1/0` and the chunk item 0 of `a/1`
  /// (^8qsp7hb).
  @Test func theItemsOfSessionIdsWithASlashHaveDifferentIds() {
    let items = Self.slashSessionIDs.flatMap { session in
      [TranscriptSearchItem(session: session, metadata: Self.metadata)]
        + (0..<Self.slashChunkCount).map { ordinal in
          TranscriptSearchItem(chunk: Self.emptyChunk(ordinal: ordinal), session: session)
        }
    }

    #expect(Set(items.map(\.id)).count == items.count)
  }

  /// The block of a session item is the name, the slug, the tags, the folder, the agent name,
  /// the recap and the last summary, one on each line.
  @Test func theBlockOfASessionItemHasOneLineForEachFact() {
    let item = TranscriptSearchItem(session: Self.sessionId, metadata: Self.metadata)

    #expect(
      item.renderBlock()
        == [
          "Zebra research", "zebra-research", "animals notes", "/projects/zoo", "Librarian",
          "Found the zebra notes in the archive.", "The notes are in the archive.",
        ].joined(separator: "\n"))
  }

  /// The metadata of a session of the directory takes the title as the name, and the slug, the
  /// tags, the folder, the agent name, the recap and the last summary of the session.
  @Test func theMetadataOfADirectorySessionTakesItsFacts() throws {
    let summary = SessionSummary(
      id: try Self.sessionId.ulid(), agentID: "default", agentName: "Librarian",
      workingDirectory: Self.metadata.folder, title: "Zebra research", tags: ["notes", "animals"],
      kind: .root, state: .idle, origin: .client, createdAt: Self.turnDate,
      updatedAt: Self.turnDate, lastSummary: "The notes are in the archive.", isLive: false,
      recap: "Found the zebra notes in the archive.")

    #expect(TranscriptSessionMetadata(summary: summary) == Self.metadata)
  }

  // MARK: - The coding

  /// A chunk item decodes back to the same item.
  @Test func aChunkItemDecodesBackToTheSameItem() throws {
    let item = Self.chunkItems(of: Self.recordedHistory())[2]

    let decoded = try JSONDecoder().decode(
      TranscriptSearchItem.self, from: JSONEncoder().encode(item))

    #expect(decoded == item)
  }

  /// A session item decodes back to the same item.
  @Test func aSessionItemDecodesBackToTheSameItem() throws {
    let item = TranscriptSearchItem(session: Self.sessionId, metadata: Self.metadata)

    let decoded = try JSONDecoder().decode(
      TranscriptSearchItem.self, from: JSONEncoder().encode(item))

    #expect(decoded == item)
  }
}

/// The fields of a chunk item that one assertion compares.
private struct Fields: Equatable {
  /// The session of the item.
  let sessionId: SessionId

  /// The turn of the chunk.
  let turn: Int

  /// The kind of the chunk.
  let kind: SessionSearchChunk.Kind

  /// The text form of the id of each entry of the chunk.
  let entries: [String]
}
