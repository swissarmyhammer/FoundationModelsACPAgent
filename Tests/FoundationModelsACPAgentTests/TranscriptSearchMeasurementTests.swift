import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The environment variable that turns the measurement of the transcript search on.
private let measurementSwitchName = "TRANSCRIPT_SEARCH_MEASUREMENT"

/// The measurement of the transcript search index with a realistic history (D207, ^y7nx1g3):
/// 1,000 sessions of 10 turns, with a stored catalog. It measures the time of a search, the time
/// of a turn update, and the start time from the stored catalog, and prints the numbers.
///
/// The measurement is off by default, so the unit suite stays fast. Set the environment
/// variable `TRANSCRIPT_SEARCH_MEASUREMENT=1` to run it:
///
/// ```
/// TRANSCRIPT_SEARCH_MEASUREMENT=1 swift test --filter TranscriptSearchMeasurementTests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment[measurementSwitchName] == "1"))
struct TranscriptSearchMeasurementTests {
  // MARK: - Constants

  /// The number of sessions of the history.
  private static let sessionCount = 1_000

  /// The number of turns of each session.
  private static let turnCount = 10

  /// The time that the fake embedder takes for one text: a small fixed cost.
  private static let embedCost = Duration.microseconds(200)

  /// The number of runs of each timed step. The report gives the median and the maximum.
  private static let runCount = 10

  /// The number of different words of the history.
  private static let vocabularySize = 4_000

  /// The seed of the words of the history, so each run makes the same history.
  private static let seed: UInt64 = 0x5EED_D207

  /// The working folder of each session.
  private static let folder = URL(fileURLWithPath: "/projects/measure", isDirectory: true)

  /// The date of the first turn.
  private static let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// The time between two turns.
  private static let turnInterval: TimeInterval = 600

  /// The time zone of the parse of a query.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The most sessions of a page of the search.
  private static let pageLimit = 20

  /// The number of words of a chunk, for each kind of the turn, in the order of the turn.
  private static let turnShape: [(kind: SessionSearchChunk.Kind, words: Int, title: String)] = [
    (.user, 30, ""), (.thought, 70, ""), (.tool, 200, "Read Sources/App/Model.swift"),
    (.agent, 140, ""),
  ]

  // MARK: - The history

  /// A generator of the words of the history: SplitMix64, so each run makes the same words.
  private struct WordSource {
    /// The state of the generator.
    var state: UInt64

    /// The next number of the generator.
    ///
    /// - Returns: The number.
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      return value ^ (value >> 31)
    }

