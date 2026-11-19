import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A query with only tokens lists the chunks newest first (D207 (c)). The order stays correct
/// after each change of the index: an upsert, a remove, a reconcile and a load of the stored
/// catalog (^w0dheny).
@Suite struct TranscriptSearchDateOrderTests {
  // MARK: - Constants

  /// The first session.
  private static let firstSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9Y1")

  /// The second session.
  private static let secondSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9Y2")

  /// The third session.
  private static let thirdSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9Y3")

  /// The folder of each session.
  private static let folder = URL(fileURLWithPath: "/projects/dates", isDirectory: true)

  /// The time zone of the parse of the query.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The query with only tokens of the tests.
  private static let tokenQuery = "from:agent"

  /// The most sessions of a page.
  private static let pageLimit = 10

  /// The oldest date of the tests: 2026-04-01 at noon.
  private static let oldDate = Date(timeIntervalSince1970: 1_775_044_800)

  /// The number of seconds of one day.
  private static let secondsOfADay: TimeInterval = 86_400

  /// A date one day after ``oldDate``.
  private static let middleDate = oldDate.addingTimeInterval(secondsOfADay)

  /// A date two days after ``oldDate``.
  private static let newDate = oldDate.addingTimeInterval(2 * secondsOfADay)

  // MARK: - Fixtures

  /// The content of a session with one agent chunk of a date.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - date: The date of the chunk.
  /// - Returns: The content.
  private static func content(_ session: SessionId, date: Date)
    -> TranscriptSearchIndex.SessionContent
  {
    let text = "An answer of \(session.rawValue)."
    return TranscriptSearchIndex.SessionContent(
      chunks: [
        SessionSearchChunk(
          turn: 0, ordinal: 0, kind: .agent, author: nil, date: date, title: "", text: text,
          entries: [
            SessionSearchChunk.EntryRange(
              id: .agentMessage(MessageId(rawValue: "\(session.rawValue)-agent")),
              range: 0..<text.count)
          ])
      ],
      metadata: TranscriptSessionMetadata(
        name: "Dates", slug: "dates", tags: [], folder: folder, agentName: nil, recap: nil,
        lastSummary: nil))
  }

  /// An index in a new folder with the first session at ``oldDate`` and the second session at
  /// ``middleDate``.
  ///
  /// - Parameter label: The label of the folder of the index.
  /// - Returns: The index.
  private static func makeIndex(label: String) async -> TranscriptSearchIndex {
    let index = makeEmptyIndex(
      folder: makeResolvedDirectory(label: "TranscriptSearchDateOrderTests-\(label)"))
    await index.index([
      firstSession: content(firstSession, date: oldDate),
      secondSession: content(secondSession, date: middleDate),
    ])
    return index
  }

  /// An index over a folder with no embedder. Its first call loads it.
  ///
  /// - Parameter folder: The folder of the index.
  /// - Returns: The index.
  private static func makeEmptyIndex(folder: URL) -> TranscriptSearchIndex {
    TranscriptSearchIndex(
      folder: folder, embedder: nil, modelID: nil, readableFolder: { _ in true })
  }

  /// The sessions of the page of the query with only tokens, in order.
  ///
  /// - Parameter index: The index.
  /// - Returns: The ULIDs of the sessions of the page.
  /// - Throws: An error of the search.
  private static func listedSessions(of index: TranscriptSearchIndex) async throws -> [ULID] {
    let request = SessionSearchRequest(
      query: try SessionSearchQuery(parsing: tokenQuery, timeZone: timeZone), sessions: nil,
      includeArchived: false, preferredFolder: nil, session: nil, limit: pageLimit, cursor: nil)
    let visible = [firstSession, secondSession, thirdSession].reduce(
      into: [SessionId: TranscriptSearchVisibleSession]()
    ) { $0[$1] = TranscriptSearchVisibleSession(folder: folder, isArchived: false) }
    return try await index.search(request, visibleSessions: visible).sessions.map(\.session)
  }

  /// The ULIDs of sessions.
  ///
  /// - Parameter sessions: The sessions.
  /// - Returns: The ULIDs, in order.
  /// - Throws: The failure of an id that is not a ULID.
  private static func ulids(_ sessions: [SessionId]) throws -> [ULID] {
    try sessions.map { try $0.ulid() }
  }

  // MARK: - Tests

  /// A session that gets a newer chunk comes first.
  @Test func anUpsertWithANewerChunkPutsTheSessionFirst() async throws {
    let index = await Self.makeIndex(label: "upsert")

    await index.index([Self.firstSession: Self.content(Self.firstSession, date: Self.newDate)])

    #expect(
      try await Self.listedSessions(of: index)
        == Self.ulids([Self.firstSession, Self.secondSession]))
  }

  /// A removed session is no longer listed.
  @Test func aRemovedSessionIsNotListed() async throws {
    let index = await Self.makeIndex(label: "remove")

    await index.remove(session: Self.secondSession)

    #expect(try await Self.listedSessions(of: index) == Self.ulids([Self.firstSession]))
  }

  /// A reconcile that adds a session and removes another lists the sessions it keeps and adds,
  /// newest first.
  @Test func aReconcileListsTheSessionsItKeepsNewestFirst() async throws {
    let index = await Self.makeIndex(label: "reconcile")

    await index.index(
      [
        Self.secondSession: Self.content(Self.secondSession, date: Self.middleDate),
        Self.thirdSession: Self.content(Self.thirdSession, date: Self.newDate),
      ], removing: [Self.firstSession])

    #expect(
      try await Self.listedSessions(of: index)
        == Self.ulids([Self.thirdSession, Self.secondSession]))
  }

  /// A new index over the stored catalog lists the sessions in the same order.
  @Test func aLoadOfTheStoredCatalogListsTheSessionsNewestFirst() async throws {
    let folder = makeResolvedDirectory(label: "TranscriptSearchDateOrderTests-load")
    let index = Self.makeEmptyIndex(folder: folder)
    await index.index([
      Self.firstSession: Self.content(Self.firstSession, date: Self.newDate),
      Self.secondSession: Self.content(Self.secondSession, date: Self.oldDate),
      Self.thirdSession: Self.content(Self.thirdSession, date: Self.middleDate),
    ])
    await index.waitForSaves()

    let restored = Self.makeEmptyIndex(folder: folder)
    await restored.load()

    #expect(
      try await Self.listedSessions(of: restored)
        == Self.ulids([Self.firstSession, Self.thirdSession, Self.secondSession]))
  }

  /// A query with only tokens on a new index that no call loaded yet waits for the load, and
  /// lists the stored sessions.
  @Test func aQueryBeforeTheLoadListsTheStoredSessions() async throws {
    let folder = makeResolvedDirectory(label: "TranscriptSearchDateOrderTests-before-load")
    let index = Self.makeEmptyIndex(folder: folder)
    await index.index([
      Self.firstSession: Self.content(Self.firstSession, date: Self.oldDate),
      Self.secondSession: Self.content(Self.secondSession, date: Self.newDate),
    ])
    await index.waitForSaves()

    let restored = Self.makeEmptyIndex(folder: folder)

    #expect(
      try await Self.listedSessions(of: restored)
        == Self.ulids([Self.secondSession, Self.firstSession]))
  }
}
