import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The search of the transcripts for the `sessions` tool and endpoint (D207 (c), (e)): the
/// filters on the matches of the registry, the sessions and their order, the hits with their
/// snippets, and the pages. Each search test runs with a fake embedder and with none.
@Suite struct TranscriptSearchTests {
  // MARK: - Types

  /// The embedder of an index of a test.
  enum Embedder: String, CaseIterable, Sendable {
    /// No embedder: the keyword signals only.
    case none

    /// The fake embedder of the transcript search tests.
    case wordBuckets

    /// The embedder, or `nil` for the keyword signals only.
    var embedder: (any PooledEmbedding)? {
      switch self {
      case .none:
        nil
      case .wordBuckets:
        WordBucketEmbedding()
      }
    }
  }

  // MARK: - Constants

  /// The session about a quokka, dated in January.
  private static let zooSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// The session about tiles, dated in March.
  private static let houseSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// The session with four chunks that hold the word ``kiwiWord``.
  private static let orchardSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YD")

  /// The folder of ``zooSession``.
  private static let zooFolder = URL(fileURLWithPath: "/projects/zoo", isDirectory: true)

  /// The folder of ``houseSession``.
  private static let houseFolder = URL(fileURLWithPath: "/projects/house", isDirectory: true)

  /// The folder of ``orchardSession``.
  private static let orchardFolder = URL(fileURLWithPath: "/projects/orchard", isDirectory: true)

  /// The time zone of the dates of the tests and of the parse of their queries.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The date of the chunks of ``zooSession``: 2026-01-10 at noon.
  private static let zooDate = Date(timeIntervalSince1970: 1_768_046_400)

  /// The date of the chunks of ``houseSession``: 2026-03-10 at noon.
  private static let houseDate = Date(timeIntervalSince1970: 1_773_144_000)

  /// The date of the chunks of ``orchardSession``: 2026-02-10 at noon.
  private static let orchardDate = Date(timeIntervalSince1970: 1_770_724_800)

  /// A day between the dates of ``zooSession`` and ``houseSession``.
  private static let middleDay = "2026-02-01"

  /// The word of the agent message of ``zooSession``.
  private static let quokkaWord = "quokka"

  /// The word of the name of ``zooSession``.
  private static let zebraWord = "zebra"

  /// The word of the thought of ``zooSession``.
  private static let wombatWord = "wombat"

  /// The word of the four agent messages of ``orchardSession``.
  private static let kiwiWord = "kiwi"

  /// The number of chunks of ``orchardSession`` that hold ``kiwiWord``.
  private static let kiwiChunkCount = 4

  /// The most hits of one session with no `session:` request.
  private static let hitsOfASession = 3

  /// The most sessions of a page of the tests.
  private static let pageLimit = 10

  /// The wire id of the agent message of ``zooSession``.
  private static let zooAgentEntry = "agent:zoo-agent"

  /// The wire id of the thought of ``zooSession``.
  private static let zooThoughtEntry = "thought:zoo-thought"

  // MARK: - Fixtures

  /// One chunk with one entry.
  ///
  /// - Parameters:
  ///   - ordinal: The place of the chunk in its session.
  ///   - kind: The kind of the chunk.
  ///   - entry: The id of the one entry of the chunk.
  ///   - date: The date of the chunk.
  ///   - text: The text of the chunk.
  /// - Returns: The chunk.
  private static func chunk(
    _ ordinal: Int, _ kind: SessionSearchChunk.Kind, entry: SessionEntry.ID, date: Date,
    text: String
  ) -> SessionSearchChunk {
    SessionSearchChunk(
      turn: 0, ordinal: ordinal, kind: kind, author: nil, date: date, title: "", text: text,
      entries: [SessionSearchChunk.EntryRange(id: entry, range: 0..<text.count)])
  }

