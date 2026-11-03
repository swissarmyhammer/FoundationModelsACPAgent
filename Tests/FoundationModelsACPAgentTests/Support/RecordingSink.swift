import FoundationModelsACP
import Synchronization

@testable import FoundationModelsACPAgent

/// A sink that keeps each update it gets, in the order of the calls. The
/// suites of the state ledger share it.
final class RecordingSink: Sendable {
  /// The updates that the sink got.
  private let kept = Mutex<[SessionUpdate]>([])

  /// The updates that the sink got, in order.
  var updates: [SessionUpdate] {
    kept.withLock { $0 }
  }

  /// The names of the states that the sink got, in order.
  var names: [String] {
    stateNames(of: updates)
  }

  /// The sink function of the recorder.
  var send: SessionUpdateSink {
    { update in self.kept.withLock { $0.append(update) } }
  }
}
