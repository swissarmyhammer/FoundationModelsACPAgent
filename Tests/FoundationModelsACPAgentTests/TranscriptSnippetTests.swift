import Testing

@testable import FoundationModelsACPAgent

/// The snippet of a hit of the transcript search (D207 (c) (3)): about 200 characters of a text
/// around the part with the most query words, cut at word ends, with the ranges and the text of
/// the matched words.
@Suite struct TranscriptSnippetTests {
  // MARK: - Constants

  /// The query word of the tests.
  private static let queryWord = "quokka"

  /// A long text with the query word in its middle: 60 filler words, the query word, and 60
  /// filler words.
  private static let longText =
    Array(repeating: "filler", count: 60).joined(separator: " ") + " The \(queryWord)! "
    + Array(repeating: "padding", count: 60).joined(separator: " ")

  // MARK: - Helpers

  /// The text of each range of a snippet.
  ///
  /// - Parameter snippet: The snippet.
  /// - Returns: The marked texts, in order.
  private static func markedTexts(of snippet: TranscriptSnippet) -> [String] {
    let characters = Array(snippet.text)
    return snippet.ranges.map { String(characters[$0]) }
  }

  // MARK: - Tests

  /// The ranges of a snippet mark the query word in the snippet text.
  @Test func theRangesMarkTheQueryWord() {
    let snippet = TranscriptSnippet.around([Self.queryWord], in: Self.longText)

    #expect(Self.markedTexts(of: snippet) == [Self.queryWord])
  }

  /// The terms of a snippet are the matched words as the text writes them.
  @Test func theTermsAreTheMatchedWordsOfTheText() {
    let snippet = TranscriptSnippet.around(["the"], in: "The cat saw the dog.")

    #expect(snippet.terms == ["The", "the"])
  }

  /// A snippet of a long text has at most the snippet length.
  @Test func aSnippetOfALongTextHasAtMostTheSnippetLength() {
    let snippet = TranscriptSnippet.around([Self.queryWord], in: Self.longText)

    #expect(snippet.text.count <= TranscriptSnippet.maximumLength)
  }

  /// A snippet starts and ends at word ends: each of its words is a whole word of the text.
  @Test func aSnippetIsCutAtWordEnds() {
    let snippet = TranscriptSnippet.around([Self.queryWord], in: Self.longText)

    #expect(
      Set(snippet.text.split(separator: " ")).isSubset(of: Set(Self.longText.split(separator: " "))))
  }

  /// A query word of a different letter case and in a code identifier matches with the tokens of
  /// the ranker.
  @Test func aWordMatchesWithTheTokensOfTheRanker() {
    let snippet = TranscriptSnippet.around(["user"], in: "Call getUser now.")

    #expect(Self.markedTexts(of: snippet) == ["getUser"])
  }

  /// A word with a letter that is not ASCII matches with the tokens of the ranker.
  @Test func aWordWithALetterThatIsNotASCIIMatches() {
    let snippet = TranscriptSnippet.around(["straße"], in: "Die Straße ist lang.")

    #expect(Self.markedTexts(of: snippet) == ["Straße"])
  }

  /// A word that holds a query word only as a part of a longer token does not match.
  @Test func aLongerTokenThatHoldsTheQueryWordDoesNotMatch() {
    let snippet = TranscriptSnippet.around([Self.queryWord], in: "Two quokkas live here.")

    #expect(snippet.ranges.isEmpty)
  }

  /// The leading snippet of a text from an offset gives the text from that offset and no range.
  @Test func theLeadingSnippetStartsAtTheOffsetWithNoRange() {
    let snippet = TranscriptSnippet.leading("Title\nThe quokka lives.", from: 6)

    #expect(snippet == TranscriptSnippet(text: "The quokka lives.", start: 6, ranges: [], terms: []))
  }

  /// A text with no query word gives its start and no range.
  @Test func aTextWithNoQueryWordGivesItsStart() {
    let snippet = TranscriptSnippet.around(["zebra"], in: "The quokka lives.")

    #expect(snippet == TranscriptSnippet(text: "The quokka lives.", start: 0, ranges: [], terms: []))
  }
}
