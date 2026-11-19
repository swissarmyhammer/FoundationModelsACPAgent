import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import FoundationModelsRouter

/// The sessions of one search: each session with the candidates that passed the filters, in the
/// order of the search.
private struct TranscriptSearchSession {
  /// The session.
  let id: SessionId

  /// The ULID of the session.
  let ulid: ULID

  /// The folder of the session.
  let folder: URL

  /// The candidates of the session, the best first.
  var candidates: [TranscriptSearchCandidate]
}

extension TranscriptSearchIndex {
  /// The most hits of one session in a page, with no `session:` request (D207 (c)).
  static let hitsOfASession = 3

  /// One page of the sessions that match a request (D207 (c), (e)).
  ///
  /// A request with a ranking text asks the registry for one match for each item of the catalog
  /// (``matches(for:)``). A request with only tokens does not call the registry: it lists the
  /// chunk items, newest first. The filters of ``TranscriptSearchFilter`` then remove the items
  /// that do not apply. The order of a session is the place of its first item, and its score is
  /// the score of that item. The sessions of the preferred folder come first (D199 (d)). Each
  /// session gives at most ``hitsOfASession`` hits, or each hit for a `session:` request. A
  /// folder of a session of the page that the process cannot read goes into the unavailable
  /// folders.
  ///
  /// - Parameters:
  ///   - request: The request. The directory tokens of its query are resolved into its
  ///     sessions and its archive flag.
  ///   - visibleSessions: The sessions that the session directory shows now, with their folder
  ///     and their archive state. An item of another session does not pass.
  /// - Returns: The page.
  /// - Throws: ``TranscriptSearchError/invalidCursor`` for a cursor that a search did not give,
  ///   or an error of the searcher.
  public func search(
    _ request: SessionSearchRequest, visibleSessions: [SessionId: TranscriptSearchVisibleSession]
  ) async throws -> SessionSearchPage {
    let offset = try TranscriptSearchCursor.offset(of: request.cursor)
    let filter = TranscriptSearchFilter(request: request, visibleSessions: visibleSessions)
    let candidates = try await candidates(of: request.query.rankingText, filter: filter)
    let sessions = Self.sessions(
      of: candidates, visibleSessions: visibleSessions, preferredFolder: request.preferredFolder)
    let queryTerms = Set(Tokenizer.tokenize(text: request.query.rankingText))
    let limit = max(1, request.limit)
    guard request.session == nil else {
      return Self.hitPage(of: sessions.first, offset: offset, limit: limit, queryTerms: queryTerms)
        .withUnavailableFolders(of: sessions.prefix(1).map(\.folder), readable: readableFolder)
    }
    let page = sessions.dropFirst(offset).prefix(limit)
    let next = offset + page.count < sessions.count ? offset + page.count : nil
    return SessionSearchPage(
      sessions: page.map {
        Self.result(of: $0, hits: $0.candidates.prefix(Self.hitsOfASession), queryTerms: queryTerms)
      },
      nextCursor: next.map(TranscriptSearchCursor.cursor(of:)), unavailableFolders: []
    ).withUnavailableFolders(of: page.map(\.folder), readable: readableFolder)
  }

  /// The candidates of a search that pass the filters, in the order of the search.
  ///
  /// - Parameters:
  ///   - rankingText: The ranking text of the query.
  ///   - filter: The filters.
  /// - Returns: The matches of the registry, or the chunk items newest first for an empty
  ///   ranking text.
  /// - Throws: An error of the searcher.
  private func candidates(of rankingText: String, filter: TranscriptSearchFilter) async throws
    -> [TranscriptSearchCandidate]
  {
    guard rankingText.isEmpty else {
      return try await matches(for: rankingText).filter { filter.admits($0.item) }.map(
        TranscriptSearchCandidate.init(match:))
    }
    return catalog.filter { $0.isChunk && filter.admits($0) }.sorted(by: Self.isNewer).map(
      TranscriptSearchCandidate.init(listed:))
  }

  /// Tells whether a chunk item comes before another in the newest-first order: the later date
  /// first, a chunk with no date last, and then the later session and the later chunk first.
  ///
  /// - Parameters:
  ///   - lhs: An item.
  ///   - rhs: Another item.
  /// - Returns: `true` when `lhs` comes first.
  private static func isNewer(_ lhs: TranscriptSearchItem, _ rhs: TranscriptSearchItem) -> Bool {
    let lhsDate = lhs.chunkDate ?? .distantPast
    let rhsDate = rhs.chunkDate ?? .distantPast
    guard lhsDate == rhsDate else {
      return lhsDate > rhsDate
    }
    guard lhs.sessionId == rhs.sessionId else {
      return lhs.sessionId.rawValue > rhs.sessionId.rawValue
    }
    return (lhs.chunkOrdinal ?? 0) > (rhs.chunkOrdinal ?? 0)
  }

