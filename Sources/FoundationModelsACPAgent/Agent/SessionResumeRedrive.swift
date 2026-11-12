import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter

/// The re-drive of the interrupted nested runs of a resumed root session.
///
/// The cold resume restored the interrupted children (``restoreNestedSessions(of:composition:)``)
/// and kept the report of the restore on the entry of the root. A restored run that the agent
/// drives again is work, and so is a caller that waits for one. Before the current state of the
/// root goes out, each of these sessions shows `running` on its ledger
/// (``holdRestoredWork(of:)``). So no snapshot of the tree says idle with noWork, and no `idle`
/// comes before the `running` of a restored run (decision of testudoapp-75).
///
/// The re-drive starts the runs of that report after the response of the resume and after the
/// current snapshots of the children (``syncChildren(of:)``): the client knows each child before
/// the child works, and no re-driven child sends an update before the response. The Agents package
/// starts the children before their callers (``RestoreReport/resumeAll()``). The end of a
/// re-driven child completes the original `start agent` call of its caller. A child that did not
/// restore has no run to start: its original call already ended as `lost`.
extension RoutedACPAgent {
  /// Shows each session that the restore of the root `sessionId` holds as `running` on its
  /// ledger: each restored run, and each caller of a restored run. The ledger sends no change
  /// (``SessionStateLedger/restoredWorkHeld(on:)``): the current-state sync of the resume reports
  /// the state. Call it before the sync of the root.
  ///
  /// A restored caller holds the claimed run of its child since the restore, so its Router
  /// session reports its work as started at that time, before the ledger listened, and reports
  /// no new start when the caller works again. Router reports the end of the work, which sets the
  /// ledger idle.
  ///
  /// - Parameter sessionId: The resumed root session.
  func holdRestoredWork(of sessionId: SessionId) async {
    await forEachHeldSource(of: sessionId) { ledger, source in
      await ledger.restoredWorkHeld(on: source)
    }
  }

  /// Starts the restored runs of the root `sessionId`, the children first. It starts nothing when
  /// the root closed or lost its connection since the resume, because no client is there to see
  /// the work. The ledgers then take back the hold of ``holdRestoredWork(of:)``.
  ///
  /// - Parameter sessionId: The resumed root session.
  func redriveInterruptedRuns(of sessionId: SessionId) async {
    guard let entry = sessions[sessionId], let report = entry.nestedRestore else {
      return
    }
    guard !entry.isClosed, connections.path(forSession: sessionId) != nil else {
      await releaseRestoredWork(of: sessionId)
      return
    }
    report.resumeAll()
  }

  /// Takes back the hold of ``holdRestoredWork(of:)`` on each held session of the root
  /// `sessionId`, when the agent does not drive the restored runs again.
  ///
  /// - Parameter sessionId: The resumed root session.
  func releaseRestoredWork(of sessionId: SessionId) async {
    await forEachHeldSource(of: sessionId) { ledger, source in
      await ledger.restoredWorkReleased(on: source)
    }
  }

  /// Runs `body` with the ledger and the Router id of each session that the restore of the root
  /// `sessionId` holds (``RestoreReport/heldSessions``). A session that is not in the table is
  /// left out.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed root session.
  ///   - body: The work on one held session.
  private func forEachHeldSource(
    of sessionId: SessionId, _ body: (SessionStateLedger, ULID) async -> Void
  ) async {
    guard let report = sessions[sessionId]?.nestedRestore else {
      return
    }
    for source in report.heldSessions {
      if let ledger = sessions[SessionId(rawValue: source.description)]?.stateLedger {
        await body(ledger, source)
      }
    }
  }
}

extension RestoreReport {
  /// The Router ids of the sessions that have work because of this restore: each restored run,
  /// and each caller that waits for a restored run. Each id comes once, the caller before its
  /// child.
  var heldSessions: [ULID] {
    var seen: Set<ULID> = []
    return restored.flatMap { run in [run.caller, run.id].compactMap { $0 } }
      .filter { seen.insert($0).inserted }
  }
}
