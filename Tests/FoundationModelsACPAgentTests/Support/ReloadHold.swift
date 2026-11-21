import Dispatch
import FoundationModelsACPAgentTestSupport
import Synchronization

/// Holds the first reload of an agent registry inside its read of the agent
/// files, so that the reload keeps the registry while a test looks at it
/// (task ^22h3kvw).
///
/// A registry stops to watch when it is released. A reload that runs keeps
/// the registry. So while the hold keeps the reload, only a stop of the
/// registry ends its watch.
///
/// The conflict source of the registry calls ``pass(requestingReload:)``
/// for each conflict-version read:
///
/// 1. The first read comes from the first build of the registry. The hold
///    requests a reload, and waits until the reload reads.
/// 2. The next read comes from that reload. The hold keeps it until
///    ``release()``.
/// 3. Each later read passes at once.
final class ReloadHold: Sendable {
  /// The progress of the hold.
  private enum Phase {
    /// No read came yet.
    case idle

    /// The first build requested a reload, and waits for its read.
    case reloadRequested

    /// The reload reads, and the hold keeps it.
    case reloadHeld
  }

  /// The progress of the hold.
  private let phase = Mutex(Phase.idle)

  /// The signal of the first read of the reload to the first build.
  private let reloadEntered = DispatchSemaphore(value: 0)

  /// The gate that keeps the read of the reload until ``release()``.
  private let gate = DispatchSemaphore(value: 0)

  /// Whether the hold keeps a reload now, with its waits.
  let isHoldingReload = WatchedValue(false)

  /// Makes a hold that saw no read.
  init() {}

  /// Lets one conflict-version read pass, or keeps it, by the progress of
  /// the hold.
  ///
  /// - Parameter requestReload: Requests a reload of the registry. The hold
  ///   calls it for the first read only.
  func pass(requestingReload requestReload: () -> Void) {
    let previous = phase.withLock { phase -> Phase in
      let previous = phase
      if previous == .idle {
        phase = .reloadRequested
      } else {
        phase = .reloadHeld
      }
      return previous
    }
    switch previous {
    case .idle:
      requestReload()
      reloadEntered.wait()
    case .reloadRequested:
      isHoldingReload.update { $0 = true }
      reloadEntered.signal()
      gate.wait()
    case .reloadHeld:
      return
    }
  }

  /// Lets the kept read of the reload continue.
  func release() {
    gate.signal()
  }
}
