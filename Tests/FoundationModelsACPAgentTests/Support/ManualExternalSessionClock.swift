import Foundation
import Synchronization

@testable import FoundationModelsACPAgent

/// A clock of ``ExternalSessionIndex`` that moves only when a test calls ``advance(by:)``.
///
/// A sleep returns when the test moves the clock past its deadline, or at once for a deadline
/// that passed. Thus a test of the 30 s limits waits on no real time.
final class ManualExternalSessionClock: ExternalSessionClock {
  /// The state of the clock.
  private struct State {
    /// The time from the start of the clock.
    var elapsed: Duration = .zero

    /// The tasks that sleep, with their deadlines, by their token.
    var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>)] =
      [:]
  }

  /// The time of the start of the clock.
  private let start = ContinuousClock.now

  /// The state.
  private let state = Mutex(State())

  var now: ContinuousClock.Instant { start + state.withLock { $0.elapsed } }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    let token = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // The check of the cancellation is under the lock, as the cancel handler is: a
        // cancel either finds the sleeper, or comes before it and is seen here.
        let wake = state.withLock { state -> Result<Void, CancellationError>? in
          guard !Task.isCancelled else { return .failure(CancellationError()) }
          guard start + state.elapsed < deadline else { return .success(()) }
          state.sleepers[token] = (deadline, continuation)
          return nil
        }
        if let wake { continuation.resume(with: wake) }
      }
    } onCancel: {
      state.withLock { $0.sleepers.removeValue(forKey: token) }?.continuation.resume(
        throwing: CancellationError())
    }
  }

  /// Moves the clock, and wakes each task whose deadline passed.
  ///
  /// - Parameter duration: The time to add.
  func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.elapsed += duration
      let now = start + state.elapsed
      let due = state.sleepers.filter { $0.value.deadline <= now }
      for token in due.keys {
        state.sleepers[token] = nil
      }
      return due.values.map(\.continuation)
    }
    for continuation in due {
      continuation.resume()
    }
  }
}
