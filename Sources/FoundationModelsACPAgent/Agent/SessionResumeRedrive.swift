import FoundationModelsACP
import FoundationModelsAgents

/// The re-drive of the interrupted nested runs of a resumed root session.
///
/// The cold resume restored the interrupted children idle (``restoreNestedSessions(of:composition:)``)
/// and kept the report of the restore on the entry of the root. The re-drive starts the runs of
/// that report after the response of the resume and after the current snapshots of the children
/// (``syncChildren(of:)``): the client knows each child before the child works, and no re-driven
/// child sends an update before the response. The Agents package starts the children before their
/// callers (``RestoreReport/resumeAll()``). The end of a re-driven child completes the original
/// `start agent` call of its caller. A child that did not restore has no run to start: its
/// original call already ended as `lost`.
extension RoutedACPAgent {
  /// Starts the restored runs of the root `sessionId`, the children first. It starts nothing when
  /// the root closed or lost its connection since the resume, because no client is there to see
  /// the work.
  ///
  /// Before the start, each restored session shows `running` on its ledger. A restored caller
  /// holds the claimed run of its child since the restore, so its Router session reports its work
  /// as started at that time, before the ledger took the snapshot, and reports no new start when
  /// the caller works again. Router reports the end of the work, which sets the ledger idle.
  ///
  /// - Parameter sessionId: The resumed root session.
  func redriveInterruptedRuns(of sessionId: SessionId) async {
    guard let entry = sessions[sessionId], !entry.isClosed,
      connections.path(forSession: sessionId) != nil, let report = entry.nestedRestore
    else {
      return
    }
    for run in report.restored {
      await sessions[SessionId(rawValue: run.id.description)]?.stateLedger.workStarted(on: run.id)
    }
    report.resumeAll()
  }
}
