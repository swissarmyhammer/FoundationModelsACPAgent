import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import FoundationModelsRouter

/// The filters of the transcript search on the items that the registry matched (D207 (e)), in
/// their order: the sessions, the archive, the kinds, the dates, then the phrases and the
/// exclusions.
///
/// The phrases and the exclusions compare the tokens of `Tokenizer.tokenize(text:)` of the
/// ranker: a phrase passes when its tokens are in the tokens of the block one after the other. A
/// session item passes the session filters, and it does not pass a `from:`, `after:` or
/// `before:` token.
struct TranscriptSearchFilter: Sendable {
  /// The sessions that the session directory shows, by session id.
  let visibleSessions: [SessionId: TranscriptSearchVisibleSession]

  /// The sessions of the directory tokens, or `nil` for each visible session.
  let sessions: Set<ULID>?

  /// The one session of a search for Find Next Hit, or `nil`.
  let session: ULID?

  /// True to keep the archived sessions.
  let includeArchived: Bool

  /// The parsed query.
  let query: SessionSearchQuery

  /// The tokens of each phrase that the block must hold.
  private let phraseTokens: [[String]]

  /// The tokens of each excluded word or phrase that the block must not hold.
  private let excludedTokens: [[String]]

  /// Makes the filters of a request.
  ///
  /// - Parameters:
  ///   - request: The request.
  ///   - visibleSessions: The sessions that the session directory shows.
  init(request: SessionSearchRequest, visibleSessions: [SessionId: TranscriptSearchVisibleSession])
  {
    self.visibleSessions = visibleSessions
    sessions = request.sessions
    session = request.session
    includeArchived = request.includeArchived
    query = request.query
    phraseTokens = request.query.phrases.map { Tokenizer.tokenize(text: $0) }.filter { !$0.isEmpty }
    excludedTokens = request.query.excluded.map { Tokenizer.tokenize(text: $0) }.filter {
      !$0.isEmpty
    }
  }

  /// Tells whether an item passes each filter.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the item passes.
  func admits(_ item: TranscriptSearchItem) -> Bool {
    admitsSession(of: item) && admitsKind(of: item) && admitsDate(of: item)
      && admitsText(of: item)
  }

  /// The session filters: a visible session of the directory tokens and of the one session, and
  /// an archived session only with `is:archived`.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the session of the item passes.
  private func admitsSession(of item: TranscriptSearchItem) -> Bool {
    guard let visible = visibleSessions[item.sessionId],
      let id = ULID(ulidString: item.sessionId.rawValue)
    else {
      return false
    }
    let inSessions = sessions?.contains(id) ?? true
    let isTheSession = session.map { $0 == id } ?? true
    return inSessions && isTheSession && (includeArchived || !visible.isArchived)
  }

  /// The kind filter: the kinds of the `from:` tokens. A session item passes only with no
  /// `from:` token: its kind `session` is then one of the kinds of the query.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the kind of the item passes.
  private func admitsKind(of item: TranscriptSearchItem) -> Bool {
    switch item.content {
    case .chunk(let chunk):
      query.kinds.contains(TranscriptSearchCandidate.kind(of: chunk.kind))
    case .session:
      query.kinds.contains(.session)
    }
  }

  /// The date filters: the date of a chunk is on or after the `after:` day and before the
  /// `before:` day. A chunk with no date, and a session item, pass only with no date token.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the date of the item passes.
  private func admitsDate(of item: TranscriptSearchItem) -> Bool {
    guard query.after != nil || query.before != nil else {
      return true
    }
    guard case .chunk(let chunk) = item.content, let date = chunk.date else {
      return false
    }
    let isAfter = query.after.map { date >= $0 } ?? true
    let isBefore = query.before.map { date < $0 } ?? true
    return isAfter && isBefore
  }

  /// The text filters: the block holds each phrase and no excluded word or phrase.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the block of the item passes.
  private func admitsText(of item: TranscriptSearchItem) -> Bool {
    guard !phraseTokens.isEmpty || !excludedTokens.isEmpty else {
      return true
    }
    let tokens = Tokenizer.tokenize(text: item.renderBlock())
    return phraseTokens.allSatisfy { Self.tokens(tokens, hold: $0) }
      && !excludedTokens.contains { Self.tokens(tokens, hold: $0) }
  }

  /// Tells whether tokens hold the tokens of a phrase one after the other.
  ///
  /// - Parameters:
  ///   - tokens: The tokens of a block.
  ///   - phrase: The tokens of the phrase. Not empty.
  /// - Returns: `true` when the phrase is in the tokens.
  private static func tokens(_ tokens: [String], hold phrase: [String]) -> Bool {
    guard phrase.count <= tokens.count else {
      return false
    }
    return (0...(tokens.count - phrase.count)).contains { start in
      tokens[start..<(start + phrase.count)].elementsEqual(phrase)
    }
  }
}