  /// The facts of a session of the tests.
  ///
  /// - Parameters:
  ///   - name: The name of the session.
  ///   - folder: The folder of the session.
  /// - Returns: The facts.
  private static func metadata(name: String, folder: URL) -> TranscriptSessionMetadata {
    TranscriptSessionMetadata(
      name: name, slug: name.lowercased().replacingOccurrences(of: " ", with: "-"), tags: [],
      folder: folder, agentName: nil, recap: "Notes of \(name).", lastSummary: nil)
  }

  /// An index with the three sessions of the tests.
  ///
  /// - Parameters:
  ///   - label: The label of the folder of the index.
  ///   - embedder: The embedder of the index.
  ///   - readableFolder: The rule "this folder is readable now".
  /// - Returns: The index.
  private static func makeIndex(
    label: String, embedder: Embedder,
    readableFolder: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) async -> TranscriptSearchIndex {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "TranscriptSearchTests-\(label)-\(embedder.rawValue)"),
      embedder: embedder.embedder, modelID: nil, readableFolder: readableFolder)
    await index.index(
      session: zooSession,
      chunks: [
        chunk(
          0, .user, entry: .userMessage(MessageId(rawValue: "zoo-user")), date: zooDate,
          text: "Where do they live?"),
        chunk(
          1, .agent, entry: .agentMessage(MessageId(rawValue: "zoo-agent")), date: zooDate,
          text: "The \(quokkaWord) lives on an island."),
        chunk(
          2, .thought, entry: .agentThought(MessageId(rawValue: "zoo-thought")), date: zooDate,
          text: "I recall the \(wombatWord) diet."),
      ],
      metadata: metadata(name: "\(zebraWord) research", folder: zooFolder))
    await index.index(
      session: houseSession,
      chunks: [
        chunk(
          0, .user, entry: .userMessage(MessageId(rawValue: "house-user")), date: houseDate,
          text: "Which colour?"),
        chunk(
          1, .agent, entry: .agentMessage(MessageId(rawValue: "house-agent")), date: houseDate,
          text: "The blue tiles fit the wall."),
      ],
      metadata: metadata(name: "Kitchen plans", folder: houseFolder))
    await index.index(
      session: orchardSession,
      chunks: (0..<kiwiChunkCount).map { ordinal in
        chunk(
          ordinal, .agent, entry: .agentMessage(MessageId(rawValue: "orchard-\(ordinal)")),
          date: orchardDate, text: "Pick the \(kiwiWord) number \(ordinal).")
      },
      metadata: metadata(name: "Fruit harvest", folder: orchardFolder))
    return index
  }

  /// The sessions that the directory shows, none archived but those of `archived`.
  ///
  /// - Parameter archived: The archived sessions.
  /// - Returns: The visible sessions.
  private static func visibleSessions(archived: Set<SessionId> = [])
    -> [SessionId: TranscriptSearchVisibleSession]
  {
    [
      (zooSession, zooFolder), (houseSession, houseFolder), (orchardSession, orchardFolder),
    ].reduce(into: [:]) { visible, pair in
      visible[pair.0] = TranscriptSearchVisibleSession(
        folder: pair.1, isArchived: archived.contains(pair.0))
    }
  }

  /// A request of the tests.
  ///
  /// - Parameters:
  ///   - text: The text of the query.
  ///   - sessions: The sessions of the directory tokens, or `nil` for each visible session.
  ///   - includeArchived: True to include the archived sessions.
  ///   - preferredFolder: The folder whose sessions come first.
  ///   - session: The one session of the search, or `nil`.
  ///   - limit: The most sessions of the page.
  ///   - cursor: The cursor of the page.
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func request(
    _ text: String, sessions: Set<SessionId>? = nil, includeArchived: Bool = false,
    preferredFolder: URL? = nil, session: SessionId? = nil, limit: Int = pageLimit,
    cursor: String? = nil
  ) throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: text, timeZone: timeZone),
      sessions: try sessions.map { Set(try $0.map { try $0.ulid() }) },
      includeArchived: includeArchived, preferredFolder: preferredFolder,
      session: try session?.ulid(), limit: limit, cursor: cursor)
  }

  /// The ULIDs of sessions.
  ///
  /// - Parameter sessions: The sessions.
  /// - Returns: The ULIDs, in order.
  /// - Throws: The failure of an id that is not a ULID.
  private static func ulids(_ sessions: [SessionId]) throws -> [ULID] {
    try sessions.map { try $0.ulid() }
  }

  /// The hits of each session of a page, in order.
  ///
  /// - Parameter page: The page.
  /// - Returns: The hits.
  private static func allHits(of page: SessionSearchPage) -> [SessionSearchHit] {
    page.sessions.flatMap(\.hits)
  }

  // MARK: - Words and the session item

  /// A word finds the session of the chunk that holds it, with that chunk as the best hit.
  @Test(arguments: Embedder.allCases) func aWordFindsTheChunkThatHoldsIt(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "word", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.first?.entryID == Self.zooAgentEntry)
  }

  /// A word of the name of a session finds the session item: a hit of the kind `session`.
  @Test(arguments: Embedder.allCases) func aWordOfASessionNameFindsTheSessionItem(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "name", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.zebraWord), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.first?.kind == .session)
  }

  /// The hit of a session item gives the recap of the session as its snippet.
  @Test(arguments: Embedder.allCases) func theHitOfASessionItemGivesTheRecap(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "recap", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.zebraWord), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.first?.snippet == "Notes of \(Self.zebraWord) research.")
  }

  // MARK: - Phrases and exclusions

  /// A phrase keeps only the texts that hold its words one after the other.
  @Test(arguments: Embedder.allCases) func aPhraseKeepsOnlyTheTextsWithThePhrase(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "phrase", embedder: embedder)

    let page = try await index.search(
      Self.request("\"lives on\""), visibleSessions: Self.visibleSessions())

    #expect(Self.allHits(of: page).map(\.entryID) == [Self.zooAgentEntry])
  }

  /// A phrase whose words are in a different order in the text finds nothing.
  @Test(arguments: Embedder.allCases) func aPhraseInAnotherOrderFindsNothing(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "phrase-order", embedder: embedder)

    let page = try await index.search(
      Self.request("\"on lives\""), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.isEmpty)
  }

  /// An excluded word removes each text that holds it.
  @Test(arguments: Embedder.allCases) func anExcludedWordRemovesTheTextsWithIt(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "exclude", embedder: embedder)

    let page = try await index.search(
      Self.request("the island -\(Self.quokkaWord)"), visibleSessions: Self.visibleSessions())

    #expect(!Self.allHits(of: page).map(\.entryID).contains(Self.zooAgentEntry))
  }

  // MARK: - Kinds

  /// A `from:` token keeps only the chunks of its kind.
  @Test(arguments: Embedder.allCases) func aFromTokenKeepsOnlyItsKind(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "from", embedder: embedder)

    let page = try await index.search(
      Self.request("from:agent the"), visibleSessions: Self.visibleSessions())

    #expect(Set(Self.allHits(of: page).map(\.kind)) == [.agent])
  }

  /// With no `from:thought` token, a search gives no thought.
  @Test(arguments: Embedder.allCases) func aSearchGivesNoThoughtWithNoFromThought(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "no-thought", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.wombatWord), visibleSessions: Self.visibleSessions())

    #expect(!Self.allHits(of: page).map(\.kind).contains(.thought))
  }

  /// The `from:thought` token finds a thought.
  @Test(arguments: Embedder.allCases) func theFromThoughtTokenFindsAThought(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "thought", embedder: embedder)

    let page = try await index.search(
      Self.request("from:thought \(Self.wombatWord)"), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.first?.entryID == Self.zooThoughtEntry)
  }

  // MARK: - Dates

  /// An `after:` token keeps the chunks on or after its day, and no session item.
  @Test(arguments: Embedder.allCases) func anAfterTokenKeepsTheLaterChunks(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "after", embedder: embedder)

    let page = try await index.search(
      Self.request("after:2026-03-01 the"), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.map(\.session) == (try Self.ulids([Self.houseSession])))
  }

  /// A `before:` token keeps the chunks before its day, and no session item.
  @Test(arguments: Embedder.allCases) func aBeforeTokenKeepsTheEarlierChunks(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "before", embedder: embedder)

    let page = try await index.search(
      Self.request("before:\(Self.middleDay) the"), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.map(\.session) == (try Self.ulids([Self.zooSession])))
  }

  // MARK: - Sessions

  /// The sessions of an `@<session>` token keep only that session.
  @Test(arguments: Embedder.allCases) func aSessionReferenceKeepsOnlyItsSession(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "reference", embedder: embedder)

    let page = try await index.search(
      Self.request("the", sessions: [Self.houseSession]), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.map(\.session) == (try Self.ulids([Self.houseSession])))
  }

  /// A session that the directory does not show gives no result.
  @Test(arguments: Embedder.allCases) func aSessionThatIsNotVisibleGivesNoResult(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "visible", embedder: embedder)
    var visible = Self.visibleSessions()
    visible[Self.zooSession] = nil

    let page = try await index.search(Self.request(Self.quokkaWord), visibleSessions: visible)

    #expect(!page.sessions.map(\.session).contains(try Self.zooSession.ulid()))
  }

  /// An archived session gives no result with no `is:archived` token.
  @Test(arguments: Embedder.allCases) func anArchivedSessionIsLeftOut(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "archived", embedder: embedder)

    let page = try await index.search(
      Self.request("tiles"), visibleSessions: Self.visibleSessions(archived: [Self.houseSession]))

    #expect(!page.sessions.map(\.session).contains(try Self.houseSession.ulid()))
  }

  /// With `is:archived`, an archived session gives its results.
  @Test(arguments: Embedder.allCases) func isArchivedIncludesAnArchivedSession(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "is-archived", embedder: embedder)

    let page = try await index.search(
      Self.request("tiles", includeArchived: true),
      visibleSessions: Self.visibleSessions(archived: [Self.houseSession]))

    #expect(page.sessions.first?.session == (try Self.houseSession.ulid()))
  }

  // MARK: - A query with only tokens

  /// A query with only tokens lists the sessions of the chunks that pass the filters, newest
  /// first.
  @Test(arguments: Embedder.allCases) func aQueryWithOnlyTokensListsTheNewestFirst(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "tokens", embedder: embedder)

    let page = try await index.search(
      Self.request("from:agent"), visibleSessions: Self.visibleSessions())

    #expect(
      page.sessions.map(\.session)
        == (try Self.ulids([Self.houseSession, Self.orchardSession, Self.zooSession])))
  }

  /// A query with only tokens gives no session item.
  @Test(arguments: Embedder.allCases) func aQueryWithOnlyTokensGivesNoSessionItem(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "tokens-session", embedder: embedder)

    let page = try await index.search(
      Self.request("is:archived"), visibleSessions: Self.visibleSessions())

    #expect(!Self.allHits(of: page).map(\.kind).contains(.session))
  }

  // MARK: - Order

  /// The sessions of the preferred folder come first.
  @Test(arguments: Embedder.allCases) func theSessionsOfThePreferredFolderComeFirst(
    embedder: Embedder
  ) async throws {
    let index = await Self.makeIndex(label: "preferred", embedder: embedder)
    let plain = try await index.search(
      Self.request("the"), visibleSessions: Self.visibleSessions())
    let last = try #require(plain.sessions.last?.session)
    let lastFolder = try #require(
      Self.visibleSessions().first { (try? $0.key.ulid()) == last }?.value.folder)

    let preferred = try await index.search(
      Self.request("the", preferredFolder: lastFolder), visibleSessions: Self.visibleSessions())

    #expect(preferred.sessions.first?.session == last)
  }

  // MARK: - Snippets

  /// The snippet of a hit marks the query word, and its terms name it.
  @Test(arguments: Embedder.allCases) func theSnippetMarksTheQueryWord(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "snippet", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions())

    let hit = try #require(page.sessions.first?.hits.first)
    let characters = Array(hit.snippet)
    #expect(hit.ranges.map { String(characters[$0]) } == hit.terms)
  }

  /// The terms of the best hit of a word are the word.
  @Test(arguments: Embedder.allCases) func theTermsOfTheBestHitAreTheWord(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "terms", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.quokkaWord), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.first?.terms == [Self.quokkaWord])
  }

  /// A match with only the cosine signal gives the start of its entry and no range.
  @Test func aMatchWithOnlyCosineGivesTheStartOfItsEntry() {
    let chunk = Self.chunk(
      1, .agent, entry: .agentMessage(MessageId(rawValue: "zoo-agent")), date: Self.zooDate,
      text: "The \(Self.quokkaWord) lives on an island.")
    let item = TranscriptSearchItem(chunk: chunk, session: Self.zooSession)
    let match = Match(
      id: item.id, block: item.renderBlock(), score: 1, signals: Signals(bm25: 0, trigram: 0, cosine: 1),
      item: item)

    let hit = TranscriptSearchCandidate(match: match).hit(queryTerms: [Self.quokkaWord])

    #expect(
      hit
        == SessionSearchHit(
          entryID: Self.zooAgentEntry, kind: .agent, author: nil, date: Self.zooDate,
          snippet: chunk.text, ranges: [], terms: []))
  }

  // MARK: - Hits and pages

  /// A session gives at most three hits.
  @Test(arguments: Embedder.allCases) func aSessionGivesAtMostThreeHits(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "three", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.kiwiWord), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hits.count == Self.hitsOfASession)
  }

  /// The hit count of a session counts each hit, also the hits that the page does not give.
  @Test func theHitCountCountsEachHit() async throws {
    let index = await Self.makeIndex(label: "count", embedder: .none)

    let page = try await index.search(
      Self.request("from:agent \(Self.kiwiWord)"), visibleSessions: Self.visibleSessions())

    #expect(page.sessions.first?.hitCount == Self.kiwiChunkCount)
  }

  /// A search of one session gives each hit of the session.
  @Test(arguments: Embedder.allCases) func aSearchOfOneSessionGivesEachHit(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "one-session", embedder: embedder)

    let page = try await index.search(
      Self.request(Self.kiwiWord, session: Self.orchardSession),
      visibleSessions: Self.visibleSessions())

    let result = try #require(page.sessions.first)
    #expect(result.hits.count == result.hitCount)
  }

  /// The pages of a cursor give the sessions of one large page, in the same order.
  @Test(arguments: Embedder.allCases) func theCursorGivesTheNextPages(embedder: Embedder)
    async throws
  {
    let index = await Self.makeIndex(label: "cursor", embedder: embedder)
    let whole = try await index.search(
      Self.request("the"), visibleSessions: Self.visibleSessions())

    var paged: [ULID] = []
    var cursor: String?
    repeat {
      let page = try await index.search(
        Self.request("the", limit: 1, cursor: cursor), visibleSessions: Self.visibleSessions())
      paged += page.sessions.map(\.session)
      cursor = page.nextCursor
    } while cursor != nil && paged.count <= whole.sessions.count

    #expect(paged == whole.sessions.map(\.session))
  }

  /// A cursor that the search did not give is refused.
  @Test func aCursorThatTheSearchDidNotGiveIsRefused() async throws {
    let index = await Self.makeIndex(label: "bad-cursor", embedder: .none)

    await #expect(throws: TranscriptSearchError.self) {
      try await index.search(
        Self.request("the", cursor: "not a cursor"), visibleSessions: Self.visibleSessions())
    }
  }

  /// The folder of a session in the page that the process cannot read is unavailable.
  @Test(arguments: Embedder.allCases) func anUnreadableFolderIsUnavailable(embedder: Embedder)
    async throws
  {
    let house = Self.houseFolder
    let index = await Self.makeIndex(
      label: "unavailable", embedder: embedder, readableFolder: { $0 != house })

    let page = try await index.search(
      Self.request("tiles", sessions: [Self.houseSession]), visibleSessions: Self.visibleSessions())

    #expect(page.unavailableFolders == [Self.houseFolder])
  }
}
