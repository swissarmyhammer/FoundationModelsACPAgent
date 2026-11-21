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
///
/// A source with a ``ReloadHold`` also gives the hold each
/// `conflictVersions(of:)` call. The hold requests a reload through the
/// newest change stream, and keeps that reload (task ^22h3kvw).
final class ProbingConflictVersionSource: AgentConflictVersionSource {
  /// The recorder of the thread of each `conflictVersions(of:)` call.
  private let recorder = CooperativePoolReadRecorder()

  /// The hold of the first reload, or `nil` for a source that keeps no
  /// read.
  private let reloadHold: ReloadHold?

  /// The continuation of the newest change stream, or `nil` before the
  /// first `changes(under:)` call.
  private let newestChanges = Mutex<AsyncStream<Void>.Continuation?>(nil)

  /// The count of `changes(under:)` streams that did not end, with its
  /// waits.
  let liveChangeStreams = WatchedValue(0)

  /// Makes a source that recorded nothing.
  ///
  /// - Parameter reloadHold: The hold of the first reload of the registry,
  ///   or `nil` (the default) for a source that keeps no read.
  init(reloadHold: ReloadHold? = nil) {
    self.reloadHold = reloadHold
  }

  /// For each `conflictVersions(of:)` call so far, in order, whether it ran
  /// on a thread of the cooperative pool.
  var readsOnCooperativePool: [Bool] {
    recorder.reads
  }

  /// Records the thread of the call, gives the call to the hold, and gives
  /// no conflict version.
  ///
  /// - Parameter url: The URL of the agent file.
  /// - Returns: An empty list.
  func conflictVersions(of url: URL) -> [AgentConflictVersion] {
    recorder.record()
    reloadHold?.pass { newestChanges.withLock { _ = $0?.yield() } }
    return []
  }

  /// Counts a new live stream, and gives a stream that gives a value only
  /// when the hold requests a reload. The count goes down when the stream
  /// ends.
  ///
  /// - Parameter roots: The roots of the registry, which the source does not
  ///   follow.
  /// - Returns: A stream that ends only when the registry stops to iterate it.
  func changes(under roots: [URL]) -> AsyncStream<Void> {
    liveChangeStreams.update { $0 += 1 }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    continuation.onTermination = { [liveChangeStreams] _ in
      liveChangeStreams.update { $0 -= 1 }
    }
    newestChanges.withLock { $0 = continuation }
    return stream
  }
}
