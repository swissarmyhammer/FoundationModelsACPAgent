import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool

/// The searcher of the transcripts of the sessions of an agent (D207), for the `search sessions`
/// operation of the `sessions` tool and the `searchSessions` field of the `sessions` endpoint.
///
/// The searcher holds the agent weakly, as ``AgentTranscriptExporter`` does. The endpoint of the
/// directory holds the searcher, and the agent holds the directory. When the agent is gone, each
/// search gives an empty page.
final class AgentTranscriptSearcher: SessionTranscriptSearcher, Sendable {
  /// The agent whose transcripts the searcher searches. Weak, to break the cycle agent →
  /// directory → endpoint → searcher → agent. A `weak let` is set one time, in the initializer,
  /// and the agent is an actor. Thus the class is `Sendable` with no unchecked conformance.
  private weak let agent: RoutedACPAgent?

  /// Makes the searcher of `agent`.
  ///
  /// - Parameter agent: The agent.
  init(agent: RoutedACPAgent) {
    self.agent = agent
  }

  /// One page of the sessions that match a request
  /// (``RoutedACPAgent/searchTranscripts(_:)``).
  ///
  /// - Parameter request: The request.
  /// - Returns: The page, or an empty page when the agent is gone.
  /// - Throws: The error of the session directory or of the search.
  func search(_ request: SessionSearchRequest) async throws -> SessionSearchPage {
    guard let agent else {
      return SessionSearchPage(sessions: [], nextCursor: nil, unavailableFolders: [])
    }
    return try await agent.searchTranscripts(request)
  }
}

extension RoutedACPAgent {
  /// One page of the sessions that match a request: the search of the transcript search index of
  /// the agent (``transcriptSearchIndex``) over the sessions that the session directory shows
  /// now, live and recorded, with their folder and their archive state.
  ///
  /// - Parameter request: The request.
  /// - Returns: The page.
  /// - Throws: The error of the session directory or of the search.
  func searchTranscripts(_ request: SessionSearchRequest) async throws -> SessionSearchPage {
    let summaries = try await sessionDirectory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    let visibleSessions = summaries.reduce(into: [SessionId: TranscriptSearchVisibleSession]()) {
      visible, summary in
      visible[SessionId(rawValue: summary.id.description)] = TranscriptSearchVisibleSession(
        folder: summary.workingDirectory, isArchived: summary.state == .archived)
    }
    return try await transcriptSearchIndex.search(request, visibleSessions: visibleSessions)
  }
}
