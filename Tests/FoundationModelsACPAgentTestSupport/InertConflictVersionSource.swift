import Foundation
import FoundationModelsAgents

/// The conflict source of the agent registry of each test session: it gives
/// no conflict version and adds no file presenter.
///
/// The default source, `FileVersionConflictSource`, adds one
/// `NSFileCoordinator` file presenter for each watched root of each agent
/// registry. A full test run makes thousands of sessions in one process, and
/// each coordinated read of the process takes more time for each presenter of
/// the process (task ^j5dys15). With some hundreds of presenters, one
/// coordinated read of an `AGENT.md` takes seconds, and the reads that wait
/// hold each thread of the cooperative pool. Then each timer and each wait of
/// the other tests stops, and those tests fail at their time limit.
///
/// No suite of this package reads the conflict versions of an agent file.
public struct InertConflictVersionSource: AgentConflictVersionSource {
  /// Makes the source.
  public init() {}

  /// Gives no conflict version.
  ///
  /// - Parameter url: The URL of the agent file.
  /// - Returns: An empty list.
  public func conflictVersions(of url: URL) -> [AgentConflictVersion] {
    []
  }

  /// Gives a stream that gives no value, and adds no file presenter.
  ///
  /// - Parameter roots: The roots of the registry, which the source does not
  ///   follow.
  /// - Returns: A stream that ends only when the registry stops to iterate it.
  public func changes(under roots: [URL]) -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}
