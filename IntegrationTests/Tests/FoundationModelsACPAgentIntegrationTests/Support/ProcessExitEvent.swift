import Foundation
import FoundationModelsACPAgentTestSupport

/// The exit event of a child process.
///
/// It sets the `terminationHandler` of the process, so it must be made before
/// `run()`: a handler set after the exit never runs. The wait then ends at
/// the exit, with no clock and no poll.
final class ProcessExitEvent: Sendable {
    /// Whether the child exited, with its waits.
    private let exited = WatchedValue(false)

    /// Watches `process`. Call it before `process.run()`.
    ///
    /// - Parameter process: The child to watch.
    init(watching process: Process) {
        let exited = exited
        process.terminationHandler = { _ in
            exited.update { $0 = true }
        }
    }

    /// Waits until the child exited.
    ///
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
    func wait() async throws {
        _ = try await exited.wait(for: "the exit of the child") { $0 }
    }
}
