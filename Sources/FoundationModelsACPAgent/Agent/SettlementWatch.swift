import Synchronization

/// Tells the host when the projector of a session has handled the settlement of a run.
///
/// The host completes a claimed `start agent` call through the Router session of the caller: the
/// completion posts a `runSettled` event, and the projector of the session reads that event in a
/// task of its own and sends the final status of the call. A host that goes on at once can send
/// its next update before that status. A resume does this when a child does not restore: it ends
/// the claim of the child as `lost`, and the status of the call must come before the current
/// `state_update` of the resume (task ^pmn2p11).
///
/// The host registers the run before it posts the completion (``expect(_:)``), so a settlement
/// that is handled at once is not missed. The projector tells each settlement after it sent the
/// update of the settlement (``settled(_:)``).
final class SettlementWatch: Sendable {
  /// What the watch knows about one run.
  private enum Entry {
    /// The host expects the settlement, and nobody waits for it yet.
    case expected

    /// The projector handled the settlement, and nobody waited for it yet.
    case settled

    /// A task waits for the settlement.
    case waiting(CheckedContinuation<Void, Never>)
  }

  /// What the watch keeps, under one lock.
  private struct State {
    /// The runs that the host expects, by completion token.
    var entries: [String: Entry] = [:]

    /// Whether the projector ended. A run is not expected any more then.
    var isClosed = false
  }

  /// The state of the watch.
  private let state = Mutex(State())

  /// Notes that the host will post the completion of the run with `token`. Call it before the
  /// post.
  ///
  /// - Parameter token: The completion token of the run.
  func expect(_ token: String) {
    state.withLock { state in
      if !state.isClosed {
        state.entries[token] = .expected
      }
    }
  }

  /// Drops the expectation of a run whose completion was not posted.
  ///
  /// - Parameter token: The completion token of the run.
  func forget(_ token: String) {
    state.withLock { _ = $0.entries.removeValue(forKey: token) }
  }

  /// Tells that the projector handled the settlement of the run with `token`. A run that nobody
  /// expects gives nothing.
  ///
  /// - Parameter token: The completion token of the run.
  func settled(_ token: String) {
    let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
      switch state.entries[token] {
      case .expected:
        state.entries[token] = .settled
        return nil
      case .waiting(let continuation):
        state.entries.removeValue(forKey: token)
        return continuation
      case .settled, nil:
        return nil
      }
    }
    waiter?.resume()
  }

  /// Suspends until the projector handled the settlement of the run with `token`. It returns at
  /// once for a run that nobody expects, for a settlement that is handled already, and after
  /// ``close()``.
  ///
  /// - Parameter token: The completion token of the run.
  func wait(for token: String) async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Bool in
        switch state.entries[token] {
        case .expected:
          state.entries[token] = .waiting(continuation)
          return false
        case .settled:
          state.entries.removeValue(forKey: token)
          return true
        case .waiting, nil:
          return true
        }
      }
      if ready {
        continuation.resume()
      }
    }
  }

  /// Posts the completion of a run and waits until the projector handled its settlement.
  ///
  /// - Parameters:
  ///   - token: The completion token of the run.
  ///   - post: Posts the completion to the Router session. It gives `true` when the session took
  ///     the completion, and `false` when it refused it.
  /// - Returns: What `post` gave. A refused completion makes no settlement, so the call does not
  ///   wait for it.
  func completing(_ token: String, by post: () async -> Bool) async -> Bool {
    expect(token)
    guard await post() else {
      forget(token)
      return false
    }
    await wait(for: token)
    return true
  }

  /// Ends the watch: each waiter goes on, and no run is expected any more. The projector calls it
  /// when it ends, because no settlement comes after that.
  func close() {
    let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
      state.isClosed = true
      let waiting = state.entries.values.compactMap { entry -> CheckedContinuation<Void, Never>? in
        if case .waiting(let continuation) = entry {
          return continuation
        }
        return nil
      }
      state.entries = [:]
      return waiting
    }
    for waiter in waiters {
      waiter.resume()
    }
  }
}
