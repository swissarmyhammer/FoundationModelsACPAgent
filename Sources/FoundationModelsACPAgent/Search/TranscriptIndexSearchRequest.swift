import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter

/// One search of a ``TranscriptSearchIndex`` by ACP session id (^bm6spcd).
///
/// The fields are the fields of the `SessionSearchRequest` of Multitool, but the sessions are
/// ACP ``SessionId`` values, not ULIDs. A session id can be any string. The client index of an
/// app holds the sessions of other ACP agents, whose session ids are UUIDs or other strings, and
/// it uses this request. The server search of Multitool gives a `SessionSearchRequest`, which
/// ``init(_:)`` changes into this request.
public struct TranscriptIndexSearchRequest: Sendable, Equatable {
  /// The parsed query.
  public var query: SessionSearchQuery

  /// The sessions that the directory tokens of the query keep, or `nil` for each visible session.
  public var sessions: Set<SessionId>?

  /// True to include the archived sessions.
  public var includeArchived: Bool

  /// The folder whose sessions come first in the page, or `nil`.
  public var preferredFolder: URL?

  /// The one session whose hits the search gives, for Find Next Hit, or `nil` to search each
  /// session of ``sessions``.
  public var session: SessionId?

  /// The most sessions of one page. With ``session``, the most hits.
  public var limit: Int

  /// The cursor of the page, as the last page gave it, or `nil` for the first page.
  public var cursor: String?

  /// Makes a request.
  ///
  /// - Parameters:
  ///   - query: The parsed query.
  ///   - sessions: The sessions that the directory tokens keep, or `nil` for each visible
  ///     session.
  ///   - includeArchived: True to include the archived sessions.
  ///   - preferredFolder: The folder whose sessions come first, or `nil`.
  ///   - session: The one session whose hits the search gives, or `nil`.
  ///   - limit: The most sessions of the page.
  ///   - cursor: The cursor of the page, or `nil` for the first page.
  public init(
    query: SessionSearchQuery, sessions: Set<SessionId>?, includeArchived: Bool,
    preferredFolder: URL?, session: SessionId?, limit: Int, cursor: String?
  ) {
    self.query = query
    self.sessions = sessions
    self.includeArchived = includeArchived
    self.preferredFolder = preferredFolder
    self.session = session
    self.limit = limit
    self.cursor = cursor
  }

  /// Makes the request of a search of Multitool: each ULID becomes the session id of its text.
  ///
  /// - Parameter request: The request of Multitool.
  public init(_ request: SessionSearchRequest) {
    self.init(
      query: request.query, sessions: request.sessions.map { Set($0.map(Self.sessionId(of:))) },
      includeArchived: request.includeArchived, preferredFolder: request.preferredFolder,
      session: request.session.map(Self.sessionId(of:)), limit: request.limit,
      cursor: request.cursor)
  }

  /// The ACP session id of a ULID: its text.
  ///
  /// - Parameter ulid: The ULID.
  /// - Returns: The session id.
  private static func sessionId(of ulid: ULID) -> SessionId {
    SessionId(rawValue: ulid.description)
  }
}
