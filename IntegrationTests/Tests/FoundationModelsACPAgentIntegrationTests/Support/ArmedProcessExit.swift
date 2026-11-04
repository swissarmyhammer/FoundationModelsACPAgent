import Dispatch
import Foundation
import FoundationModelsACPAgentTestSupport

/// The exit event of a process of this machine that this process did not
/// start, armed while the process is alive.
///
/// The kernel event source holds the process itself, not its pid. A pid
/// that the system gives to a new process after the reap thus cannot end or
/// hold the wait, and the wait uses no clock and no poll.
final class ArmedProcessExit: Sendable {
  /// The process watched.
  let pid: pid_t

  /// Whether the process exited, with its waits.
  private let exited = WatchedValue(false)

  /// The kernel event source. It is kept until the end of the wait.
  private let source: any DispatchSourceProcess

  /// The queue of the event handler and of the read after the arm.
  private let queue = DispatchQueue(label: "ArmedProcessExit")

  /// Arms the exit event of `pid`. Call it while `pid` is alive.
  ///
  /// A process that exited before the arm sends no event, so after the arm
  /// the event reads one time, with ``ProcessState/hasExited(_:)``, whether the process
  /// already exited.
  ///
  /// - Parameter pid: The process to watch.
  init(pid: pid_t) {
    self.pid = pid
    source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    let exited = exited
    source.setEventHandler {
      exited.update { $0 = true }
    }
    source.resume()
    queue.async {
      if ProcessState.hasExited(pid) {
        exited.update { $0 = true }
      }
    }
  }

  deinit {
    source.cancel()
  }

  /// Waits until the process exited. The end of the wait is the result: do
  /// not read the state of the pid again after it.
  ///
  /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
  func wait() async throws {
    _ = try await exited.wait(for: "the exit of process \(pid)") { $0 }
  }
}
