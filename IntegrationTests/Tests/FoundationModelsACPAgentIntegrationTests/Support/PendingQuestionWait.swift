// `PendingQuestionWait` — the wait of a client for the first question that
// the agent asked in one session.
//
// The session model of the client keeps each question that waits for the
// user. A change of that list resumes the wait, so the wait uses no clock and
// no poll. The wait ends also when its task is cancelled: a wait that ignored
// cancel would hold a test that no question will reach, and the time limit of
// Swift Testing cannot end a body that waits in an await that ignores cancel.

import FoundationModelsACPClient
import Observation
import Synchronization

/// The wake of one wait: it resumes the wait one time, for a change of the
/// list or for a cancel, whichever comes first.
private final class OneShotWake: Sendable {
  /// Where the wake stands.
  private enum State {
    /// Nothing happened yet.
    case idle

    /// The wait is suspended, and holds this continuation.
    case suspended(CheckedContinuation<Void, Never>)

    /// A change or a cancel came, and the wait did not suspend yet or
    /// resumed already.
    case fired
  }

  /// The state, under its lock.
  private let state = Mutex(State.idle)

  /// Suspends the wait, unless the wake fired already.
  ///
  /// - Parameter continuation: The continuation of the wait.
  func suspend(_ continuation: CheckedContinuation<Void, Never>) {
    let resumeAtOnce = state.withLock { state -> Bool in
      if case .fired = state {
        return true
      }
      state = .suspended(continuation)
      return false
    }
    if resumeAtOnce {
      continuation.resume()
    }
  }

  /// Resumes the wait, or marks the wake as fired when the wait did not
  /// suspend yet. A second call does nothing.
  func fire() {
    let suspended = state.withLock { state -> CheckedContinuation<Void, Never>? in
      defer { state = .fired }
      if case .suspended(let continuation) = state {
        return continuation
      }
      return nil
    }
    suspended?.resume()
  }
}

/// Waits for the question of an agent at the client end of one session.
@MainActor
enum PendingQuestionWait {
  /// Waits until `session` holds a pending question, and gives the first one.
  ///
  /// - Parameter session: The session model of the client.
  /// - Returns: The first pending question.
  /// - Throws: `CancellationError` when the task is cancelled first.
  static func first(in session: SessionModel) async throws -> PendingElicitation {
    while true {
      if let first = session.pendingElicitations.first {
        return first
      }
      try Task.checkCancellation()
      let wake = OneShotWake()
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          // The check above and the observation below run with no
          // suspension between them, so no change of the list is lost.
          withObservationTracking {
            _ = session.pendingElicitations
          } onChange: {
            wake.fire()
          }
          wake.suspend(continuation)
        }
      } onCancel: {
        wake.fire()
      }
    }
  }
}
