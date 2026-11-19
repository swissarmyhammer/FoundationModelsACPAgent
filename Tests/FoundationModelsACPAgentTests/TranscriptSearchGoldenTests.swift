import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The pages of the transcript search for a fixed catalog and a fixed set of requests are the
/// pages in the golden file (D207, ^w0dheny). The golden file holds the pages that the search
/// gave before the change for speed. Thus a change of the search that keeps its results keeps
/// this suite green: the same sessions, the same order, the same hits and snippets, and the
/// same cursors.
///
/// The catalog has sessions in two folders, an archived session, a session that the directory
/// does not show, chunks of each kind, dates that the sessions share, and chunks with no date.
/// Each request runs with no embedder and with the fake embedder. Each request with a next
/// cursor also gives its next pages, through the cursor of the page before.
@Suite struct TranscriptSearchGoldenTests {
  // MARK: - Types

  /// One request of the golden set: its name in the golden file and its parts.
  private struct Case {
    /// The name of the case in the golden file.
    let name: String

    /// The text of the query.
    let query: String

    /// The places of the sessions of the directory tokens, or `nil` for each visible session.
    var sessions: [Int]?

    /// True to include the archived sessions.
    var includeArchived = false

    /// True to put the sessions of ``secondFolder`` first.
    var prefersSecondFolder = false

    /// The place of the one session of a `session:` request, or `nil`.
    var session: Int?

    /// The most sessions (or hits, for a `session:` request) of a page.
    var limit = TranscriptSearchGoldenTests.pageLimit
  }

  // MARK: - Constants

  /// The name of the golden file under `Tests/Fixtures`.
  private static let goldenFileName = "transcript-search-golden.json"

  /// The number of sessions of the catalog.
  private static let sessionCount = 24

  /// The first 24 characters of the ULID of each session. The last two characters are the
  /// place of the session.
  private static let ulidPrefix = "01KAXN6R4M8ZJ0C2W3Q5T7V9"

  /// The characters of a ULID, in their order.
  private static let ulidAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// The words of the texts of the catalog.
  private static let vocabulary = [
    "amber", "cobalt", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "kelp",
  ]

  /// The kinds of the chunks of a session, in the order of the chunks.
  private static let kindCycle: [SessionSearchChunk.Kind] = [
    .user, .thought, .tool, .agent, .plan, .message,
  ]

  /// The title of each tool call.
  private static let toolTitle = "Read Sources/Kiln.swift"

  /// The author of each message from another session.
  private static let messageAuthor = "helper"

  /// The number of words of a chunk.
  private static let wordsOfAChunk = 14

  /// The fewest chunks of a session.
  private static let fewestChunks = 6

  /// The number of chunks that one more step of a session adds.
  private static let chunksOfAStep = 3

  /// The number of steps of the chunk counts of the sessions.
  private static let chunkSteps = 4

  /// The first day of the dates of the catalog: 2026-03-01 at midnight UTC.
  private static let firstDay = Date(timeIntervalSince1970: 1_772_323_200)

  /// The number of seconds of one day.
  private static let secondsOfADay: TimeInterval = 86_400

  /// The number of seconds of one hour.
  private static let secondsOfAnHour: TimeInterval = 3_600

  /// The number of days of the dates of the sessions.
  private static let dayCount = 9

  /// The step between the days of two sessions that follow each other.
  private static let dayStep = 5

  /// The number of chunks of one turn: the chunks of a turn share their date.
  private static let chunksOfATurn = 2

  /// Each session whose place has this remainder by ``noDatePeriod`` has a last chunk with no
  /// date.
  private static let noDateRemainder = 4

  /// The period of the sessions with a last chunk with no date.
  private static let noDatePeriod = 5

  /// Each session whose place has this remainder by ``archivePeriod`` is archived.
  private static let archiveRemainder = 6

  /// The period of the archived sessions.
  private static let archivePeriod = 7

  /// The period of the sessions of ``secondFolder``: each session whose place is a multiple of
  /// it.
  private static let secondFolderPeriod = 3

  /// The place of the session that the directory does not show.
  private static let hiddenSession = 5

  /// The multiplier of the generator of the words.
  private static let generatorMultiplier: UInt64 = 6_364_136_223_846_793_005

  /// The increment of the generator of the words.
  private static let generatorIncrement: UInt64 = 1_442_695_040_888_963_407

  /// The step between the first states of the generator for two sessions that follow each
  /// other. It is more than the number of chunks of a session, so no two chunks share a state.
  private static let generatorSessionStride = 1_000

  /// The ordinal of the words of the recap of a session: an ordinal that no chunk has.
  private static let recapOrdinal = generatorSessionStride - 1

  /// The shift of the state of the generator before it picks a word.
  private static let generatorShift: UInt64 = 33

  /// The folder of most sessions. The process can read it.
  private static let firstFolder = URL(fileURLWithPath: "/projects/kiln", isDirectory: true)

  /// The folder of each session whose place is a multiple of ``secondFolderPeriod``. The
  /// process cannot read it.
  private static let secondFolder = URL(fileURLWithPath: "/projects/forge", isDirectory: true)

