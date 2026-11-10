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
  /// the tree, the current state, and the response. The current snapshots of the children, the
  /// live updates that the tree made meanwhile, and the questions that wait for the user follow
  /// the response (``scheduleHotSync(of:through:releasing:)``).
  ///
  /// The tree runs on during the resume. The take holds each live update of the tree that the
  /// agent records from the take on (``SessionResumeHold``), so no live update comes before the
  /// announcement of its session, or before the response. The copy of the tree for the replay is
  /// made in the same step of the actor as the take. So an update recorded before the take is in
  /// the replay and goes to the old connection, and an update recorded after the take goes live
  /// to the new connection after the response (``recordAndRoute(_:of:)``). Each live update
  /// reaches the new connection one time.
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
    let hold = SessionResumeHold(rootSessionId: sessionId)
    try takeSession(sessionId, for: caller, holding: hold)
    // The same step of the actor as the take: no update is recorded between the two.
    let tree = replayCursor.map { _ in replayedTree(of: sessionId, history: entry.history) }
    for id in treeSessionIds(of: sessionId) {
      await sessions[id]?.projector.relay?.withdrawOpenQuestions()
    }
    let connection = connections.path(forSession: sessionId)?.connection
    if connection == nil {
      // No client sees the updates of the tree, so nothing waits for the response.
      await endHold(hold, of: sessionId)
    }
    if let tree, let replayCursor {
      try await replay(tree, from: replayCursor, sessionId: sessionId)
    }
    await syncCurrentState(of: sessionId, replayed: replayCursor != nil, through: connection)
    let response = ResumeSessionResponse(
      availableCommands: CommandRegistry.availableCommands(for: await entry.commands.commands),
      configOptions: entry.announcedConfigOptions)
    if let connection {
      scheduleHotSync(of: sessionId, through: connection, releasing: hold)
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
  /// child, then the live updates that the hold kept, and then the open questions of the tree,
  /// asked again on the new owner. The kept updates of a child go out after its snapshot, so the
  /// client knows the child before them. A question goes out after the snapshot of its child, so
  /// the client knows the child before the request names it.
  ///
  /// Call it synchronously in the handler of the request, so the work follows the response. When
  /// the connection closes before the response, the work does not run, and the hold ends.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session.
  ///   - connection: The connection of the request.
  ///   - hold: The hold of the take of the resume.
  private func scheduleHotSync(
    of sessionId: SessionId, through connection: AgentSideConnection,
    releasing hold: SessionResumeHold
  ) {
    connection.afterRespondingInCurrentInstrumentationContext(
      { [weak self] in
        await self?.finishHotSync(of: sessionId, releasing: hold)
      },
      onDiscard: { [connections] in
        hold.discard()
        connections.removeHold(hold, of: sessionId)
      })
  }

  /// The work of ``scheduleHotSync(of:through:releasing:)``.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session.
  ///   - hold: The hold of the take of the resume.
  private func finishHotSync(of sessionId: SessionId, releasing hold: SessionResumeHold) async {
    await syncChildren(of: sessionId)
    await endHold(hold, of: sessionId)
    for id in treeSessionIds(of: sessionId) {
      await sessions[id]?.projector.relay?.reaskWithdrawnQuestions()
    }
  }

  /// Sends the live updates that a hold kept, opens it, and ends its record in the table.
  ///
  /// - Parameters:
  ///   - hold: The hold of the take of the resume.
  ///   - sessionId: The resumed root session.
  private func endHold(_ hold: SessionResumeHold, of sessionId: SessionId) async {
    await hold.release()
    connections.removeHold(hold, of: sessionId)
  }
}
