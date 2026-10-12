import Synchronization

/// Counts the calls of one thing that a test watches: for example the close
/// of the ACP connection, the stop of a window, or the runs of a tool body.
///
/// The calls can come from many tasks, so a mutex guards the count. Each
/// copy of a value that holds the counter shares the same count.
public final class CallCounter: Sendable {
    /// The number of calls so far.
    private let calls = Mutex(0)

    /// Creates a counter that counted no call.
    public init() {}

    /// Records one call.
    public func record() {
        calls.withLock { $0 += 1 }
    }

    /// The number of calls so far.
    public var count: Int {
        calls.withLock { $0 }
    }
}
