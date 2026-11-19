import Foundation
import FoundationModelsACP
import FoundationModelsRouter

// The restore of a fork (D205).
//
// The session directory of the Router makes a fork as a live session that runs the tools of its
// source, on the surface of the source. `session/fork` makes it so, and so does the `fork session`
// operation of the `sessions` tool. The agent serves a fork as each other root session: with a
// surface of its own, its own MCP servers and its own directories. Thus the agent restores the
// fork from its recording (`restoreColdRoot`), and these steps of the restore are for a fork.

extension RoutedACPAgent {
  /// Stops the live session of the session directory with an id that the table does not hold.
  ///
  /// The session directory holds a fork that it made until the fork stops. Two live sessions with
  /// one id would share one folder, so the restore of the fork stops the live one first. The
  /// suspend writes no ended marker, so the restore finds the session, as for a model slot
  /// switch. A session that the table holds is not touched here: the caller tears it down.
  ///
  /// - Parameters:
  ///   - id: The recorded id of the session.
  ///   - sessionId: The wire id of the session.
  func releaseDirectorySession(_ id: ULID, sessionId: SessionId) async {
    guard sessions[sessionId] == nil, let live = sessionDirectory.session(id: id) else {
      return
    }
    live.suspend()
    await live.close()
  }

  /// Records the agent of the source of a fork as the agent of the fork, when the fork has no
  /// agent record (``SessionAgentStore``). A fork has the agent of its source, and the
  /// composition of the restore reads the record. A session that is no fork records nothing.
  /// A failed write goes to the log: the fork then gets the agent of a new session.
  ///
  /// - Parameters:
  ///   - id: The recorded id of the session.
  ///   - sessionId: The wire id of the session.
  ///   - transcriptRoot: The recording root of the session.
  func inheritForkAgent(of id: ULID, sessionId: SessionId, in transcriptRoot: URL) async {
    guard SessionAgentStore.choice(of: sessionId, in: transcriptRoot) == nil,
      let source = await forkSource(of: id),
      let choice = SessionAgentStore.choice(
        of: SessionId(rawValue: source.description), in: transcriptRoot)
    else {
      return
    }
    do {
      try SessionAgentStore.record(choice, for: sessionId, in: transcriptRoot)
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).warning(
        "The agent of the source of a fork was not recorded for the fork. The fork gets the agent of a new session.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
  }

  /// The history of a fork that has no history file: the part of the retained history of its
  /// source that the fork copied. `session/fork` writes the file of the fork when it makes the
  /// fork. A fork that the `fork session` operation made has no file, so its first restore
  /// copies the part from the source here, and the client shows the copied turns.
  ///
  /// The agent knows no cut of such a fork. The tool calls of the transcript of the fork name
  /// the tool calls that it keeps, so the part ends before the call that forked
  /// (``SessionMergeEngine/forkEnd(keepingToolCalls:)``). The source history is the one in the
  /// table, else the one in the file of the source: a fork records in the folder of its source.
  ///
  /// - Parameter session: The restored session.
  /// - Returns: The copied history, or `nil` for a session that is no fork, a fork with a history
  ///   file, and a fork whose source has no history.
  func unrecordedForkHistory(of session: any RoutedSession) async -> SessionMergeEngine? {
    guard let sourceId = session.parentId,
      !SessionHistoryFile.exists(in: session.recordingDirectory)
    else {
      return nil
    }
    let source = SessionId(rawValue: sourceId.description)
    let sourceHistory =
      sessions[source]?.history
      ?? retainedHistory(
        kept: nil, directory: session.recordingDirectory.deletingLastPathComponent(),
        sessionId: source)
    guard !sourceHistory.entries.isEmpty else {
      return nil
    }
    let kept = await session.transcript.toolCallIds
    return sourceHistory.copiedHistory(endingAt: sourceHistory.forkEnd(keepingToolCalls: kept))
  }
}