  /// The sessions of the candidates: in the order of their first candidate, with the sessions of
  /// the preferred folder first.
  ///
  /// - Parameters:
  ///   - candidates: The candidates, in the order of the search.
  ///   - visibleSessions: The sessions that the directory shows.
  ///   - preferredFolder: The folder whose sessions come first, or `nil`.
  /// - Returns: The sessions.
  private static func sessions(
    of candidates: [TranscriptSearchCandidate],
    visibleSessions: [SessionId: TranscriptSearchVisibleSession], preferredFolder: URL?
  ) -> [TranscriptSearchSession] {
    var sessions: [TranscriptSearchSession] = []
    var places: [SessionId: Int] = [:]
    for candidate in candidates {
      let id = candidate.item.sessionId
      if let place = places[id] {
        sessions[place].candidates.append(candidate)
      } else if let visible = visibleSessions[id], let ulid = ULID(ulidString: id.rawValue) {
        places[id] = sessions.count
        sessions.append(
          TranscriptSearchSession(
            id: id, ulid: ulid, folder: visible.folder, candidates: [candidate]))
      }
    }
    guard let preferred = preferredFolder.map(comparablePath(of:)) else {
      return sessions
    }
    let isPreferred = { (session: TranscriptSearchSession) in
      comparablePath(of: session.folder) == preferred
    }
    return sessions.filter(isPreferred) + sessions.filter { !isPreferred($0) }
  }

  /// The page of a `session:` request: the hits of the one session, paged by the limit.
  ///
  /// - Parameters:
  ///   - session: The session, or `nil` when it has no hit.
  ///   - offset: The offset of the first hit of the page.
  ///   - limit: The most hits of the page.
  ///   - queryTerms: The query terms.
  /// - Returns: The page.
  private static func hitPage(
    of session: TranscriptSearchSession?, offset: Int, limit: Int, queryTerms: Set<String>
  ) -> SessionSearchPage {
    guard let session else {
      return SessionSearchPage(sessions: [], nextCursor: nil, unavailableFolders: [])
    }
    let hits = session.candidates.dropFirst(offset).prefix(limit)
    let next = offset + hits.count < session.candidates.count ? offset + hits.count : nil
    return SessionSearchPage(
      sessions: [result(of: session, hits: hits, queryTerms: queryTerms)],
      nextCursor: next.map(TranscriptSearchCursor.cursor(of:)), unavailableFolders: [])
  }

  /// The result of one session.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - hits: The candidates of the session that the page gives.
  ///   - queryTerms: The query terms.
  /// - Returns: The result.
  private static func result(
    of session: TranscriptSearchSession, hits: ArraySlice<TranscriptSearchCandidate>,
    queryTerms: Set<String>
  ) -> SessionSearchResult {
    SessionSearchResult(
      session: session.ulid, score: session.candidates.first?.score ?? .zero,
      hitCount: session.candidates.count, hits: hits.map { $0.hit(queryTerms: queryTerms) })
  }

  /// The path of a folder to compare two folders: the standard file path.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The path.
  private static func comparablePath(of folder: URL) -> String {
    folder.standardizedFileURL.path
  }
}

extension SessionSearchPage {
  /// This page with the folders that the process cannot read now as its unavailable folders,
  /// each one time, in order.
  ///
  /// - Parameters:
  ///   - folders: The folders of the sessions of the page.
  ///   - readable: The rule "this folder is readable now".
  /// - Returns: The page.
  fileprivate func withUnavailableFolders(
    of folders: [URL], readable: @Sendable (URL) -> Bool
  ) -> SessionSearchPage {
    var unavailable: [URL] = []
    for folder in folders where !readable(folder) && !unavailable.contains(folder) {
      unavailable.append(folder)
    }
    return SessionSearchPage(
      sessions: sessions, nextCursor: nextCursor, unavailableFolders: unavailable)
  }
}

extension TranscriptSearchItem {
  /// True for a chunk item.
  fileprivate var isChunk: Bool {
    chunkOrdinal != nil
  }

  /// The date of a chunk item, or `nil` for a session item or a chunk with no date.
  fileprivate var chunkDate: Date? {
    guard case .chunk(let chunk) = content else {
      return nil
    }
    return chunk.date
  }

  /// The ordinal of a chunk item, or `nil` for a session item.
  fileprivate var chunkOrdinal: Int? {
    guard case .chunk(let chunk) = content else {
      return nil
    }
    return chunk.ordinal
  }
}
