import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The search of an index whose session ids are not all ULIDs (^bm6spcd). The client index of
/// the app holds the sessions of other ACP agents, whose session ids are UUIDs or other strings.
/// The search by ``SessionId`` gives them. The search of Multitool still gives only the sessions
/// whose ids are ULIDs.
@Suite struct TranscriptSearchSessionIdTests {
  // MARK: - Constants

  /// A session of another agent with a UUID as its session id, dated in January.
  private static let uuidSession = SessionId(rawValue: "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f")

  /// A session of another agent with a free-form session id, dated in March.
  private static let freeFormSession = SessionId(rawValue: "thread-alpha.42")

  /// A session of this server with a ULID as its session id, dated in February.
  private static let ulidSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// The folder of each session of the tests.
  private static let folder = URL(fileURLWithPath: "/projects/burrow", isDirectory: true)

  /// The time zone of the parse of the queries.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The date of the chunk of ``uuidSession``: 2026-01-10 at noon.
  private static let uuidDate = Date(timeIntervalSince1970: 1_768_046_400)

  /// The date of the chunk of ``ulidSession``: 2026-02-10 at noon.
  private static let ulidDate = Date(timeIntervalSince1970: 1_770_724_800)

  /// The date of the chunk of ``freeFormSession``: 2026-03-10 at noon.
  private static let freeFormDate = Date(timeIntervalSince1970: 1_773_144_000)

  /// The word that only the chunk of ``uuidSession`` holds.
  private static let quokkaWord = "quokka"

  /// The word that only the chunk of ``freeFormSession`` holds.
  private static let wombatWord = "wombat"

  /// The word that the chunk of each session holds.
  private static let burrowWord = "burrow"

  /// The text of the chunk of ``uuidSession``.
  private static let uuidText = "The \(quokkaWord) digs a \(burrowWord)."

  /// The wire id of the agent message of ``uuidSession``.
  private static let uuidEntry = "agent:uuid-agent"

  /// The wire id of the agent message of ``freeFormSession``.
  private static let freeFormEntry = "agent:free-form-agent"

  /// The most sessions of a page of the tests.
  private static let pageLimit = 10

  // MARK: - Fixtures

  /// One agent chunk with one entry.
  ///
  /// - Parameters:
  ///   - entry: The message id of the one entry of the chunk.
  ///   - date: The date of the chunk.
  ///   - text: The text of the chunk.
  /// - Returns: The chunk.
  private static func chunk(entry: String, date: Date, text: String) -> SessionSearchChunk {
    SessionSearchChunk(
      turn: 0, ordinal: 0, kind: .agent, author: nil, date: date, title: "", text: text,
      entries: [
        SessionSearchChunk.EntryRange(
          id: .agentMessage(MessageId(rawValue: entry)), range: 0..<text.count)
      ])
  }

  /// The facts of a session of the tests.
  ///
  /// - Parameter name: The name of the session.
  /// - Returns: The facts.
  private static func metadata(name: String) -> TranscriptSessionMetadata {
    TranscriptSessionMetadata(
      name: name, slug: name, tags: [], folder: folder, agentName: nil, recap: "", lastSummary: nil)
  }

