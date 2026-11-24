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
  /// A session id can be any string (^bm6spcd): the client index of an app holds the sessions
  /// of other ACP agents, whose session ids are UUIDs or other strings.
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
    _ request: TranscriptIndexSearchRequest,
    visibleSessions: [SessionId: TranscriptSearchVisibleSession]
  ) async throws -> TranscriptIndexSearchPage {
    let matches = try await rankedMatches(of: request)
    return try search(request, visibleSessions: visibleSessions, matches: matches)
  }

  /// The matches of the registry for the ranking text of a request, after the check of its
  /// cursor. A request with no ranking text does not call the registry and has no match.
  ///
  /// - Parameter request: The request.
  /// - Returns: The matches, the highest fused score first.
  /// - Throws: ``TranscriptSearchError/invalidCursor`` for a cursor that a search did not give,
  ///   or an error of the searcher.
  private func rankedMatches(of request: TranscriptIndexSearchRequest) async throws
    -> [Match<TranscriptSearchItem>]
  {
    _ = try TranscriptSearchCursor.offset(of: request.cursor)
    let rankingText = request.query.rankingText
    guard !rankingText.isEmpty else {
      await load()
      return []
    }
    return try await matches(for: rankingText)
  }

  /// One page of the sessions that match a request, with the matches of the registry for its
  /// ranking text (``rankedMatches(of:)``).
  ///
  /// - Parameters:
  ///   - request: The request.
  ///   - visibleSessions: The sessions that the session directory shows now.
  ///   - matches: The matches of the registry, or none for a request with no ranking text.
  /// - Returns: The page.
  /// - Throws: ``TranscriptSearchError/invalidCursor`` for a cursor that a search did not give.
  private func search(
    _ request: TranscriptIndexSearchRequest,
    visibleSessions: [SessionId: TranscriptSearchVisibleSession],
    matches: [Match<TranscriptSearchItem>]
  ) throws -> TranscriptIndexSearchPage {
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
    let sessions = collectSessions(
      of: rankingText, matches: matches, filter: filter, into: &collector)
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
    return TranscriptIndexSearchPage(
      sessions: page.map(withHits).map {
        Self.result(of: $0, hits: $0.candidates.prefix(Self.hitsOfASession), queryTerms: queryTerms)
      },
      nextCursor: next.map(TranscriptSearchCursor.cursor(of:)), unavailableFolders: []
    ).withUnavailableFolders(of: page.map(\.folder), readable: readableFolder)
  }

  /// One page of the sessions that match a request of the search of Multitool, whose sessions
  /// are ULIDs (D207 (c), (e)).
  ///
  /// The search is the search by session id (a ``TranscriptIndexSearchRequest``) over the
  /// visible sessions whose ids are ULIDs. A session with another id cannot be a
  /// `SessionSearchResult`, so it does not pass, and the order, the filters and the cursor of
  /// the other sessions do not change. The session directory gives the id of each session as the
  /// text of its ULID, which is the session id that ``TranscriptIndexSearchRequest/init(_:)``
  /// makes of a ULID of the request.
  ///
  /// - Parameters:
  ///   - request: The request of Multitool.
  ///   - visibleSessions: The sessions that the session directory shows now, with their folder
  ///     and their archive state. An item of another session does not pass.
  /// The first page of a request with no session filter (no ``SessionSearchRequest/sessions``
  /// and no ``SessionSearchRequest/session``) also gives the sessions of other agents whose
  /// external items match (``externalResults(of:filter:queryTerms:)``), in
  /// ``FoundationModelsMultitool/SessionSearchPage/externalSessions``. A later page and a
  /// request with a session filter give none, and a query with no ranking text gives none,
  /// because only the registry matches the index fields.
  ///
  /// - Returns: The page, with the ULID of each session.
  /// - Throws: ``TranscriptSearchError/invalidCursor`` for a cursor that a search did not give,
  ///   or an error of the searcher.
  public func search(
    _ request: SessionSearchRequest, visibleSessions: [SessionId: TranscriptSearchVisibleSession]
  ) async throws -> SessionSearchPage {
    let indexRequest = TranscriptIndexSearchRequest(request)
    let ulidSessions = visibleSessions.filter { ULID(ulidString: $0.key.rawValue) != nil }
    let matches = try await rankedMatches(of: indexRequest)
    let page = try search(indexRequest, visibleSessions: ulidSessions, matches: matches)
    let givesExternal = request.cursor == nil && request.sessions == nil && request.session == nil
    let externalSessions =
      givesExternal
      ? Self.externalResults(
        of: matches, filter: TranscriptSearchFilter(request: indexRequest, visibleSessions: [:]),
        queryTerms: Set(Tokenizer.tokenize(text: request.query.rankingText))) : []
    return SessionSearchPage(
      sessions: page.sessions.compactMap(Self.multitoolResult(of:)), nextCursor: page.nextCursor,
      unavailableFolders: page.unavailableFolders, externalSessions: externalSessions)
  }

  /// The result of Multitool of a session whose id is a ULID.
  ///
  /// The search of Multitool searches only the sessions whose ids are ULIDs, so each of its
  /// results has a ULID. A miss is a programmer error.
  ///
  /// - Parameter result: The result by session id.
  /// - Returns: The result with the ULID of the session, or `nil` when the id is not a ULID.
  private static func multitoolResult(of result: TranscriptIndexSearchResult)
    -> SessionSearchResult?
  {
    guard let ulid = ULID(ulidString: result.session.rawValue) else {
      assertionFailure("the search of Multitool gave a session whose id is not a ULID")
      ACPAgentTelemetry.logger(.transcriptSearch).error(
        "The transcript search of Multitool gave a session whose id is not a ULID.",
        metadata: ACPAgentTelemetry.sessionMetadata(result.session))
      return nil
    }
    return SessionSearchResult(
      session: ulid, score: result.score, hitCount: result.hitCount, hits: result.hits)
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
  ///   - matches: The matches of the registry for the ranking text.
  ///   - filter: The filters.
  ///   - collector: The collector of the sessions.
  /// - Returns: The sessions: of the matches of the registry, with their hits, or of the chunk
  ///   items newest first for an empty ranking text, with only their first hit
  ///   (``listedHits(of:filter:keptHits:)`` gives the others).
  private func collectSessions(
    of rankingText: String, matches: [Match<TranscriptSearchItem>],
    filter: TranscriptSearchFilter, into collector: inout TranscriptSearchSessionCollector
  ) -> [TranscriptSearchSession] {
    guard rankingText.isEmpty else {
      for match in matches {
        guard !match.item.isExternal, let slot = collector.slot(of: match.item.sessionId),
          collector.wants(slot: slot), filter.admitsFacts(of: match.item),
          filter.admitsText(of: match.item)
        else {
          continue
        }
        collector.collect(TranscriptSearchCandidate(match: match), at: slot)
      }
      return collector.sessions
    }
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
  ) -> TranscriptIndexSearchPage {
    guard let session else {
      return TranscriptIndexSearchPage(sessions: [], nextCursor: nil, unavailableFolders: [])
    }
    let hits = session.candidates.dropFirst(offset).prefix(limit)
    let next = offset + hits.count < session.hitCount ? offset + hits.count : nil
    return TranscriptIndexSearchPage(
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
  ) -> TranscriptIndexSearchResult {
    TranscriptIndexSearchResult(
      session: session.id, score: session.score, hitCount: session.hitCount,
      hits: hits.map { $0.hit(queryTerms: queryTerms) })
  }
}

extension TranscriptIndexSearchPage {
  /// This page with the folders that the process cannot read now as its unavailable folders,
  /// each one time, in order.
  ///
  /// - Parameters:
  ///   - folders: The folders of the sessions of the page.
  ///   - readable: The rule "this folder is readable now".
  /// - Returns: The page.
  fileprivate func withUnavailableFolders(
    of folders: [URL], readable: @Sendable (URL) -> Bool
  ) -> TranscriptIndexSearchPage {
    var unavailable: [URL] = []
    for folder in folders where !readable(folder) && !unavailable.contains(folder) {
      unavailable.append(folder)
    }
    return TranscriptIndexSearchPage(
      sessions: sessions, nextCursor: nextCursor, unavailableFolders: unavailable)
  }
}
