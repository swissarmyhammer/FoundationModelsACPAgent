import Foundation
import Testing

// MARK: - The shared wait for a fact (plan.md §20.1)
//
// A case that must let production work happen before it asserts waits
// for the fact the production code makes true. It never sleeps for a
// guessed span: a sleep decides the result by the speed of the machine,
// and a full test run puts many suites on that machine together, so the
// span that is long enough alone is too short there.

/// The wait for a fact the production code makes true.
enum Poll {
    /// The number of seconds in ``pollDeadline``.
    private static let pollDeadlineSeconds = 30

    /// How long a polled condition may take before its case fails.
    private static let pollDeadline: Swift.Duration = .seconds(pollDeadlineSeconds)

    /// The number of milliseconds in ``pollInterval``.
    private static let pollIntervalMilliseconds = 50

    /// How long a poll sleeps between two reads.
    private static let pollInterval: Swift.Duration = .milliseconds(pollIntervalMilliseconds)

    /// Polls `condition` until it holds, or fails the case at the
    /// deadline.
    ///
    /// The loop reads the cancellation flag on each turn, so a caller
    /// that cancels the waiting task ends the wait at once and the task
    /// yields nothing after it.
    ///
    /// - Parameters:
    ///   - label: What the case waits for, for the failure message.
    ///   - condition: The condition to poll.
    ///   - sourceLocation: The line a timeout is reported at.
    /// - Throws: Whatever `condition` throws, and `CancellationError`
    ///   when the waiting task is cancelled.
    static func until(
        _ label: String,
        _ condition: () async throws -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + pollDeadline
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try await condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("timed out while waiting until \(label)", sourceLocation: sourceLocation)
    }
}
