import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

/// The launcher that the session directory of the agent uses (ROUTER-8,
/// ACPA-9). The agent gives it to `RouterSessionDirectory.use(launcher:)`
/// in its initializer.
///
/// - ``restoreSession(id:)`` makes a recorded root session live with no
///   client (ACPA-9 Step 2). It uses the same composition and restore as a
///   `session/resume` of a session that is not live
///   (``RoutedACPAgent/restoreColdRoot(_:sessionId:context:workingDirectory:additionalRoots:clientMCPServers:userPresence:)``).
///   The session goes into the session table of the agent with no owner. A
///   later `session/resume` of a client takes it with the hot resume.
/// - ``launchRootSession(for:)`` comes in ACPA-9 Step 7. Until then it
///   throws `SessionDirectoryError.noLauncher`, as a directory with no
///   launcher does.
///
/// The launcher holds the agent weakly: the agent holds the directory, and
/// the directory holds the launcher. When the agent is gone, each call
/// throws `noLauncher`.
final class AgentSessionLauncher: SessionLauncher, @unchecked Sendable {
  /// The agent whose sessions the launcher makes. Weak, to break the cycle
  /// agent → directory → launcher → agent. It is set one time, in the
  /// initializer, and never changes.
  private weak var agent: RoutedACPAgent?

  /// Makes the launcher of `agent`.
  ///
  /// - Parameter agent: The agent.
  init(agent: RoutedACPAgent) {
    self.agent = agent
  }

  /// Not available before ACPA-9 Step 7.
  ///
  /// - Parameter request: The start request.
  /// - Returns: Never.
  /// - Throws: `SessionDirectoryError.noLauncher`, always.
  func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
    throw SessionDirectoryError.noLauncher
  }

  /// Makes the recorded root session `id` live with no client, or gives
  /// the live session when it is live already.
  ///
  /// - Parameter id: The id of the recorded root session.
  /// - Returns: The live session.
  /// - Throws: `SessionDirectoryError.noLauncher` when the agent is gone,
  ///   `SessionDirectoryError.unknownSession(_:)` when the directory has no
  ///   root session with this id, or the error of the restore.
  func restoreSession(id: ULID) async throws -> any RoutedSession {
    guard let agent else {
      throw SessionDirectoryError.noLauncher
    }
    return try await agent.restoreSessionForDirectory(id: id)
  }
}

extension RoutedACPAgent {
  /// The work of ``AgentSessionLauncher/restoreSession(id:)``.
  ///
  /// The restore uses the recorded working directory of the session, no
  /// additional root and no MCP server of a client. The user presence is
  /// `interactive`, as for a session that a client of the user opens: a
  /// client of the user can take the session later.
  ///
  /// - Parameter id: The id of the recorded root session.
  /// - Returns: The live session.
  /// - Throws: `SessionDirectoryError.unknownSession(_:)` when the
  ///   directory has no root session with this id, or the error of the
  ///   restore.
  func restoreSessionForDirectory(id: ULID) async throws -> any RoutedSession {
    let sessionId = SessionId(rawValue: id.description)
    if let live = liveRoot(sessionId) {
      return live.session
    }
    guard let summary = try await sessionDirectory.summary(of: id), summary.parentID == nil
    else {
      throw SessionDirectoryError.unknownSession(id)
    }
    let workingDirectory = summary.workingDirectory
    let context = try await loadSessionContext(workingDirectory: workingDirectory)
    let cold = try await restoreColdRoot(
      id, sessionId: sessionId, context: context, workingDirectory: workingDirectory,
      additionalRoots: [], clientMCPServers: [], userPresence: .interactive)
    // No client replays the session, so no restored run waits for a re-drive.
    await holdRestoredWork(of: sessionId)
    await syncCurrentState(of: sessionId)
    await releaseRestoredWork(of: sessionId)
    return cold.restored.session
  }
}
