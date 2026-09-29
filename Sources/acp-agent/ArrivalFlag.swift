import Synchronization

/// Whether a signal reached one watched window.
///
/// The task that reads the arrivals of a watch raises the flag, and the task
/// that runs the window reads it when the work of the window ends. A class,
/// because `Mutex` is noncopyable: the escaping closure of the watching task
/// captures this reference, not the lock itself.
final class ArrivalFlag: Sendable {
    /// Whether an arrival was recorded, guarded for the reader against the
    /// write of the watching task.
    private let guardedRaised = Mutex(false)

    /// Records that a signal arrived.
    func raise() {
        guardedRaised.withLock { $0 = true }
    }

    /// Whether a signal arrived.
    var isRaised: Bool {
        guardedRaised.withLock { $0 }
    }
}
