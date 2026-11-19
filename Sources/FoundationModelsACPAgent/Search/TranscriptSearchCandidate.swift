import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool

/// One item of the transcript search that passed the filters, with its place in the order of
/// the search: a match of the registry, or a chunk of a query with only tokens.
struct TranscriptSearchCandidate: Sendable {
  /// The score of a chunk of a query with only tokens: the search ranks nothing, so the score
  /// is the lowest score.
  static let unrankedScore = 0.0

  /// The item.
  let item: TranscriptSearchItem

  /// The score of the item in `[0, 1]`.
  let score: Double

  /// True when the BM25 signal or the trigram signal of the registry scored the item. A match
  /// with only the cosine signal has no matched word.
  let hasKeywordSignal: Bool

  /// Makes the candidate of a match of the registry.
  ///
  /// - Parameter match: The match.
  init(match: Match<TranscriptSearchItem>) {
    item = match.item
    score = match.score
    hasKeywordSignal = match.signals.map { $0.bm25 > .zero || $0.trigram > .zero } ?? false
  }

  /// Makes the candidate of an item of a query with only tokens: no score and no matched word.
  ///
  /// - Parameter item: The item.
  init(listed item: TranscriptSearchItem) {
    self.item = item
    score = Self.unrankedScore
    hasKeywordSignal = false
  }

  /// The hit of the candidate (D207 (c) (3)).
  ///
  /// A chunk gives about 200 characters of its block around the part with the most query terms,
  /// with the wire id of the entry that holds the snippet. A match with only the cosine signal
  /// gives the start of the first entry of the chunk and no range. A session item gives a hit of
  /// the kind `session` with the recap of the session, or its name when it has no recap. A
  /// session item holds no entry, so the entry id of its hit is empty.
  ///
  /// - Parameter queryTerms: The terms of the ranking text of the query, as
  ///   `Tokenizer.tokenize(text:)` gives them.
  /// - Returns: The hit.
  func hit(queryTerms: Set<String>) -> SessionSearchHit {
    switch item.content {
    case .chunk(let chunk):
      return chunkHit(of: chunk, queryTerms: queryTerms)
    case .session(let metadata):
      let snippet = snippet(of: metadata.recap ?? metadata.name, from: 0, queryTerms: queryTerms)
      return SessionSearchHit(
        entryID: "", kind: .session, author: nil, date: nil, snippet: snippet.text,
        ranges: snippet.ranges, terms: snippet.terms)
    }
  }

  /// The hit of a chunk.
  ///
  /// - Parameters:
  ///   - chunk: The chunk.
  ///   - queryTerms: The query terms.
  /// - Returns: The hit.
  private func chunkHit(of chunk: SessionSearchChunk, queryTerms: Set<String>) -> SessionSearchHit
  {
    let block = item.renderBlock()
    let titleLength = block.count - chunk.text.count
    let entryStart = titleLength + (chunk.entries.first?.range.lowerBound ?? 0)
    let snippet = snippet(of: block, from: entryStart, queryTerms: queryTerms)
    return SessionSearchHit(
      entryID: Self.entry(of: chunk, at: snippet.anchor - titleLength)?.searchHitID ?? "",
      kind: Self.kind(of: chunk.kind), author: chunk.author, date: chunk.date,
      snippet: snippet.text, ranges: snippet.ranges, terms: snippet.terms)
  }

  /// The snippet of a text: around the query terms when a keyword signal scored the item, else
  /// the text from an offset with no range.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - offset: The offset of the start of a snippet with no matched word.
  ///   - queryTerms: The query terms.
  /// - Returns: The snippet.
  private func snippet(of text: String, from offset: Int, queryTerms: Set<String>)
    -> TranscriptSnippet
  {
    guard hasKeywordSignal else {
      return TranscriptSnippet.leading(text, from: offset)
    }
    return TranscriptSnippet.around(queryTerms, in: text)
  }

  /// The entry of a chunk that holds an offset of its text: the last entry that starts at or
  /// before the offset, or the first entry.
  ///
  /// - Parameters:
  ///   - chunk: The chunk.
  ///   - offset: The offset in the text of the chunk.
  /// - Returns: The id of the entry, or `nil` when the chunk has no entry.
  private static func entry(of chunk: SessionSearchChunk, at offset: Int) -> SessionEntry.ID? {
    (chunk.entries.last { $0.range.lowerBound <= offset } ?? chunk.entries.first)?.id
  }

  /// The kind of a hit of a chunk.
  ///
  /// - Parameter kind: The kind of the chunk.
  /// - Returns: The kind of the hit.
  static func kind(of kind: SessionSearchChunk.Kind) -> SessionSearchHit.Kind {
    switch kind {
    case .user: .user
    case .agent: .agent
    case .message: .message
    case .tool: .tool
    case .plan: .plan
    case .thought: .thought
    }
  }
}
