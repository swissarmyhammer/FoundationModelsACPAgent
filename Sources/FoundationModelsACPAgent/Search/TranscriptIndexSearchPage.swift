import Foundation
import FoundationModelsACP
import FoundationModelsMultitool

/// One session that matches a search of a ``TranscriptSearchIndex`` by ACP session id, with its
/// hits (^bm6spcd). The fields are the fields of the `SessionSearchResult` of Multitool, but the
/// session is an ACP ``SessionId``, which can be any string.
public struct TranscriptIndexSearchResult: Sendable, Equatable {
  /// The id of the session.
  public var session: SessionId

  /// The score in `[0, 1]` of the first match of the session.
  public var score: Double

  /// The number of hits of the session. It can be larger than the number of ``hits``.
  public var hitCount: Int

  /// The hits of the session, the best hit first.
  public var hits: [SessionSearchHit]

  /// Makes a result.
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - score: The score in `[0, 1]` of the first match of the session.
  ///   - hitCount: The number of hits of the session.
  ///   - hits: The hits of the session, the best hit first.
  public init(session: SessionId, score: Double, hitCount: Int, hits: [SessionSearchHit]) {
    self.session = session
    self.score = score
    self.hitCount = hitCount
    self.hits = hits
  }
}

/// One page of a search of a ``TranscriptSearchIndex`` by ACP session id (^bm6spcd). The fields
/// are the fields of the `SessionSearchPage` of Multitool, with ``TranscriptIndexSearchResult``
/// sessions.
public struct TranscriptIndexSearchPage: Sendable, Equatable {
  /// The sessions that match, in the order of the search: first the sessions of the preferred
  /// folder, then the others.
  public var sessions: [TranscriptIndexSearchResult]

  /// The cursor of the next page, or `nil` when this page is the last one.
  public var nextCursor: String?

  /// The folders of the sessions of the page that the process cannot read now.
  public var unavailableFolders: [URL]

  /// Makes a page.
  ///
  /// - Parameters:
  ///   - sessions: The sessions that match.
  ///   - nextCursor: The cursor of the next page, or `nil`.
  ///   - unavailableFolders: The folders that the process cannot read now.
  public init(
    sessions: [TranscriptIndexSearchResult], nextCursor: String?, unavailableFolders: [URL]
  ) {
    self.sessions = sessions
    self.nextCursor = nextCursor
    self.unavailableFolders = unavailableFolders
  }
}
