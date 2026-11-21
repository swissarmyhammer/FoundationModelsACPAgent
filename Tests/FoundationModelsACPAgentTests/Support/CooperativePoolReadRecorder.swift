import Synchronization

/// Records, for each read of a probe, whether the read ran on a thread of the
/// cooperative pool (task ^6yt2dpb).
///
/// Each probe of the suites holds one recorder, and calls ``record()`` before
/// it reads.
final class CooperativePoolReadRecorder: Sendable {
  /// For each read, in order, whether it ran on a thread of the pool.
  private let records = Mutex<[Bool]>([])

  /// Makes a recorder that recorded no read.
  init() {}

  /// For each read so far, in order, whether it ran on a thread of the pool.
  var reads: [Bool] {
    records.withLock { $0 }
  }

  /// Records whether the code of now runs on a thread of the pool.
  func record() {
    let onPool = CooperativePool.isCurrentThreadInPool
    records.withLock { $0.append(onPool) }
  }
}