  /// The time zone of the dates of the queries.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The most sessions of a page.
  private static let pageLimit = 4

  /// The most pages of one case.
  private static let pageCount = 3

  /// The requests of the golden set.
  private static let cases: [Case] = [
    Case(name: "word", query: "amber"),
    Case(name: "words", query: "amber cobalt"),
    Case(name: "phrase", query: "\"amber cobalt\""),
    Case(name: "exclusion", query: "amber -delta"),
    Case(name: "from-tool", query: "garnet from:tool"),
    Case(name: "from-thought", query: "garnet from:thought"),
    Case(name: "dates", query: "harbor after:2026-03-03 before:2026-03-08"),
    Case(name: "session-name", query: "project"),
    Case(name: "session-request", query: "amber", session: 4, limit: 2),
    Case(name: "token-only", query: "from:agent"),
    Case(name: "token-only-dates", query: "from:user -delta after:2026-03-04"),
    Case(name: "token-only-session", query: "from:plan from:tool", session: 8, limit: 2),
    Case(name: "preferred-folder", query: "indigo", prefersSecondFolder: true),
    Case(name: "token-only-preferred", query: "from:message", prefersSecondFolder: true),
    Case(name: "archived", query: "juniper", includeArchived: true),
    Case(name: "directory-sessions", query: "kelp", sessions: [1, 2, 3, 6, 9, 13]),
  ]

  // MARK: - The catalog

  /// The id of the session at a place.
  ///
  /// - Parameter place: The place of the session.
  /// - Returns: The id.
  private static func session(_ place: Int) -> SessionId {
    let alphabet = ulidAlphabet
    let high = alphabet[place / alphabet.count]
    let low = alphabet[place % alphabet.count]
    return SessionId(rawValue: "\(ulidPrefix)\(high)\(low)")
  }

  /// The folder of the session at a place.
  ///
  /// - Parameter place: The place of the session.
  /// - Returns: The folder.
  private static func folder(_ place: Int) -> URL {
    place.isMultiple(of: secondFolderPeriod) ? secondFolder : firstFolder
  }

  /// The words of one chunk, from a fixed generator.
  ///
  /// - Parameters:
  ///   - place: The place of the session.
  ///   - ordinal: The ordinal of the chunk.
  /// - Returns: The text.
  private static func text(session place: Int, ordinal: Int) -> String {
    var state = UInt64(place * generatorSessionStride + ordinal)
    return (0..<wordsOfAChunk).map { _ in
      state = state &* generatorMultiplier &+ generatorIncrement
      return vocabulary[Int((state >> generatorShift) % UInt64(vocabulary.count))]
    }.joined(separator: " ")
  }

  /// The date of a chunk: the day of its session and the hour of its turn, or `nil` for the
  /// last chunk of each session whose place has the remainder ``noDateRemainder``.
  ///
  /// - Parameters:
  ///   - place: The place of the session.
  ///   - ordinal: The ordinal of the chunk.
  ///   - count: The number of chunks of the session.
  /// - Returns: The date.
  private static func date(session place: Int, ordinal: Int, count: Int) -> Date? {
    guard place % noDatePeriod != noDateRemainder || ordinal != count - 1 else {
      return nil
    }
    let day = Double(place * dayStep % dayCount)
    let hour = Double(ordinal / chunksOfATurn)
    return firstDay.addingTimeInterval(day * secondsOfADay + hour * secondsOfAnHour)
  }

  /// The entry id of the first or the second entry of a chunk.
  ///
  /// - Parameters:
  ///   - kind: The kind of the chunk.
  ///   - name: The name of the entry.
  /// - Returns: The entry id.
  private static func entry(kind: SessionSearchChunk.Kind, name: String) -> SessionEntry.ID {
    switch kind {
    case .user: .userMessage(MessageId(rawValue: name))
    case .thought: .agentThought(MessageId(rawValue: name))
    case .tool: .toolCall(ToolCallId(rawValue: name))
    case .plan: .plan(PlanId(rawValue: name))
    case .message: .sessionMessage(MessageId(rawValue: name))
    case .agent: .agentMessage(MessageId(rawValue: name))
    }
  }

  /// One chunk of a session. A chunk holds two entries: the first half of its text and the
  /// rest. A tool chunk of an odd turn is a later piece of its call, with no title line.
  ///
  /// - Parameters:
  ///   - place: The place of the session.
  ///   - ordinal: The ordinal of the chunk.
  ///   - count: The number of chunks of the session.
  /// - Returns: The chunk.
  private static func chunk(session place: Int, ordinal: Int, count: Int) -> SessionSearchChunk {
    let kind = kindCycle[ordinal % kindCycle.count]
    let turn = ordinal / chunksOfATurn
    let body = text(session: place, ordinal: ordinal)
    let isFirstPiece = turn.isMultiple(of: 2)
    let text = kind == .tool && isFirstPiece ? "\(toolTitle)\n\(body)" : body
    let middle = text.count / 2
    return SessionSearchChunk(
      turn: turn, ordinal: ordinal, kind: kind, author: kind == .message ? messageAuthor : nil,
      date: date(session: place, ordinal: ordinal, count: count),
      title: kind == .tool ? toolTitle : "", text: text,
      entries: [
        SessionSearchChunk.EntryRange(
          id: entry(kind: kind, name: "s\(place)-c\(ordinal)-a"), range: 0..<middle),
        SessionSearchChunk.EntryRange(
          id: entry(kind: kind, name: "s\(place)-c\(ordinal)-b"), range: middle..<text.count),
      ])
  }

