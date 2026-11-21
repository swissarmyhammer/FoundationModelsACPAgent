import Dispatch

/// Tells whether the code of now runs on a thread of the cooperative pool of
/// Swift concurrency (task ^6yt2dpb).
///
/// Each thread of the cooperative pool runs on a dispatch root queue whose
/// label ends with `.cooperative`, for example
/// `com.apple.root.default-qos.cooperative`. A thread of another queue has
/// the label of that queue.
enum CooperativePool {
  /// The end of the label of each queue of the cooperative pool.
  private static let labelSuffix = ".cooperative"

  /// Whether the code of now runs on a thread of the cooperative pool.
  static var isCurrentThreadInPool: Bool {
    String(cString: __dispatch_queue_get_label(nil)).hasSuffix(labelSuffix)
  }
}