    /// A text of words of the vocabulary. A few words come often and most words come rarely,
    /// as in a real text.
    ///
    /// - Parameter count: The number of words.
    /// - Returns: The text.
    mutating func text(words count: Int) -> String {
      (0..<count).map { _ in
        let roll = Double(next() % 1_000_000) / 1_000_000
        let rank = Int(pow(roll, 3) * Double(TranscriptSearchMeasurementTests.vocabularySize))
        return TranscriptSearchMeasurementTests.word(rank)
      }.joined(separator: " ")
    }
  }

  /// The word of a rank of the vocabulary.
  ///
  /// - Parameter rank: The rank of the word.
  /// - Returns: The word.
  private static func word(_ rank: Int) -> String {
    let letters = Array("abcdefghiklmnoprstuvwyz")
    var value = rank + letters.count
    var word = ""
    while value > 0 {
      word.append(letters[value % letters.count])
      value /= letters.count
    }
    return word + "a"
  }

  /// The chunks of one turn.
  ///
  /// - Parameters:
  ///   - turn: The turn index.
  ///   - words: The source of the words.
  /// - Returns: The chunks.
  private static func turnChunks(_ turn: Int, words: inout WordSource) -> [SessionSearchChunk] {
    let date = firstDate.addingTimeInterval(Double(turn) * turnInterval)
    return turnShape.enumerated().map { place, shape in
      let body = words.text(words: shape.words)
      let text = shape.title.isEmpty ? body : "\(shape.title)\n\(body)"
      return SessionSearchChunk(
        turn: turn, ordinal: turn * turnShape.count + place, kind: shape.kind, author: nil,
        date: date, title: shape.title, text: text,
        entries: [
          SessionSearchChunk.EntryRange(
            id: .agentMessage(MessageId(rawValue: "entry-\(turn)-\(place)")),
            range: 0..<text.count)
        ])
    }
  }

  /// The content of each session of the history.
  ///
  /// - Returns: The content of each session, by session id.
  private static func history() -> [SessionId: TranscriptSearchIndex.SessionContent] {
    var words = WordSource(state: seed)
    return (0..<sessionCount).reduce(into: [:]) { contents, place in
      let session = SessionId(rawValue: ULID().ulidString)
      let chunks = (0..<turnCount).flatMap { turnChunks($0, words: &words) }
      contents[session] = TranscriptSearchIndex.SessionContent(
        chunks: chunks,
        metadata: TranscriptSessionMetadata(
          name: "Session \(place) \(words.text(words: 3))", slug: "session-\(place)",
          tags: [], folder: folder, agentName: nil, recap: words.text(words: 25),
          lastSummary: nil))
    }
  }

  // MARK: - The timing

  /// The time of one step.
  ///
  /// - Parameter step: The step.
  /// - Returns: The time, in milliseconds.
  private static func milliseconds(of step: () async throws -> Void) async rethrows -> Double {
    let elapsed = try await ContinuousClock().measure { try await step() }
    let parts = elapsed.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }

  /// The median and the maximum of a set of times.
  ///
  /// - Parameter times: The times, in milliseconds.
  /// - Returns: The text of the median and the maximum.
  private static func summary(_ times: [Double]) -> String {
    let sorted = times.sorted()
    let median = sorted[sorted.count / 2]
    return String(format: "median %.1f ms, max %.1f ms", median, sorted.last ?? median)
  }

  /// Prints one line of the report.
  ///
  /// - Parameter line: The line.
  private static func report(_ line: String) {
    print("TRANSCRIPT-SEARCH-MEASUREMENT \(line)")
  }

  /// A request of a query.
  ///
  /// - Parameter text: The text of the query.
  /// - Returns: The request.
  private static func request(_ text: String) throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: text, timeZone: timeZone), sessions: nil,
      includeArchived: false, preferredFolder: nil, session: nil, limit: pageLimit, cursor: nil)
  }

  // MARK: - The measurement

  /// Builds the stored catalog of 1,000 sessions, and measures a search, a turn update and a
  /// start from the stored catalog.
  @Test(.timeLimit(.minutes(30))) func measureOneThousandSessions() async throws {
    let contents = Self.history()
    let directory = makeResolvedDirectory(label: "TranscriptSearchMeasurementTests")
    let embedder = CountingEmbedding(costPerText: Self.embedCost)
    let index = await TranscriptSearchIndex(
      folder: directory, embedder: embedder, modelID: "fake-embedding",
      readableFolder: { _ in true })
    let build = await Self.milliseconds { await index.index(contents) }
    let save = await Self.milliseconds { await index.waitForSaves() }
    let itemCount = await index.catalog.count
    Self.report(
      "history: \(Self.sessionCount) sessions, \(Self.turnCount) turns each, \(itemCount) items, "
        + "embed cost \(Self.embedCost) a text")
    Self.report(
      String(format: "first build: %.0f ms (%d texts embedded), save: %.0f ms", build,
        embedder.embeddedTextCount, save))

    let visible = contents.keys.reduce(into: [SessionId: TranscriptSearchVisibleSession]()) {
      $0[$1] = TranscriptSearchVisibleSession(folder: Self.folder, isArchived: false)
    }
    for query in [Self.word(3), Self.word(900), "\(Self.word(10)) \(Self.word(2_500))", "from:tool"]
    {
      let request = try Self.request(query)
      var searchTimes: [Double] = []
      var matchTimes: [Double] = []
      for _ in 0..<Self.runCount {
        searchTimes.append(
          try await Self.milliseconds { _ = try await index.search(request, visibleSessions: visible) })
        matchTimes.append(try await Self.milliseconds { _ = try await index.matches(for: query) })
      }
      Self.report(
        "search \"\(query)\": \(Self.summary(searchTimes)); "
          + "registry matches alone: \(Self.summary(matchTimes))")
    }

    var words = WordSource(state: Self.seed ^ 1)
    var updateTimes: [Double] = []
    for session in contents.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(Self.runCount) {
      let content = try #require(contents[session])
      let chunks = content.chunks + Self.turnChunks(Self.turnCount, words: &words)
      updateTimes.append(
        await Self.milliseconds {
          await index.index(session: session, chunks: chunks, metadata: content.metadata)
        })
    }
    Self.report(
      "turn update (\(Self.turnShape.count) new chunks, embed included): "
        + Self.summary(updateTimes))
    await index.waitForSaves()
    let storedCount = await index.catalog.count

    let restartEmbedder = CountingEmbedding(costPerText: Self.embedCost)
    var restarted: TranscriptSearchIndex?
    let start = await Self.milliseconds {
      restarted = await TranscriptSearchIndex(
        folder: directory, embedder: restartEmbedder, modelID: "fake-embedding",
        readableFolder: { _ in true })
    }
    let restored = try #require(restarted)
    let firstSearch = try await Self.milliseconds {
      _ = try await restored.search(try Self.request(Self.word(900)), visibleSessions: visible)
    }
    Self.report(
      String(format: "start from the stored catalog: %.0f ms, first search after it: %.1f ms, "
        + "texts embedded: %d", start, firstSearch, restartEmbedder.embeddedTextCount))

    #expect(await restored.catalog.count == storedCount)
  }
}
