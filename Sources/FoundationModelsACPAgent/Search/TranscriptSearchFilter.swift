import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import FoundationModelsRouter

/// The filters of the transcript search on the items that the registry matched (D207 (e)): the
/// sessions, the archive, the kinds, the dates, then the phrases and the exclusions.
///
/// The filters come in two costs (^w0dheny). The session filters, the kinds and the dates are
/// cheap. The phrases and the exclusions tokenize the block of the item: the search applies
/// them only to an item that passed the cheap filters, and only when the item can change the
/// page (``TranscriptSearchSessionCollector``).
///
/// The phrases and the exclusions compare the tokens of `Tokenizer.tokenize(text:)` of the
/// ranker: a phrase passes when its tokens are in the tokens of the block one after the other. A
/// session item passes the session filters, and it does not pass a `from:`, `after:` or
/// `before:` token. An external item (a session of another agent) does not pass a `from:` token,
/// and the date of its last record goes to the `after:` and `before:` tokens. It has no archive
/// state, so it passes with and without `is:archived`.
struct TranscriptSearchFilter: Sendable {
  /// The sessions that the session directory shows, by session id.
  let visibleSessions: [SessionId: TranscriptSearchVisibleSession]

  /// The sessions of the directory tokens, or `nil` for each visible session. A session id can
  /// be any string (^bm6spcd).
  let sessions: Set<SessionId>?

  /// The one session of a search for Find Next Hit, or `nil`.
  let session: SessionId?

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
  init(
    request: TranscriptIndexSearchRequest,
    visibleSessions: [SessionId: TranscriptSearchVisibleSession]
  ) {
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

  /// The session filters on one visible session: of the directory tokens and of the one
  /// session, and archived only with `is:archived`.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - visible: The facts of the session in the directory.
  /// - Returns: `true` when the session passes.
  func admits(_ id: SessionId, visible: TranscriptSearchVisibleSession) -> Bool {
    let inSessions = sessions?.contains(id) ?? true
    let isTheSession = session.map { $0 == id } ?? true
    return inSessions && isTheSession && (includeArchived || !visible.isArchived)
  }

  /// The cheap filters of the facts of an item: its kind and its date.
  ///
  /// - Parameter item: The item.
  /// - Returns: `true` when the kind and the date of the item pass.
  func admitsFacts(of item: TranscriptSearchItem) -> Bool {
    switch item.content {
    case .chunk(let chunk):
      admits(kind: TranscriptSearchCandidate.kind(of: chunk.kind), date: chunk.date)
    case .session:
      admits(kind: .session, date: nil)
    case .external(let summary):
      admits(kind: .session, date: summary.displayDate)
    }
  }

  /// The kind filter and the date filters.
  ///
  /// The kind filter keeps the kinds of the `from:` tokens. A session item passes only with no
  /// `from:` token: its kind `session` is then one of the kinds of the query.
  ///
  /// The date filters keep a date on or after the `after:` day and before the `before:` day. A
  /// chunk with no date, and a session item, pass only with no date token.
  ///
  /// - Parameters:
  ///   - kind: The kind of the hit of the item.
  ///   - date: The date of a chunk, or `nil` for a chunk with no date and for a session item.
  /// - Returns: `true` when the kind and the date pass.
  func admits(kind: SessionSearchHit.Kind, date: Date?) -> Bool {
    guard query.kinds.contains(kind) else {
      return false
    }
    guard query.after != nil || query.before != nil else {
      return true
    }
    guard let date else {
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
  func admitsText(of item: TranscriptSearchItem) -> Bool {
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
