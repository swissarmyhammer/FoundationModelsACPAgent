import Dispatch
import FoundationModelsACPAgent
import Synchronization

/// A secret store that keeps back one read of a secret reference until the test opens it.
///
/// The settings store of the agent reads each secret reference of the configuration when it
/// merges the configuration of a working directory. So a test that writes a reference into the
/// project configuration, and arms this gate, stops the next merge at a known step. The merge
/// waits on its thread until ``open()``. The agent actor is free while a request waits on the
/// merge, so the test can make the agent do other work in that interval. No clock decides the
/// order.
///
/// Each read before ``arm(onEntry:)`` and after ``open()`` gives the value at once.
final class SecretStoreGate: SecretStore {
  /// Where the gate is.
  private enum Phase {
    /// The gate is not armed. Each read goes through.
    case idle

    /// The next read waits. The value tells the test that the read came.
    case armed(@Sendable () -> Void)

    /// A read waits now.
    case holding

    /// The test opened the gate. Each read goes through.
    case open
  }

  /// Where the gate is, under its lock.
  private let phase = Mutex(Phase.idle)

  /// The signal that lets the waiting read go.
  private let opening = DispatchSemaphore(value: 0)

  /// The value of each reference.
  private let secret: String

  /// Makes a gate that is not armed.
  ///
  /// - Parameter secret: The value that the store gives for each reference.
  init(giving secret: String) {
    self.secret = secret
  }

  /// Arms the gate: the next read waits until ``open()``.
  ///
  /// - Parameter onEntry: Called once, when the next read comes and starts to wait.
  func arm(onEntry: @escaping @Sendable () -> Void) {
    phase.withLock { $0 = .armed(onEntry) }
  }

  /// Opens the gate. The read that waits goes on, and each later read goes through. A gate that
  /// no read entered does not keep a read back after this call.
  func open() {
    let wasHolding = phase.withLock { phase -> Bool in
      defer { phase = .open }
      if case .holding = phase {
        return true
      }
      return false
    }
    if wasHolding {
      opening.signal()
    }
  }

  /// Gives the value of a reference. The first read after ``arm(onEntry:)`` waits until
  /// ``open()``.
  ///
  /// - Parameter name: The reference name.
  /// - Returns: The value of the gate.
  func value(forReference name: String) throws -> String? {
    let onEntry = phase.withLock { phase -> (@Sendable () -> Void)? in
      guard case .armed(let onEntry) = phase else {
        return nil
      }
      phase = .holding
      return onEntry
    }
    if let onEntry {
      onEntry()
      opening.wait()
    }
    return secret
  }
}
