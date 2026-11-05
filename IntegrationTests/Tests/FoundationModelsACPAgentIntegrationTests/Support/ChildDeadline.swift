// `ChildDeadline` — the limit of one spawned child, and the failure when the
// child passes it.
//
// On 2026-11-05 a CI run held the runner for 5 h 14 min, and the time limit of
// the suite never fired. Swift Testing starts a time limit as a timer beside
// the test body, but it cannot end a body that waits in an await that ignores
// cancel, and a blocking read of a pipe holds a thread of the cooperative pool
// with no cancel at all. A timer that acts on the TEST cannot help then.
//
// This deadline acts on the CHILD. At the limit it kills the child with
// `SIGKILL`. The pipes of the child then reach their end, the connection over
// them closes, and each wait of the test ends by an event. The failure holds
// the stderr of the child, so a CI log says what the child did before it
// stopped. A test that ends before the limit disarms the deadline.
//
// The deadline is a backstop and not a wait. No test waits for it, and no
// test uses it to order two events: each wait of the tests still ends by an
// event (the exit of the child, the end of a pipe, a change of a value). The
// deadline only keeps a child that never gives the event from holding the
// runner.

import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport

/// A child that was still running at its limit, and that the deadline killed.
struct ChildDeadlineExceeded: Error, CustomStringConvertible {
  /// The most characters of the stdout of the child that the description
  /// shows. The stdout of an agent is its ACP frames, and the last ones say
  /// what it did last.
  private static let standardOutputTailLength = 2_000

  /// The file name of the executable, with no argument: an argument can be a
  /// password.
  let command: String

  /// The limit the child passed.
  let limit: Duration

  /// The exit status of the child, or the signal that ended it. `nil` when
  /// the child had not ended when the failure was made.
  let terminationStatus: Int32?

  /// What the child wrote to its stdout.
  let standardOutput: String

  /// What the child wrote to its stderr.
  let standardError: String

  /// The command, the limit, and the output of the child.
  var description: String {
    let status = terminationStatus.map(String.init) ?? "not ended"
    return """
      \(command) was still running at its limit of \(limit), and was killed \
      (termination status: \(status)).
      stderr of the child:
      \(standardError)
      end of the stdout of the child:
      \(standardOutput.suffix(Self.standardOutputTailLength))
      """
  }
}

/// A timer that kills one child at its limit.
final class ChildDeadline: Sendable {
  /// The limit of a child when the caller gives none. The children of this
  /// package are stub agents and short tools, and the longest one needs
  /// seconds. A child that needs more than this is hung.
  static let standardLimit = Duration.seconds(120)

  /// How long the pipes of a killed child get to reach their end by
  /// themselves, before the deadline ends the reads. A process other than
  /// the child can hold a pipe open.
  private static let pipeGrace = Duration.seconds(1)

  /// The limit of the child.
  let limit: Duration

  /// The child.
  private let process: Process

  /// Whether the deadline killed the child.
  private let exceeded = WatchedValue(false)

  /// The timer.
  private let timer: Task<Void, Never>

  /// Arms the deadline. Call it after `process.run()`.
  ///
  /// - Parameters:
  ///   - process: The running child.
  ///   - limit: The time from now to the kill.
  ///   - afterGrace: What runs when the pipes of the killed child did not end
  ///     within their grace time, such as `PipeCapture.stop()`.
  init(
    process: Process, limit: Duration = standardLimit,
    afterGrace: @escaping @Sendable () -> Void = {}
  ) {
    self.process = process
    self.limit = limit
    let exceeded = exceeded
    timer = Task {
      do {
        try await Task.sleep(for: limit)
      } catch {
        // The sleep throws only when the caller disarmed the deadline.
        return
      }
      exceeded.update { $0 = true }
      Self.kill(process)
      do {
        try await Task.sleep(for: Self.pipeGrace)
      } catch {
        return
      }
      afterGrace()
    }
  }

  /// Whether the deadline killed the child.
  var hasExceeded: Bool { exceeded.value }

  /// Ends the timer: the child ended in time.
  func disarm() {
    timer.cancel()
  }

  /// Ends the timer and kills the child if it still runs: the caller gives up
  /// on the child, for example after an error or a cancel.
  func abandon() {
    timer.cancel()
    Self.kill(process)
  }

  /// The failure for a child that the deadline killed.
  ///
  /// - Parameters:
  ///   - standardOutput: What the child wrote to its stdout.
  ///   - standardError: What the child wrote to its stderr.
  /// - Returns: The failure.
  func failure(standardOutput: String, standardError: String) -> ChildDeadlineExceeded {
    ChildDeadlineExceeded(
      command: process.executableURL?.lastPathComponent ?? "child",
      limit: limit,
      // `terminationStatus` of a child that still runs raises an exception.
      terminationStatus: process.isRunning ? nil : process.terminationStatus,
      standardOutput: standardOutput,
      standardError: standardError)
  }

  /// Kills `process` with `SIGKILL`, only while the test process still owns
  /// it: an ended child has given its pid back, and the system may have
  /// handed the pid to another process.
  ///
  /// - Parameter process: The child.
  private static func kill(_ process: Process) {
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }
}
