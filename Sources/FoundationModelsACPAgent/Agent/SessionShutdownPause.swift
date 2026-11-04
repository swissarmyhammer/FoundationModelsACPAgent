import FoundationModelsACP
import Synchronization

/// The pause of the open tool calls at the orderly shutdown of the process (task ^d6vzdkg).
///
/// An orderly shutdown is not a `session/close`. It cancels nothing: the work that runs stays
/// restorable. So each tool call that runs gets the status `paused` (ACP `ToolCallStatus`: the
/// call started, does not run now, and does not continue until something resumes it), and never
/// a final status. The history then holds no final status for the call. A resume of the session
/// reads that as an interrupted call and restores the child that the call started.
extension RoutedACPAgent {
  /// Sends a `tool_call_update` with the status `paused` for each tool call of the session that
  /// runs, and then does the same for each session nested in it. The updates go through the
  /// projector of each session, so they keep their order with the events of that session, and
  /// the history records them.
  ///
  /// A call that did not start (`pending`), a call that is paused already, and a call with a
  /// final status get nothing.
  ///
  /// - Parameter sessionId: The session whose open tool calls pause.
  func pauseOpenToolCalls(of sessionId: SessionId) async {
    guard let entry = sessions[sessionId] else {
      return
    }
    // From here on, a tool call that ends because its run stops gets no final status. The
    // history is read after this step, so a call that the stop ends later stays `in_progress`
    // in it, and the pause below covers it.
    entry.projector.interruption.begin()
    for update in entry.history.runningToolCallPauses {
      await entry.projector.commandSink(.toolCallUpdate(update))
    }
    for childId in entry.children {
      await pauseOpenToolCalls(of: childId)
    }
  }
}

extension SessionMergeEngine {
  /// The updates that pause the tool calls that run now: one for each merged tool call with the
  /// status `in_progress`, in the order of the calls.
  var runningToolCallPauses: [ToolCallUpdate] {
    transcriptUpdates.compactMap { update in
      guard case .toolCallUpdate(let call) = update, call.status == .value(.inProgress) else {
        return nil
      }
      return ToolCallUpdate(toolCallId: call.toolCallId, status: .value(.paused))
    }
  }
}

/// The switch that keeps a final status of a tool call out of the sends of a session after the
/// orderly shutdown began (task ^d6vzdkg).
///
/// The shutdown stops the agent runs, and a tool call that waits for a stopped run returns. That
/// return is no completion of the work: the work stays restorable. The call keeps the status
/// `paused`, and its final status goes nowhere: it is neither sent nor kept in the history.
final class InterruptedToolCalls: Sendable {
  /// Whether the shutdown began.
  private let began = Mutex(false)

  /// Starts to hold back the final status of each tool call. It cannot be undone: the process
  /// ends.
  func begin() {
    began.withLock { $0 = true }
  }

  /// A sink that gives each update to `send`, except for a final status of a tool call after
  /// ``begin()``.
  ///
  /// - Parameter send: The sink to guard.
  /// - Returns: The guarding sink.
  func filtering(_ send: @escaping SessionUpdateSink) -> SessionUpdateSink {
    { update in
      if case .toolCallUpdate(let call) = update, BackgroundWatch.isFinal(call.status),
        self.began.withLock({ $0 })
      {
        return
      }
      await send(update)
    }
  }
}
