import Foundation
import Testing

@testable import acp_agent

// MARK: - The scripted `Ctrl-C` watch (cli-plan.md §5.9)
//
// No suite arms a real signal. `signal(SIGINT, SIG_IGN)` changes the
// disposition of the whole process, and this process is the test runner.
// So each case drives the production reaction through the watch below,
// and the spawned-binary suite of the nested package sends the real
// `SIGINT` to a real `acp-agent`.

/// The `Ctrl-C` watch a case writes, in place of a real signal.
enum ScriptedInterruptWatch {
    /// An installer whose first arrival goes out only once `fact` holds.
    ///
    /// A cancel that lands before the turn is running reaches an agent
    /// with no active turn, and that agent ignores it (plan.md §8.6).
    /// So the watch waits for a fact the running turn made true, and
    /// order decides the result rather than a delay.
    ///
    /// - Parameters:
    ///   - label: What the watch waits for, named in a timeout failure.
    ///   - fact: What must hold before the arrival goes out.
    /// - Returns: The installer of that watch.
    static func armed(
        waitingFor label: String, after fact: @escaping @Sendable () -> Bool
    ) -> InterruptHandler.Installer {
        {
            let (arrivals, continuation) = AsyncStream<Int>.makeStream()
            let waiting = Task {
                try await Poll.until(label) { fact() }
                continuation.yield(InterruptHandler.firstArrival)
                continuation.finish()
            }
            return InterruptWatch(
                arrivals: arrivals,
                disarm: {
                    waiting.cancel()
                    continuation.finish()
                })
        }
    }
}
