import Foundation
import FoundationModelsRouter
import Synchronization

/// The recording roots that this agent composed a session under, in the order of the first use.
///
/// The session directory of the Router finds a recorded session only under the roots that the
/// host gives it (``RouterSessionDirectory/useRecordingRoots(_:)``). The roots of the projects in
/// the project store are not enough: a session can work in a folder that the store does not hold
/// yet. So the agent adds the root of each session that it composes, and the directory reads the
/// roots of this set and the roots of the project store (``RoutedACPAgent/recordingRootsOfTheDirectory()``).
final class KnownRecordingRoots: Sendable {
  /// The roots, without a repeated root.
  private let roots = Mutex<[URL]>([])

  /// Adds a root. A root that the set holds already changes nothing.
  ///
  /// - Parameter root: The recording root of a composed session.
  func add(_ root: URL) {
    let standardized = root.standardizedFileURL
    roots.withLock { roots in
      if !roots.contains(standardized) {
        roots.append(standardized)
      }
    }
  }

  /// The roots now, in the order of the first use.
  var all: [URL] {
    roots.withLock { $0 }
  }
}

extension RoutedACPAgent {
  /// Makes the reader of the recording roots that the session directory and the transcript reader
  /// use: the roots of the composed sessions (``knownRecordingRoots``) and the roots of the project
  /// store of the home (``RegisteredRecordingRoots``), without a repeated root.
  ///
  /// - Returns: The reader. It reads the project store at each call.
  nonisolated func recordingRootsOfTheDirectory() -> @Sendable () async -> [URL] {
    Self.recordingRoots(known: knownRecordingRoots, store: settingsStore)
  }

  /// Makes the reader of the roots from its two sources. The initializer calls it before the agent
  /// is complete, so it takes the sources as arguments.
  ///
  /// Each failure of the resolution of the project store gets one `warning` record
  /// (``RegisteredRecordingRoots/Failure/log()``). The roots of the composed sessions still go in
  /// the result.
  ///
  /// - Parameters:
  ///   - known: The roots of the composed sessions.
  ///   - store: The settings store that gives the project store.
  /// - Returns: The reader of the roots.
  nonisolated static func recordingRoots(
    known: KnownRecordingRoots, store: SettingsStore
  ) -> @Sendable () async -> [URL] {
    {
      var roots = known.all
      let registered = await RegisteredRecordingRoots.resolve(in: store)
      for failure in registered.failures {
        failure.log()
      }
      for root in registered.roots {
        let standardized = root.standardizedFileURL
        if !roots.contains(standardized) {
          roots.append(standardized)
        }
      }
      return roots
    }
  }
}
