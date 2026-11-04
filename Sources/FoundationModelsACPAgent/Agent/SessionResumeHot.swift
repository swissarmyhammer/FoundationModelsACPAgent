import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The hot resume: a `session/resume` of a root session that is live in this process.
///
/// A new connection takes over the whole live tree, the root and the sessions nested in it, and
/// the work goes on. Nothing is torn down: the open prompts stay open, the running sub-agent runs
/// keep running, and the projectors and the Router sessions stay as they are. The resume builds
/// nothing new, so a failure can only come before the take, and a failed resume leaves the live
/// session and its owner as they were.
extension RoutedACPAgent {
  /// The entry of a root session that a hot resume can take over.
  ///
  /// - Parameter sessionId: The session of the resume.
  /// - Returns: The entry, or `nil` when the session is not in the table, is closed, or is a
  ///   nested session.
  func liveRoot(_ sessionId: SessionId) -> ActiveSession? {
    guard let entry = sessions[sessionId], !entry.isClosed, entry.parentSessionId == nil else {
      return nil
    }
    return entry
  }

  /// Resumes a live root session for a new connection.
  ///
  /// The order is: the check that the replay has a connection to go through, the take of the
  /// session (D120 c), the withdrawal of the open questions from the old connection, the replay of
  /// the tree, the current state, and the response. The current snapshots of the children, and
  /// the questions that wait for the user, follow the response (``scheduleHotSync(of:through:)``).
  ///
  /// - Parameters:
  ///   - params: The resume request.
  ///   - entry: The live entry of the root.
  ///   - replayCursor: Where the replay begins, or `nil` for no replay.
  ///   - caller: The connection of the request.
  /// - Returns: The response. It holds the commands and the options that the live session has.
  /// - Throws: An internal error when a replay is asked for and the caller has no connection to
  ///   notify through; the session is not taken then. Or the owner refusal of an `external`
  ///   connection (``RequestError/sessionHasOwner(id:)``).
  func resumeLiveSession(
    _ params: ResumeSessionRequest, entry: ActiveSession, replayCursor: ReplayCursor?,
    from caller: ConnectionId
  ) async throws -> ResumeSessionResponse {
    let sessionId = params.sessionId
    guard replayCursor == nil || connections.path(of: caller)?.connection != nil else {
      throw RequestError.internalError(detail: "the agent has no connection to notify through")
    }
    try takeSession(sessionId, for: caller)
    for id in treeSessionIds(of: sessionId) {
      await sessions[id]?.projector.relay?.withdrawOpenQuestions()
    }
    try await replayHistory(entry.history, from: replayCursor, sessionId: sessionId)
    await syncCurrentState(of: sessionId, replayed: replayCursor != nil)
    let response = ResumeSessionResponse(
      availableCommands: CommandRegistry.availableCommands(for: await entry.commands.commands),
      configOptions: entry.announcedConfigOptions)
    if let connection = connections.path(forSession: sessionId)?.connection {
      scheduleHotSync(of: sessionId, through: connection)
    }
    return response
  }

  /// The session and the sessions nested in it, the parent before the child.
  ///
  /// - Parameter sessionId: The root of the tree.
  /// - Returns: The ids of the tree.
  func treeSessionIds(of sessionId: SessionId) -> [SessionId] {
    [sessionId] + (sessions[sessionId]?.children ?? []).flatMap { treeSessionIds(of: $0) }
  }

  /// Schedules the work that follows the response of a hot resume: the current snapshot of each
  /// child, and then the open questions of the tree, asked again on the new owner. A question
  /// goes out after the snapshot of its child, so the client knows the child before the request
  /// names it.
  ///
  /// Call it synchronously in the handler of the request, so the work follows the response.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session.
  ///   - connection: The connection of the request.
  private func scheduleHotSync(of sessionId: SessionId, through connection: AgentSideConnection) {
    connection.afterRespondingInCurrentInstrumentationContext { [weak self] in
      await self?.finishHotSync(of: sessionId)
    }
  }

  /// The work of ``scheduleHotSync(of:through:)``.
  ///
  /// - Parameter sessionId: The resumed root session.
  private func finishHotSync(of sessionId: SessionId) async {
    await syncChildren(of: sessionId)
    for id in treeSessionIds(of: sessionId) {
      await sessions[id]?.projector.relay?.reaskWithdrawnQuestions()
    }
  }
}
