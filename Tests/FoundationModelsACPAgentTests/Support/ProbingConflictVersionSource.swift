import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Synchronization

/// A conflict source of an agent registry that gives no conflict version and
/// adds no file presenter, and that records what the registry does with it
/// (task ^6yt2dpb):
///
/// - For each `conflictVersions(of:)` call, whether the call ran on a thread
///   of the cooperative pool. Each build of the registry calls it, in the
///   same synchronous read as the coordinated read of each agent file.
/// - The count of `changes(under:)` streams that the registry follows now.
///   A registry with `watch: true` starts to follow a stream at its first
///   build, and ends the stream when it stops to watch.
final class ProbingConflictVersionSource: AgentConflictVersionSource {
  /// For each `conflictVersions(of:)` call, in order, whether it ran on a
  /// thread of the cooperative pool.
  private let reads = Mutex<[Bool]>([])

  /// The count of `changes(under:)` streams that did not end, with its
  /// waits.
  let liveChangeStreams = WatchedValue(0)

  /// Makes a source that recorded nothing.
  init() {}

  /// For each `conflictVersions(of:)` call so far, in order, whether it ran
  /// on a thread of the cooperative pool.
  var readsOnCooperativePool: [Bool] {
    reads.withLock { $0 }
  }

  /// Records the thread of the call, and gives no conflict version.
  ///
  /// - Parameter url: The URL of the agent file.
  /// - Returns: An empty list.
  func conflictVersions(of url: URL) -> [AgentConflictVersion] {
    let onPool = CooperativePool.isCurrentThreadInPool
    reads.withLock { $0.append(onPool) }
    return []
  }

  /// Counts a new live stream, and gives a stream that gives no value. The
  /// count goes down when the stream ends.
  ///
  /// - Parameter roots: The roots of the registry, which the source does not
  ///   follow.
  /// - Returns: A stream that ends only when the registry stops to iterate it.
  func changes(under roots: [URL]) -> AsyncStream<Void> {
    liveChangeStreams.update { $0 += 1 }
    return AsyncStream { continuation in
      continuation.onTermination = { [liveChangeStreams] _ in
        liveChangeStreams.update { $0 -= 1 }
      }
    }
  }
}
