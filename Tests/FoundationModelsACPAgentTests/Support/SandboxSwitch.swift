import FoundationModelsExtras
import Synchronization

/// A switch that a test sandbox probe reads (task ^22h3kvw).
///
/// An agent checks its mode with the probe when it starts. A test turns the
/// switch on after the start, so a later session composition sees a
/// sandboxed process.
final class SandboxSwitch: Sendable {
  /// The state of the switch.
  private let state = Mutex(false)

  /// Makes a switch that is off.
  init() {}

  /// Whether the probe tells that the process is sandboxed.
  var isSandboxed: Bool {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }

  /// A sandbox probe that reads this switch.
  var probe: SandboxProbe {
    SandboxProbe { self.isSandboxed }
  }
}
