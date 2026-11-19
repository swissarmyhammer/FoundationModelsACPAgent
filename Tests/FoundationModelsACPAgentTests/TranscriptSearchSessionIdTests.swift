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

  /// The second ULID session of the Multitool index, dated in February.
  private static let secondULIDSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// The third ULID session of the Multitool index, dated in February.
  private static let thirdULIDSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YD")

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

  /// The word that the chunks of ``ulidSession`` and of ``secondULIDSession`` hold. The folder of
  /// the sessions does not hold it, so a search for it gives no hit of the folder.
  private static let rabbitWord = "rabbit"

  /// The text of the first chunk of ``ulidSession``.
  private static let ulidText = "A \(rabbitWord) leaves the \(burrowWord)."

  /// The wire id of the agent message of ``uuidSession``.
  private static let uuidEntry = "agent:uuid-agent"

  /// The wire id of the agent message of ``freeFormSession``.
  private static let freeFormEntry = "agent:free-form-agent"

  /// The wire id of the first agent message of ``ulidSession`` in the Multitool index.
  private static let firstULIDEntry = "ulid-agent"

  /// The wire id of the second agent message of ``ulidSession`` in the Multitool index.
  private static let secondULIDEntry = "ulid-agent-again"

  /// The wire id of an agent message, as a hit gives it.
  ///
  /// - Parameter entry: The message id of the entry.
  /// - Returns: The wire id.
  private static func agentEntryID(_ entry: String) -> String { "agent:\(entry)" }

  /// The most sessions of a page of the tests.
  private static let pageLimit = 10

  /// A limit of a request that no other request of the tests uses.
  private static let unusedLimit = 7

  /// A cursor of a request that no other request of the tests uses.
  private static let unusedCursor = "cursor-of-the-conversion"

  // MARK: - Fixtures

  /// One agent chunk with one entry.
  ///
  /// - Parameters:
  ///   - ordinal: The ordinal of the chunk in its session, which is also its turn.
  ///   - entry: The message id of the one entry of the chunk.
  ///   - date: The date of the chunk.
  ///   - text: The text of the chunk.
  /// - Returns: The chunk.
  private static func chunk(ordinal: Int = 0, entry: String, date: Date, text: String)
    -> SessionSearchChunk
  {
    SessionSearchChunk(
      turn: ordinal, ordinal: ordinal, kind: .agent, author: nil, date: date, title: "", text: text,
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

  /// A loaded index with no session.
  ///
  /// - Parameters:
  ///   - label: The label of the folder of the index.
  ///   - embedder: The embedder of the index.
  /// - Returns: The index.
  private static func makeEmptyIndex(label: String, embedder: TranscriptSearchTests.Embedder)
    async -> TranscriptSearchIndex
  {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(
        label: "TranscriptSearchSessionIdTests-\(label)-\(embedder.rawValue)"),
      embedder: embedder.embedder, modelID: nil, readableFolder: { _ in true })
    await index.load()
    return index
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
    let index = await makeEmptyIndex(label: label, embedder: embedder)
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
        chunk(entry: firstULIDEntry, date: ulidDate, text: ulidText)
      ],
      metadata: metadata(name: "ulid"))
    return index
  }

  /// An index with three ULID sessions for the search of Multitool. ``ulidSession`` has two
  /// chunks that hold ``burrowWord``. Each other session has one such chunk. ``ulidSession`` and
  /// ``secondULIDSession`` hold ``rabbitWord``.
  ///
  /// - Parameters:
  ///   - label: The label of the folder of the index.
  ///   - embedder: The embedder of the index.
  /// - Returns: The index.
  private static func makeULIDIndex(label: String, embedder: TranscriptSearchTests.Embedder)
    async -> TranscriptSearchIndex
  {
    let index = await makeEmptyIndex(label: "ulid-\(label)", embedder: embedder)
    await index.index(
      session: ulidSession,
      chunks: [
        chunk(entry: firstULIDEntry, date: ulidDate, text: ulidText),
        chunk(
          ordinal: 1, entry: secondULIDEntry, date: ulidDate,
          text: "The \(rabbitWord) comes back to the \(burrowWord)."),
      ],
      metadata: metadata(name: "ulid"))
    await index.index(
      session: secondULIDSession,
      chunks: [
        chunk(
          entry: "second-agent", date: ulidDate,
          text: "A mole digs under the \(burrowWord) of the \(rabbitWord).")
      ],
      metadata: metadata(name: "second-ulid"))
    await index.index(
      session: thirdULIDSession,
      chunks: [
        chunk(entry: "third-agent", date: ulidDate, text: "A fox waits at the \(burrowWord).")
      ],
      metadata: metadata(name: "third-ulid"))
    return index
  }

  /// The visible sessions of a list of sessions, none of them archived.
  ///
  /// - Parameter sessions: The sessions.
  /// - Returns: The visible sessions.
  private static func visible(_ sessions: [SessionId]) -> [SessionId:
    TranscriptSearchVisibleSession]
  {
    sessions.reduce(into: [:]) { visible, session in
      visible[session] = TranscriptSearchVisibleSession(folder: folder, isArchived: false)
    }
  }

  /// The sessions that the directory shows: each session of the tests.
  private static var visibleSessions: [SessionId: TranscriptSearchVisibleSession] {
    visible([uuidSession, freeFormSession, ulidSession])
  }

  /// The sessions that the directory shows for the Multitool index: its three ULID sessions.
  private static var visibleULIDSessions: [SessionId: TranscriptSearchVisibleSession] {
    visible([ulidSession, secondULIDSession, thirdULIDSession])
  }

  /// A request of Multitool.
  ///
  /// - Parameters:
  ///   - text: The text of the query.
  ///   - sessions: The ULIDs of the directory tokens, or `nil` for each visible session.
  ///   - session: The ULID of the one session of the search, or `nil`.
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func multitoolRequest(
    _ text: String = burrowWord, sessions: Set<ULID>? = nil, session: ULID? = nil
  ) throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: text, timeZone: timeZone), sessions: sessions,
      includeArchived: false, preferredFolder: nil, session: session, limit: pageLimit,
      cursor: nil)
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

    let page = try await index.search(
      Self.multitoolRequest(), visibleSessions: Self.visibleSessions)

    #expect(page.sessions.map(\.session) == [try Self.ulidSession.ulid()])
  }

  /// The `sessions:` ULIDs of a Multitool request keep only those sessions.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases)
  func theMultitoolSessionsFilterKeepsItsULIDs(embedder: TranscriptSearchTests.Embedder)
    async throws
  {
    let index = await Self.makeULIDIndex(label: "multitool-sessions", embedder: embedder)
    let kept: Set<ULID> = [try Self.ulidSession.ulid(), try Self.thirdULIDSession.ulid()]

    let page = try await index.search(
      Self.multitoolRequest(sessions: kept), visibleSessions: Self.visibleULIDSessions)

    #expect(Set(page.sessions.map(\.session)) == kept)
  }

  /// The `session:` ULID of a Multitool request gives only that session, with each of its hits:
  /// the hits that the search by session id gives for the same session, both chunks among them.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases)
  func theMultitoolSessionGivesEachHitOfItsULID(embedder: TranscriptSearchTests.Embedder)
    async throws
  {
    let index = await Self.makeULIDIndex(label: "multitool-session", embedder: embedder)
    let byId = try await index.search(
      Self.request(Self.rabbitWord, session: Self.ulidSession),
      visibleSessions: Self.visibleULIDSessions)
    let sessionHits = try #require(byId.sessions.first).hits
    try #require(
      Set(sessionHits.map(\.entryID)).isSuperset(
        of: [Self.agentEntryID(Self.firstULIDEntry), Self.agentEntryID(Self.secondULIDEntry)]))

    let page = try await index.search(
      Self.multitoolRequest(Self.rabbitWord, session: try Self.ulidSession.ulid()),
      visibleSessions: Self.visibleULIDSessions)

    let hitsBySession = Dictionary(
      page.sessions.map { ($0.session.description, $0.hits) }, uniquingKeysWith: +)
    #expect(hitsBySession == [Self.ulidSession.rawValue: sessionHits])
  }

  /// The conversion of a Multitool request gives each field of the request, each ULID as the
  /// session id of its text.
  @Test func theConversionOfAMultitoolRequestKeepsEachField() throws {
    let query = try SessionSearchQuery(parsing: Self.burrowWord, timeZone: Self.timeZone)
    let multitool = SessionSearchRequest(
      query: query,
      sessions: [try Self.secondULIDSession.ulid(), try Self.thirdULIDSession.ulid()],
      includeArchived: true, preferredFolder: Self.folder, session: try Self.ulidSession.ulid(),
      limit: Self.unusedLimit, cursor: Self.unusedCursor)

    let converted = TranscriptIndexSearchRequest(multitool)

    #expect(
      converted
        == TranscriptIndexSearchRequest(
          query: query, sessions: [Self.secondULIDSession, Self.thirdULIDSession],
          includeArchived: true, preferredFolder: Self.folder, session: Self.ulidSession,
          limit: Self.unusedLimit, cursor: Self.unusedCursor))
  }
}
