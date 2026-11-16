import FoundationModelsACP
import FoundationModelsRouter

/// What a cold resume does for one open call whose run was in the background when the agent
/// stopped.
///
/// The retained history keeps such a call `pending`, `in_progress` or `paused`, with the marker
/// ``BackgroundRunMeta``. The live process that knew the run is gone. Thus without this step, the
/// call stays open on the client for ever. The journal of the session tells what became of the
/// run (`RouterSessionDirectory.runStatuses(of:)`):
///
/// - The run completed: the call gets its final status now, with a note that the run ended while
///   the agent was not running.
/// - The run is orphaned: Router posts a `_lost` terminal for it. The resume joins the token of
///   the run to the call again, so that terminal goes on the same wire id, and no new row keyed on
///   the token comes.
/// - The journal does not know the run: the call is lost now.
///
/// The `agents` calls of restored runs are not in this step. The restore of the child drives them
/// (``RoutedACPAgent/restoreOpenCalls(of:)``).
enum BackgroundCallRestore: Equatable {
  /// Join the completion token of the run to the wire id of its call.
  case rejoin(token: String, call: ToolCallId)

  /// Add this final update of the call to the history.
  case finish(ToolCallUpdate)

  /// The note of a call whose run completed while the agent was not running.
  static let endedWhileDownText = "The run ended while the agent was not running"

  /// The note of a call whose run the journal does not know.
  static let unknownRunText = "The agent stopped, and no record tells how the run ended"

  /// The restores of the open background calls of one history.
  ///
  /// - Parameters:
  ///   - history: The updates of the retained history, merged: one update for each call.
  ///   - statuses: The status of each run in the journal of the session.
  ///   - skipping: The completion tokens of the runs that another restore drives.
  /// - Returns: The restores, in the order of the calls.
  static func restores(
    of history: [SessionUpdate], statuses: [RunKey: RunStatus], skipping: Set<String>
  ) -> [BackgroundCallRestore] {
    var byToken: [String: RunStatus] = [:]
    for (key, status) in statuses {
      byToken[key.correlationID] = status
    }
    return history.compactMap { update in
      guard case .toolCallUpdate(let call) = update, !BackgroundWatch.isFinal(call.status),
        case .value(let meta) = call.meta,
        let token = BackgroundRunMeta.completionToken(in: meta), !skipping.contains(token)
      else {
        return nil
      }
      return restore(of: call.toolCallId, token: token, status: byToken[token])
    }
  }

  /// The restore of one open call.
  ///
  /// - Parameters:
  ///   - call: The wire id of the call.
  ///   - token: The completion token of its run.
  ///   - status: The status of the run in the journal, or `nil` when the journal does not know it.
  /// - Returns: The restore.
  private static func restore(of call: ToolCallId, token: String, status: RunStatus?)
    -> BackgroundCallRestore
  {
    switch status {
    case .completed(let outcome):
      return .finish(
        finalUpdate(
          of: call, status: ACPEventTranslator.wireStatus(for: outcome), note: endedWhileDownText))
    case .orphaned:
      return .rejoin(token: token, call: call)
    case nil:
      return .finish(
        finalUpdate(
          of: call, status: .unknown(ACPEventTranslator.lostStatusWireValue),
          note: unknownRunText))
    }
  }

  /// The final update of a call, with a note as its content.
  ///
  /// - Parameters:
  ///   - call: The wire id of the call.
  ///   - status: The final status.
  ///   - note: The text of the content.
  /// - Returns: The update.
  private static func finalUpdate(
    of call: ToolCallId, status: FoundationModelsACP.ToolCallStatus, note: String
  ) -> ToolCallUpdate {
    var update = ToolCallUpdate(toolCallId: call)
    update.status = .value(status)
    update.content = .value([.content(Content(content: .text(TextContent(text: note))))])
    return update
  }
}

extension RoutedACPAgent {
  /// Ends or joins again each open call of a resumed session whose run was in the background
  /// when the agent stopped (``BackgroundCallRestore``). Call it after the restore of the nested
  /// sessions, and before the replay.
  ///
  /// - Parameters:
  ///   - sessionId: The resumed session.
  ///   - recordedId: The recorded id of the session in the Router.
  func restoreBackgroundCalls(of sessionId: SessionId, recordedId: ULID) async {
    guard let entry = sessions[sessionId] else {
      return
    }
    let statuses: [RunKey: RunStatus]
    do {
      statuses = try await sessionDirectory.runStatuses(of: recordedId)
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The journal of a resumed session did not read. Its open background calls stay open.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
      return
    }
    let restored = Set(entry.nestedRestore?.restored.compactMap(\.completionToken) ?? [])
    let restores = BackgroundCallRestore.restores(
      of: entry.history.transcriptUpdates, statuses: statuses, skipping: restored)
    for restore in restores {
      switch restore {
      case .rejoin(let token, let call):
        entry.projector.runCallJoins.record(toolCallID: call.rawValue, for: RunToken(token))
      case .finish(let update):
        recordInHistory(.toolCallUpdate(update), of: sessionId)
      }
    }
  }
}
