import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The receiver of the changes of the work that runs apart from the foreground work. The state
/// ledger of the session is the one receiver.
typealias BackgroundReport = @Sendable (BackgroundChange) async -> Void

/// Finds the tool calls whose run goes on after the SDK call returned. It also finds the wire
/// updates that announce and finish them. It turns both into ``BackgroundChange`` values.
///
/// A run is background work from the moment its SDK call returned with the run still open. It
/// stays background work until its final status went to the client. The events of one run come in
/// this order:
///
/// - The open record joins the run to the SDK call.
/// - The first progress of the run shows that the run is on the run plane.
/// - The `toolStatus` of the SDK call says that the call returned.
/// - The settlement of the run ends it.
///
/// A run whose settlement comes before the `toolStatus` of its call ended inline. It is never
/// detached. The watch tells the settlement before the translator sends the final status. It
/// reports the end of the run only when that update reached the sink. A final status that a hold
/// keeps back (``AgentCallHolds``) does not reach the sink yet. So the call stays listed until the
/// hold lets it go.
///
/// The watch keeps one entry for each open run, and one short id for each call of the session.
/// The join table (``RunCallJoinTable``) has the same bound.
final class BackgroundWatch: Sendable {
  /// One run that the session opened.
  private struct Run {
    /// The wire id of the tool call of the run.
    let call: ToolCallId

    /// Whether the run posted progress, which tells that it is on the run plane.
    var hasProgress = false

    /// Whether the settlement of the run is in translation.
    var isSettling = false

    /// Whether the run was reported as detached.
    var isDetached = false

    /// Whether the run goes on after its SDK call returned: it is on the run plane, it does not
    /// settle, and it was not reported before.
    var canDetach: Bool {
      hasProgress && !isSettling && !isDetached
    }
  }

  /// What the watch keeps, under one lock.
  private struct State {
    /// The open runs, by completion token.
    var runs: [RunToken: Run] = [:]

    /// The wire ids of the calls whose update went to the client. It holds one short id for each
    /// call of the session, as the join table does.
    var announcedCalls: Set<ToolCallId> = []

    /// The token of the run that settles on a call.
    ///
    /// - Parameter call: The wire id of the call.
    /// - Returns: The token, or `nil` when no run settles on the call.
    func settlingToken(of call: ToolCallId) -> RunToken? {
      runs.first { $0.value.call == call && $0.value.isSettling }?.key
    }
  }

  /// The state of the watch.
  private let state = Mutex(State())

  /// Makes a sink that tells the changes of the sent updates, after each update is sent.
  ///
  /// - Parameters:
  ///   - sink: The sink that sends the updates.
  ///   - report: The receiver of the changes.
  /// - Returns: The sink that reports.
  func reporting(
    sentThrough sink: @escaping SessionUpdateSink, to report: @escaping BackgroundReport
  )
    -> SessionUpdateSink
  {
    { [self] update in
      await sink(update)
      for change in changes(afterSending: update) {
        await report(change)
      }
    }
  }

  /// Notes an event before the translator handles it.
  ///
  /// - Parameter event: The event.
  func willTranslate(_ event: SessionEvent) {
    guard case .runSettled(let operation) = event, operation.kind == .completed else {
      return
    }
    state.withLock { $0.runs[RunToken(operation.correlationID)]?.isSettling = true }
  }

  /// Notes an event after the translator handled it.
  ///
  /// - Parameters:
  ///   - event: The event.
  ///   - joins: The join table of the session, which gives the wire id of a run.
  /// - Returns: The changes that the event makes.
  func didTranslate(_ event: SessionEvent, joins: RunCallJoinTable) -> [BackgroundChange] {
    switch event {
    case .toolInvocation(let record, _) where record.closedAt == nil:
      let token = RunToken(record.correlationID)
      let call = joins.toolCallId(for: token)
      state.withLock { $0.runs[token] = Run(call: call) }
    case .runProgress(let operation):
      state.withLock { $0.runs[RunToken(operation.correlationID)]?.hasProgress = true }
    case .toolStatus(let id, let status, _, _) where status != .running:
      return detach(callWithSDKId: id)
    default:
      break
    }
    return []
  }

  /// Marks the run of an SDK call as detached, when the call returned and the run goes on.
  ///
  /// - Parameter id: The SDK id of the call that returned.
  /// - Returns: The change, or none when no run goes on for the call.
  private func detach(callWithSDKId id: String) -> [BackgroundChange] {
    state.withLock { state in
      let wanted = ToolCallId(rawValue: id)
      guard
        let token = state.runs.first(where: { $0.value.call == wanted && $0.value.canDetach })?.key
      else {
        return []
      }
      state.runs[token]?.isDetached = true
      return [.callDetached(wanted)]
    }
  }

  /// The changes that a sent update makes.
  ///
  /// - Parameter update: The update that went to the client.
  /// - Returns: The announcement of its call. Also the end of the run, when the update carries
  ///   the final status of a run that settles.
  private func changes(afterSending update: SessionUpdate) -> [BackgroundChange] {
    guard case .toolCallUpdate(let call) = update else {
      return []
    }
    return state.withLock { state in
      var changes: [BackgroundChange] = []
      if state.announcedCalls.insert(call.toolCallId).inserted {
        changes.append(.callAnnounced(call.toolCallId))
      }
      if let token = state.settlingToken(of: call.toolCallId), Self.isFinal(call.status) {
        state.runs.removeValue(forKey: token)
        changes.append(.callSettled(call.toolCallId))
      }
      return changes
    }
  }

  /// Whether a status patch ends a call.
  ///
  /// - Parameter status: The patch of an update.
  /// - Returns: `true` for a status that is not `pending`, `in_progress` or `paused`.
  static func isFinal(_ status: PatchField<FoundationModelsACP.ToolCallStatus>) -> Bool {
    guard case .value(let value) = status else {
      return false
    }
    switch value {
    case .pending, .inProgress, .paused:
      return false
    case .completed, .failed, .cancelled, .unknown:
      return true
    }
  }
}
