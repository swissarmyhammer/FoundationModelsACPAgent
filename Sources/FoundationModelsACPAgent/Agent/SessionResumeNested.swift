import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter
import Logging

/// The restore of the nested sub-agent sessions of a resumed root session.
///
/// A sub-agent recording is a separate root in the recording folder. The Router restore of the
/// root does not bring it back. Only FoundationModelsAgents builds the tools and the instructions
/// of a child from the current definition and the current catalog, so the restore of the children
/// goes through its runner (``AgentRunner/restoreInterrupted(of:caller:directory:prompts:)``).
extension RoutedACPAgent {
  /// The keys of the orphan `start agent` calls of the root. The Router restore of the root takes
  /// them as `claimingRuns`: the restore posts no `lost` end for these calls, and the restored
  /// children complete them. Call it before the restore of the root.
  ///
  /// - Parameters:
  ///   - rootId: The recorded root session.
  ///   - composition: The composition of the resumed root.
  /// - Returns: The keys. It is empty for a replay-only composition.
  func claimedRuns(of rootId: ULID, in composition: SessionComposition) async -> Set<RunKey> {
    guard let agents = composition.surface.agents else {
      return []
    }
    return await agents.runner.claims(of: rootId, directory: sessionDirectory)
  }

  /// Restores the interrupted nested sessions of a resumed root, and registers each one as a
  /// session nested in its caller, the caller before the child. The restored sessions are idle:
  /// the runner holds the start of each run, and a later task starts them.
  ///
  /// The root restores first, with the hook key of its project, so each child finds its root open
  /// and takes the same key. Each restored session records that key for the `snapshots` tool
  /// before its first submission (``SnapshotSessionKeys``).
  ///
  /// A child that does not restore leaves the resume of the root as it is. The report keeps the
  /// failure on the entry of the root for the announcement of the child.
  ///
  /// - Parameters:
  ///   - sessionId: The ACP session id of the resumed root.
  ///   - composition: The composition of the resumed root.
  ///   - hookLineage: The hook lineage of the resumed root.
  func restoreNestedSessions(
    of sessionId: SessionId, composition: SessionComposition, hookLineage: HookLineage
  ) async {
    guard let agents = composition.surface.agents, let rootId = ULID(ulidString: sessionId.rawValue)
    else {
      return
    }
    let report = await agents.runner.restoreInterrupted(
      of: rootId, caller: nil, directory: sessionDirectory)
    for run in report.restored {
      await registerRestoredRun(run, hookSessionKey: hookLineage.sessionKey)
    }
    logNestedRestore(report, of: sessionId)
    sessions[sessionId]?.nestedRestore = report
  }

  /// Registers the restored session of one run as a session nested in its caller.
  ///
  /// - Parameters:
  ///   - run: The restored run, not started.
  ///   - hookSessionKey: The hook key of the project of the root.
  private func registerRestoredRun(_ run: AgentRun, hookSessionKey: String) async {
    let sessionId = SessionId(rawValue: run.id.description)
    guard let caller = run.caller, let session = sessionDirectory.session(id: run.id) else {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "A restored run has no live session or no caller. The run has no session of its own.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
      return
    }
    SnapshotSessionKeys.shared.record(hookSessionKey, for: sessionId)
    do {
      try await registerNestedSession(session, parent: SessionId(rawValue: caller.description))
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The session of a restored run did not register. The run has no session of its own.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
    }
  }

  /// Writes one record for each child that did not restore, and for each session whose children
  /// could not be read. The records carry the ids and no text of the error, because an error text
  /// can hold content.
  ///
  /// - Parameters:
  ///   - report: The report of the restore.
  ///   - sessionId: The ACP session id of the resumed root.
  private func logNestedRestore(_ report: RestoreReport, of sessionId: SessionId) {
    for failed in report.failed {
      ACPAgentTelemetry.logger(.sessionResume).notice(
        "A recorded child did not restore. The root session resumes without it.",
        metadata: ACPAgentTelemetry.sessionMetadata(
          SessionId(rawValue: failed.child.sessionID.description)))
    }
    for unreadable in report.unreadable.keys {
      ACPAgentTelemetry.logger(.sessionResume).warning(
        "The children of a session could not be read. The restore went on without them.",
        metadata: ACPAgentTelemetry.sessionMetadata(SessionId(rawValue: unreadable.description)))
    }
  }
}
