import FoundationModelsMetadataRegistry

/// The snippet of a hit of the transcript search (D207 (c) (3)): about 200 characters of a text
/// around the part with the most query words, cut at word ends, with the ranges and the text of
/// the matched words.
///
/// A word is a run of characters that are not white space. A word matches when one of the tokens
/// that `Tokenizer.tokenize(text:)` of the ranker gives for it is a query term, so the snippet
/// marks the words with the same rule as the BM25 signal. All offsets count characters.
struct TranscriptSnippet: Equatable, Sendable {
  /// One word of a text.
  private struct Word {
    /// The characters of the word in the text, with its punctuation.
    let span: Range<Int>

    /// The characters of the word in the text with no punctuation at the two ends, or `nil` when
    /// the word does not match.
    let match: Range<Int>?
  }

  /// The most characters of a snippet.
  static let maximumLength = 200

  /// The text of the snippet.
  let text: String

  /// The offset of the snippet in its source text.
  let start: Int

  /// The matched words, as ranges of character offsets in ``text``.
  let ranges: [Range<Int>]

  /// The matched words as the text writes them, each one time, in the order of the text.
  let terms: [String]

  /// The offset in the source text of the first matched word, or of the snippet start when no
  /// word matches.
  var anchor: Int {
    start + (ranges.first?.lowerBound ?? 0)
  }

  /// The snippet of a text around the part with the most query terms. A text with no query term
  /// gives its start and no range.
  ///
  /// - Parameters:
  ///   - queryTerms: The query terms, as `Tokenizer.tokenize(text:)` gives them.
  ///   - source: The text.
  /// - Returns: The snippet.
  static func around(_ queryTerms: Set<String>, in source: String) -> TranscriptSnippet {
    let characters = Array(source)
    let words = words(of: characters, queryTerms: queryTerms)
    guard let window = bestWindow(of: words, characters: characters) else {
      return leading(source, from: 0)
    }
    return snippet(of: characters, words: words, window: window)
  }

  /// The snippet of a text from an offset, with no range: the start of an entry.
  ///
  /// - Parameters:
  ///   - source: The text.
  ///   - offset: The offset of the start, in characters.
  /// - Returns: The snippet.
  static func leading(_ source: String, from offset: Int) -> TranscriptSnippet {
    let characters = Array(source)
    let start = min(max(offset, 0), characters.count)
    let words = words(of: characters, queryTerms: []).filter { $0.span.lowerBound >= start }
    guard let first = words.first else {
      return TranscriptSnippet(text: "", start: start, ranges: [], terms: [])
    }
    let end = cutEnd(of: words, from: first.span.lowerBound)
    return TranscriptSnippet(
      text: String(characters[first.span.lowerBound..<end]), start: first.span.lowerBound,
      ranges: [], terms: [])
  }

  /// The words of a text.
  ///
  /// - Parameters:
  ///   - characters: The characters of the text.
  ///   - queryTerms: The query terms.
  /// - Returns: The words, in order.
  private static func words(of characters: [Character], queryTerms: Set<String>) -> [Word] {
    var words: [Word] = []
    var index = 0
    while index < characters.count {
      guard !characters[index].isWhitespace else {
        index += 1
        continue
      }
      let lower = index
      while index < characters.count, !characters[index].isWhitespace {
        index += 1
      }
      words.append(word(of: characters, span: lower..<index, queryTerms: queryTerms))
    }
    return words
  }

  /// One word of a text, with its match.
  ///
  /// - Parameters:
  ///   - characters: The characters of the text.
  ///   - span: The characters of the word.
  ///   - queryTerms: The query terms.
  /// - Returns: The word.
  private static func word(of characters: [Character], span: Range<Int>, queryTerms: Set<String>)
    -> Word
  {
    let tokens = Tokenizer.tokenize(text: String(characters[span]))
    guard !queryTerms.isDisjoint(with: tokens) else {
      return Word(span: span, match: nil)
    }
    let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
    let lower = span.first { isWordCharacter(characters[$0]) } ?? span.lowerBound
    let upper = (span.last { isWordCharacter(characters[$0]) }).map { $0 + 1 } ?? span.upperBound
    return Word(span: span, match: lower..<upper)
  }

  /// The words of the best window: the first and the last matched word of the window of
  /// ``maximumLength`` characters with the most different matched texts, then the most matched
  /// words, then the earliest start.
  ///
  /// - Parameters:
  ///   - words: The words of the text.
  ///   - characters: The characters of the text.
  /// - Returns: The indexes of the first and the last matched word, or `nil` when no word
  ///   matches.
  private static func bestWindow(of words: [Word], characters: [Character]) -> ClosedRange<Int>? {
    let matched = words.indices.filter { words[$0].match != nil }
    var best: (window: ClosedRange<Int>, distinct: Int, count: Int)?
    for (place, first) in matched.enumerated() {
      let limit = words[first].span.lowerBound + maximumLength
      let inside = matched[place...].prefix { words[$0].span.upperBound <= limit }
      let last = inside.last ?? first
      let texts = Set(inside.compactMap { words[$0].match.map { String(characters[$0]).lowercased() } })
      if best.map({ (texts.count, inside.count) > ($0.distinct, $0.count) }) ?? true {
        best = (first...last, texts.count, inside.count)
      }
    }
    return best?.window
  }

  /// The snippet of a window: the matched words in the middle, with the words around them, cut
  /// at word ends.
  ///
  /// - Parameters:
  ///   - characters: The characters of the text.
  ///   - words: The words of the text.
  ///   - window: The indexes of the first and the last matched word of the window.
  /// - Returns: The snippet.
  private static func snippet(of characters: [Character], words: [Word], window: ClosedRange<Int>)
    -> TranscriptSnippet
  {
    let core = words[window.lowerBound].span.lowerBound..<words[window.upperBound].span.upperBound
    let slack = max(0, maximumLength - core.count)
    let wanted = max(0, min(core.lowerBound - slack / 2, characters.count - maximumLength))
    let start = words.first { $0.span.lowerBound >= wanted }.map(\.span.lowerBound) ?? core.lowerBound
    let end = max(cutEnd(of: words, from: start), min(core.upperBound, start + maximumLength))
    let inside = words.compactMap(\.match).filter { $0.lowerBound >= start && $0.upperBound <= end }
    var terms: [String] = []
    for range in inside where !terms.contains(String(characters[range])) {
      terms.append(String(characters[range]))
    }
    return TranscriptSnippet(
      text: String(characters[start..<end]), start: start,
      ranges: inside.map { ($0.lowerBound - start)..<($0.upperBound - start) }, terms: terms)
  }

  /// The end of a snippet that starts at an offset: the end of the last word that ends at most
  /// ``maximumLength`` characters after the start. A first word that is longer is cut at
  /// ``maximumLength`` characters.
  ///
  /// - Parameters:
  ///   - words: The words of the text.
  ///   - start: The start of the snippet.
  /// - Returns: The end of the snippet.
  private static func cutEnd(of words: [Word], from start: Int) -> Int {
    let limit = start + maximumLength
    let fitting = words.last { $0.span.lowerBound >= start && $0.span.upperBound <= limit }
    guard let fitting else {
      let first = words.first { $0.span.lowerBound >= start }
      return min(first?.span.upperBound ?? start, limit)
    }
    return fitting.span.upperBound
  }
}
