import FoundationModelsACP

// The turn ends of the sessions of the server, for a host (D208 Q74, Keep Updated).
//
// A host that keeps a share of a session updated must learn the end of each turn of the
// session. The change stream of the transcript search index is not that signal: the reconcile
// at launch and a fork also give a change, a turn whose chunks did not change gives none, and a
// change comes only after the embed. Thus the agent gives one event at the end of each turn.
// The host does the update; the agent does not.

extension RoutedACPAgent {
  /// Makes a new stream of the turn ends of the sessions of this server. Each call gives a new
  /// stream of its own: the id of the session at the end of each prompt and at the end of each
  /// turn that a message from another session started, after the agent wrote the retained
  /// history of the turn. The stream ends when the agent goes away.
  ///
  /// The agent never waits for a subscriber. The stream holds the newest
  /// ``SubscriberFeed/defaultBufferLimit`` turn ends that its subscriber did not read, and it
  /// drops the oldest ones.
  ///
  /// - Returns: The stream of the turn ends after this call.
  public nonisolated func turnEnds() -> AsyncStream<SessionId> {
    turnEndFeed.subscribe()
  }

  /// Ends one turn of a session: it writes the retained history of the session
  /// (``writeHistory(of:)``), and then gives the turn end to each subscriber of ``turnEnds()``.
  ///
  /// - Parameter sessionId: The session whose turn ended.
  func turnEnded(_ sessionId: SessionId) {
    writeHistory(of: sessionId)
    turnEndFeed.publish([sessionId])
  }
}