  /// The content of the session at a place.
  ///
  /// - Parameter place: The place of the session.
  /// - Returns: The content.
  private static func content(session place: Int) -> TranscriptSearchIndex.SessionContent {
    let count = fewestChunks + (place % chunkSteps) * chunksOfAStep
    let name = vocabulary[place % vocabulary.count]
    return TranscriptSearchIndex.SessionContent(
      chunks: (0..<count).map { chunk(session: place, ordinal: $0, count: count) },
      metadata: TranscriptSessionMetadata(
        name: "Project \(name) \(place)", slug: "project-\(name)-\(place)", tags: [name],
        folder: folder(place), agentName: nil,
        recap: text(session: place, ordinal: recapOrdinal), lastSummary: nil))
  }

  /// An index with each session of the catalog. The process cannot read ``secondFolder``.
  ///
  /// - Parameter embedder: The embedder of the index.
  /// - Returns: The index.
  private static func makeIndex(embedder: TranscriptSearchTests.Embedder) async
    -> TranscriptSearchIndex
  {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "TranscriptSearchGoldenTests-\(embedder.rawValue)"),
      embedder: embedder.embedder, modelID: nil,
      readableFolder: { $0 != TranscriptSearchGoldenTests.secondFolder })
    await index.load()
    await index.index(
      Dictionary(
        uniqueKeysWithValues: (0..<sessionCount).map { (session($0), content(session: $0)) }))
    return index
  }

  /// The sessions that the directory shows: each session but ``hiddenSession``, with the
  /// archived sessions.
  ///
  /// - Returns: The visible sessions.
  private static func visibleSessions() -> [SessionId: TranscriptSearchVisibleSession] {
    (0..<sessionCount).filter { $0 != hiddenSession }.reduce(into: [:]) { visible, place in
      visible[session(place)] = TranscriptSearchVisibleSession(
        folder: folder(place), isArchived: place % archivePeriod == archiveRemainder)
    }
  }

  // MARK: - The pages

  /// The request of a case.
  ///
  /// - Parameters:
  ///   - testCase: The case.
  ///   - cursor: The cursor of the page.
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func request(of testCase: Case, cursor: String?) throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: testCase.query, timeZone: timeZone),
      sessions: try testCase.sessions.map { Set(try $0.map { try session($0).ulid() }) },
      includeArchived: testCase.includeArchived,
      preferredFolder: testCase.prefersSecondFolder ? secondFolder : nil,
      session: try testCase.session.map { try session($0).ulid() }, limit: testCase.limit,
      cursor: cursor)
  }

  /// The pages of each case: the first page, and each next page through the cursor of the
  /// page before, up to ``pageCount`` pages.
  ///
  /// - Parameter embedder: The embedder of the index.
  /// - Returns: The pages of each case, by the name of the embedder and the name of the case.
  /// - Throws: An error of the search.
  private static func pages(embedder: TranscriptSearchTests.Embedder) async throws
    -> [String: [SessionSearchPage]]
  {
    let index = await makeIndex(embedder: embedder)
    let visible = visibleSessions()
    var pages: [String: [SessionSearchPage]] = [:]
    for testCase in cases {
      var casePages: [SessionSearchPage] = []
      var cursor: String?
      repeat {
        let page = try await index.search(
          request(of: testCase, cursor: cursor), visibleSessions: visible)
        casePages.append(page)
        cursor = page.nextCursor
      } while cursor != nil && casePages.count < pageCount
      pages["\(embedder.rawValue)/\(testCase.name)"] = casePages
    }
    return pages
  }

  /// The pages of the golden file.
  ///
  /// - Returns: The pages of each case, by the name of the embedder and the name of the case.
  /// - Throws: An error of the read or of the decode.
  private static func goldenPages() throws -> [String: [SessionSearchPage]] {
    let file = try PackageRoot.directory()
      .appendingPathComponent("Tests/Fixtures")
      .appendingPathComponent(goldenFileName)
    return try JSONDecoder().decode(
      [String: [SessionSearchPage]].self, from: Data(contentsOf: file))
  }

  // MARK: - Tests

  /// Each case gives the pages of the golden file, with each embedder.
  @Test(arguments: TranscriptSearchTests.Embedder.allCases) func eachCaseGivesTheGoldenPages(
    embedder: TranscriptSearchTests.Embedder
  ) async throws {
    let pages = try await Self.pages(embedder: embedder)
    let golden = try Self.goldenPages()

    for (name, casePages) in pages.sorted(by: { $0.key < $1.key }) {
      #expect(casePages == golden[name], "case \(name)")
    }
  }
}