  /// An index with the three sessions of the tests.
  ///
  /// - Parameters:
  ///   - label: The label of the folder of the index.
  ///   - embedder: The embedder of the index.
  /// - Returns: The index.
  private static func makeIndex(label: String, embedder: TranscriptSearchTests.Embedder) async
    -> TranscriptSearchIndex
  {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(
        label: "TranscriptSearchSessionIdTests-\(label)-\(embedder.rawValue)"),
      embedder: embedder.embedder, modelID: nil, readableFolder: { _ in true })
    await index.load()
    await index.index(
      session: uuidSession, chunks: [chunk(entry: "uuid-agent", date: uuidDate, text: uuidText)],
      metadata: metadata(name: "uuid"))
    await index.index(
      session: freeFormSession,
      chunks: [
        chunk(
          entry: "free-form-agent", date: freeFormDate,
          text: "The \(wombatWord) sleeps in the \(burrowWord).")
      ],
      metadata: metadata(name: "free-form"))
    await index.index(
      session: ulidSession,
      chunks: [
        chunk(entry: "ulid-agent", date: ulidDate, text: "A rabbit leaves the \(burrowWord).")
      ],
      metadata: metadata(name: "ulid"))
    return index
  }

  /// The sessions that the directory shows: each session of the tests.
  private static var visibleSessions: [SessionId: TranscriptSearchVisibleSession] {
    [uuidSession, freeFormSession, ulidSession].reduce(into: [:]) { visible, session in
      visible[session] = TranscriptSearchVisibleSession(folder: folder, isArchived: false)
    }
  }

  /// A request by session id of the tests.
  ///
  /// - Parameters:
  ///   - text: The text of the query.
  ///   - sessions: The sessions of the directory tokens, or `nil` for each visible session.
  ///   - session: The one session of the search, or `nil`.
  ///   - limit: The most sessions of the page.
  ///   - cursor: The cursor of the page.
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func request(
    _ text: String, sessions: Set<SessionId>? = nil, session: SessionId? = nil,
    limit: Int = pageLimit, cursor: String? = nil
  ) throws -> TranscriptIndexSearchRequest {
    TranscriptIndexSearchRequest(
      query: try SessionSearchQuery(parsing: text, timeZone: timeZone), sessions: sessions,
      includeArchived: false, preferredFolder: nil, session: session, limit: limit, cursor: cursor)
  }

  // MARK: - The search by session id

  /// A word finds the session whose id is a UUID, as the best session.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func aWordFindsAUUIDSession(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "uuid", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.first?.session == Self.uuidSession)
  }

  /// A word finds the session whose id is a free-form string, as the best session.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func aWordFindsAFreeFormSession(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "free-form", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.wombatWord), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.first?.session == Self.freeFormSession)
  }

  /// The best hit of a UUID session is the chunk that holds the word.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func theHitOfAUUIDSessionIsItsChunk(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "uuid-hit", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.first?.hits.first?.entryID == Self.uuidEntry)
  }

  /// The hit of a UUID session gives the text of its chunk as its snippet.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func theHitOfAUUIDSessionHasASnippet(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "uuid-snippet", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.first?.hits.first?.snippet == Self.uuidText)
  }

  /// A query with only tokens lists each session newest first, whatever the form of its id.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func aQueryWithOnlyTokensListsEachId(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "tokens", embedder: embedder)

    let page = try await index.search(
      Self.request("from:agent"), visibleSessions: Self.visibleSessions)

    #expect(
      page.sessions.map(\.session) == [Self.freeFormSession, Self.ulidSession, Self.uuidSession])
  }

  /// A query with only tokens gives the hit of a free-form session.
  @Test func aQueryWithOnlyTokensGivesTheHitOfAFreeFormSession() async throws {
    let index = await Self.makeIndex(label: "tokens-hit", embedder: .none)

    let page = try await index.search(
      Self.request("from:agent"), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.first?.hits.map(\.entryID) == [Self.freeFormEntry])
  }

  /// The sessions of the directory tokens keep a UUID session.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func theSessionsFilterKeepsAUUID(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "sessions", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.burrowWord, sessions: [Self.uuidSession]),
      visibleSessions: Self.visibleSessions)

    #expect(page.sessions.map(\.session) == [Self.uuidSession])
  }

  /// A search of one free-form session gives the hits of that session.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func aSearchOfAFreeFormSession(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "one-session", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.burrowWord, session: Self.freeFormSession),
      visibleSessions: Self.visibleSessions)

    #expect(page.sessions.map(\.session) == [Self.freeFormSession])
  }

  /// The pages of a cursor give the sessions of one large page, in the same order.
  @Test func theCursorGivesTheNextPagesOfEachId() async throws {
    let index = await Self.makeIndex(label: "cursor", embedder: .none)
    let whole = try await index.search(
      Self.request(Self.burrowWord), visibleSessions: Self.visibleSessions)

    var paged: [SessionId] = []
    var cursor: String?
    repeat {
      let page = try await index.search(
        Self.request(Self.burrowWord, limit: 1, cursor: cursor),
        visibleSessions: Self.visibleSessions)
      paged += page.sessions.map(\.session)
      cursor = page.nextCursor
    } while cursor != nil && paged.count <= whole.sessions.count

    #expect(paged == whole.sessions.map(\.session) && paged.count == Self.visibleSessions.count)
  }

  // MARK: - The search of Multitool

  /// The search of Multitool gives only the session whose id is a ULID, as its ULID.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func theMultitoolSearchGivesTheULID(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "multitool", embedder: embedder)
    let request = SessionSearchRequest(
      query: try SessionSearchQuery(parsing: Self.burrowWord, timeZone: Self.timeZone),
      sessions: nil, includeArchived: false, preferredFolder: nil, session: nil,
      limit: Self.pageLimit, cursor: nil)

    let page = try await index.search(request, visibleSessions: Self.visibleSessions)

    #expect(page.sessions.map(\.session) == [try Self.ulidSession.ulid()])
  }
}
