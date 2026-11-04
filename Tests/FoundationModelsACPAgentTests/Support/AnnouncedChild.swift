import FoundationModelsACP

/// Finds the child that a `subagent_update` announcement names on the wire.
enum AnnouncedChild {
  /// The id of the first session that an announcement on `parent` names.
  ///
  /// - Parameters:
  ///   - updates: The notifications.
  ///   - parent: The session that carries the announcement.
  /// - Returns: The announced child, or `nil`.
  static func first(in updates: [UpdateSessionNotification], on parent: SessionId) -> SessionId? {
    for notification in updates where notification.sessionId == parent {
      if case .subagentUpdate(let update) = notification.update { return update.sessionId }
    }
    return nil
  }
}
