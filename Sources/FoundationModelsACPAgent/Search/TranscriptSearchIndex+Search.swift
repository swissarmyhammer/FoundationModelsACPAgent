import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import FoundationModelsRouter

/// One session of a search, in the type that ``TranscriptSearchSessionCollector`` gives.
private typealias TranscriptSearchSession = TranscriptSearchSessionCollector.CollectedSession

extension TranscriptSearchIndex {
  /// The most hits of one session in a page, with no `session:` request (D207 (c)).
  static let hitsOfASession = 3

  /// One page of the sessions that match a request (D207 (c), (e)).
  ///
  /// A request with a ranking text asks the registry for one match for each item of the catalog
  /// (``matches(for:)``). A request with only tokens does not call the registry: it walks the
  /// chunk items newest first (``TranscriptSearchDateIndex``), and it stops when it has the
  /// sessions of its page. The filters of ``TranscriptSearchFilter`` then remove the items that
  /// do not apply: first the cheap filters (the sessions, the archive, the kinds, the dates),
  /// then the phrases and the exclusions, only for an item that can change the page. The order
  /// of a session is the place of its first item, and its score is the score of that item. The
  /// sessions of the preferred folder come first (D199 (d)). Each session gives at most
  /// ``hitsOfASession`` hits, or each hit for a `session:` request. Only the hits of the page get
  /// a snippet. A folder of a session of the page that the process cannot read goes into the
  /// unavailable folders.
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
    let rankingText = request.query.rankingText
    let limit = max(1, request.limit)
    let isSessionRequest = request.session != nil
    let keptHits = isSessionRequest ? Int.max : Self.hitsOfASession
    var collector = TranscriptSearchSessionCollector(
      filter: filter,
      wanted: isSessionRequest ? 1 : Self.wantedSessions(offset: offset, limit: limit),
      keptHits: keptHits, countsHits: !rankingText.isEmpty, preferredFolder: request.preferredFolder
    )
    let sessions = try await collectSessions(of: rankingText, filter: filter, into: &collector)
    let withHits = { (session: TranscriptSearchSession) in
      self.withHits(session, rankingText: rankingText, filter: filter, keptHits: keptHits)
    }
    let queryTerms = Set(Tokenizer.tokenize(text: rankingText))
    guard !isSessionRequest else {
      return Self.hitPage(
        of: sessions.first.map(withHits), offset: offset, limit: limit, queryTerms: queryTerms
      ).withUnavailableFolders(of: sessions.prefix(1).map(\.folder), readable: readableFolder)
    }
    let page = sessions.dropFirst(offset).prefix(limit)
    let next = offset + page.count < sessions.count ? offset + page.count : nil
    return SessionSearchPage(
      sessions: page.map(withHits).map {
        Self.result(of: $0, hits: $0.candidates.prefix(Self.hitsOfASession), queryTerms: queryTerms)
      },
      nextCursor: next.map(TranscriptSearchCursor.cursor(of:)), unavailableFolders: []
    ).withUnavailableFolders(of: page.map(\.folder), readable: readableFolder)
  }

  /// The number of sessions that a page needs in each group of the order: the sessions before
  /// the page, the sessions of the page, and one more session to tell that a next page exists.
  ///
  /// - Parameters:
  ///   - offset: The offset of the first session of the page.
  ///   - limit: The most sessions of the page. At least one.
  /// - Returns: The number of sessions, at most `Int.max`.
  private static func wantedSessions(offset: Int, limit: Int) -> Int {
    let (pageEnd, pageOverflow) = offset.addingReportingOverflow(limit)
    let (wanted, wantedOverflow) = pageEnd.addingReportingOverflow(1)
    return pageOverflow || wantedOverflow ? .max : wanted
  }

  /// The sessions of a search that pass the filters, in the order of the search, with the
  /// sessions of the preferred folder first. A session that the page does not need can be
  /// missing.
  ///
  /// - Parameters:
  ///   - rankingText: The ranking text of the query.
  ///   - filter: The filters.
  ///   - collector: The collector of the sessions.
  /// - Returns: The sessions: of the matches of the registry, with their hits, or of the chunk
  ///   items newest first for an empty ranking text, with only their first hit
  ///   (``listedHits(of:filter:keptHits:)`` gives the others).
  /// - Throws: An error of the searcher.
  private func collectSessions(
    of rankingText: String, filter: TranscriptSearchFilter,
    into collector: inout TranscriptSearchSessionCollector
  ) async throws -> [TranscriptSearchSession] {
    guard rankingText.isEmpty else {
      for match in try await matches(for: rankingText) {
        guard let slot = collector.slot(of: match.item.sessionId), collector.wants(slot: slot),
          filter.admitsFacts(of: match.item), filter.admitsText(of: match.item)
        else {
          continue
        }
        collector.collect(TranscriptSearchCandidate(match: match), at: slot)
      }
      return collector.sessions
    }
    await load()
    for entry in dateIndex.entries {
      guard let slot = collector.slot(of: entry.sessionId), collector.wants(slot: slot),
        filter.admits(kind: entry.kind, date: entry.date),
        let item = chunkItem(of: entry), filter.admitsText(of: item)
      else {
        continue
      }
      collector.collect(TranscriptSearchCandidate(listed: item), at: slot)
      if collector.isComplete {
        break
      }
    }
    return collector.sessions
  }

  /// The chunk item of an entry of the date index.
  ///
  /// The index changes its sessions and its date index in the same step, so an entry always
  /// names a held chunk item. A miss is a programmer error, not a race.
  ///
  /// - Parameter entry: The entry.
  /// - Returns: The chunk item, or `nil` when the index does not hold it.
  private func chunkItem(of entry: TranscriptSearchDateIndex.Entry) -> TranscriptSearchItem? {
    guard let chunkItems = sessions[entry.sessionId]?.chunkItems,
      chunkItems.indices.contains(entry.position)
    else {
      assertionFailure("the date index names a chunk that the index does not hold")
      ACPAgentTelemetry.logger(.transcriptSearch).error(
        "The transcript search date index names a chunk that the index does not hold.",
        metadata: ACPAgentTelemetry.sessionMetadata(entry.sessionId))
      return nil
    }
    return chunkItems[entry.position]
  }

  /// A session of a page with its hits. A session of the matches of the registry has its hits
  /// already. A session of a query with only tokens gets them from its chunk items, only for
  /// the sessions of the page.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - rankingText: The ranking text of the query.
  ///   - filter: The filters.
  ///   - keptHits: The most hits to keep.
  /// - Returns: The session with its hit count and its first hits.
  private func withHits(
    _ session: TranscriptSearchSession, rankingText: String, filter: TranscriptSearchFilter,
    keptHits: Int
  ) -> TranscriptSearchSession {
    guard rankingText.isEmpty else {
      return session
    }
    return listedHits(of: session, filter: filter, keptHits: keptHits)
  }

  /// A session of a query with only tokens with all of its hits: each of its chunk items that
  /// passes each filter, newest first.
  ///
  /// - Parameters:
  ///   - session: The session, with its first hit.
  ///   - filter: The filters.
  ///   - keptHits: The most hits to keep.
  /// - Returns: The session with its hit count and its first hits.
  private func listedHits(
    of session: TranscriptSearchSession, filter: TranscriptSearchFilter, keptHits: Int
  ) -> TranscriptSearchSession {
    let chunkItems = sessions[session.id]?.chunkItems ?? []
    let hits = TranscriptSearchDateIndex.sorted(
      TranscriptSearchDateIndex.entries(of: session.id, chunkItems: chunkItems).filter {
        filter.admits(kind: $0.kind, date: $0.date)
          && filter.admitsText(of: chunkItems[$0.position])
      }
    ).map { TranscriptSearchCandidate(listed: chunkItems[$0.position]) }
    return session.replacingCandidates(with: hits, keeping: keptHits)
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
    let next = offset + hits.count < session.hitCount ? offset + hits.count : nil
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
      session: session.ulid, score: session.score, hitCount: session.hitCount,
      hits: hits.map { $0.hit(queryTerms: queryTerms) })
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
