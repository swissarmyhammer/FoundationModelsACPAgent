import FoundationModelsACPAgentTestSupport
import Observation
import Synchronization

/// The wait for a condition over observable state of the main actor, for
/// example a `SessionModel` of the client.
///
/// The wait reads the condition inside `withObservationTracking`. When the
/// condition is false, the next change of a value that the read touched
/// ends the observation, and the wait reads the condition again. Thus the
/// wait uses no clock and no poll.
@MainActor
enum ObservedValue {
  /// Waits until `isMet` is true. Returns at once when it is true now.
  ///
  /// - Parameters:
  ///   - condition: The name of the condition, for the error of a
  ///     cancelled wait.
  ///   - isMet: Tells if the condition is true. It reads only
  ///     observable state.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the condition comes.
  static func wait(for condition: String, until isMet: @escaping @MainActor () -> Bool) async throws
  {
    while true {
      let shot = OneShot()
      let met = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
          shot.arm(continuation)
          MainActor.assumeIsolated {
            let now = withObservationTracking {
              isMet()
            } onChange: {
              shot.fire(false)
            }
            if now {
              shot.fire(true)
            } else if Task.isCancelled {
              shot.fire(false)
            }
          }
        }
      } onCancel: {
        shot.fire(false)
      }
      if met {
        return
      }
      if Task.isCancelled {
        throw ConditionWaitCancelled(condition: condition)
      }
    }
  }
}

/// A continuation that resumes exactly one time: by the first call of
/// ``fire(_:)``. A change of the observed state, the read that finds the
/// condition true, and a cancel can each call it, from different threads.
final class OneShot: Sendable {
  /// The state of the shot. Only the valid states can be written: a
  /// continuation waits only before the fire, and a value exists only after
  /// the fire.
  private enum State {
    /// No arm and no fire came.
    case unarmed

    /// The continuation waits for the fire.
    case armed(CheckedContinuation<Bool, Never>)

    /// The first fire came, with this value.
    case fired(Bool)
  }

  /// The state, under one lock.
  private let state = Mutex(State.unarmed)

  /// Keeps `continuation`. A fire that already came resumes it at once.
  ///
  /// - Parameter continuation: The continuation of the wait.
  func arm(_ continuation: CheckedContinuation<Bool, Never>) {
    let firedValue = state.withLock { state -> Bool? in
      if case .fired(let value) = state {
        return value
      }
      state = .armed(continuation)
      return nil
    }
    if let firedValue {
      continuation.resume(returning: firedValue)
    }
  }

  /// Resumes the continuation with `value`, only on the first call.
  ///
  /// - Parameter value: Whether the condition is true.
  func fire(_ value: Bool) {
    let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      if case .fired = state {
        return nil
      }
      defer { state = .fired(value) }
      if case .armed(let continuation) = state {
        return continuation
      }
      return nil
    }
    continuation?.resume(returning: value)
  }
}
