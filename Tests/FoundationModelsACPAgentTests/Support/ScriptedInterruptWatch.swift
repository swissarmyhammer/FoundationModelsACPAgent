import Foundation
import Testing

@testable import acp_agent

// MARK: - The scripted signal watches (cli-plan.md §5.9)
//
// No suite arms a real signal. `signal(SIGINT, SIG_IGN)` and
// `signal(SIGTERM, SIG_IGN)` change the disposition of the whole process, and
// this process is the test runner. So each case drives the production
// reaction through the watches below, and the spawned-binary suites of the
// nested package send the real signal to a real `acp-agent`.

/// One scripted arrival: a stream that gives one element after a gate opens,
/// and the disarm that ends the stream.
///
/// The `Ctrl-C` watch and the `SIGTERM` watch carry different elements, but a
/// scripted arrival has the same shape for both. So both watches use this one
/// builder.
enum ScriptedArrival {
    /// Makes a stream whose one element goes out only after `gate` returns.
    ///
    /// - Parameters:
    ///   - element: The element the stream gives.
    ///   - gate: What must end before the element goes out. When it throws,
    ///     the stream finishes with no element.
    /// - Returns: The stream, and the disarm that stops the wait and finishes
    ///   the stream.
    static func after<Element: Sendable>(
        _ gate: @escaping @Sendable () async throws -> Void, giving element: Element
    ) -> (arrivals: AsyncStream<Element>, disarm: @Sendable () -> Void) {
        let (arrivals, continuation) = AsyncStream<Element>.makeStream()
        let waiting = Task {
            try await gate()
            continuation.yield(element)
            continuation.finish()
        }
        return (
            arrivals,
            {
                waiting.cancel()
                continuation.finish()
            }
        )
    }

    /// A gate that opens once `fact` holds.
    ///
    /// A signal that lands before the prompt is running reaches an agent with
    /// no active prompt, and that agent ignores the cancel (plan.md §8.6). So
    /// the watch waits for a fact the running prompt made true, and order
    /// decides the result rather than a delay.
    ///
    /// - Parameters:
    ///   - label: What the gate waits for, named in a timeout failure.
    ///   - fact: What must hold before the gate opens.
    /// - Returns: The gate.
    static func once(
        _ label: String, holds fact: @escaping @Sendable () -> Bool
    ) -> @Sendable () async throws -> Void {
        { try await Poll.until(label) { fact() } }
    }
}

/// The `Ctrl-C` watch a case writes, in place of a real signal.
enum ScriptedInterruptWatch {
    /// An installer whose first arrival goes out only once `fact` holds.
    ///
    /// - Parameters:
    ///   - label: What the watch waits for, named in a timeout failure.
    ///   - fact: What must hold before the arrival goes out.
    /// - Returns: The installer of that watch.
    static func armed(
        waitingFor label: String, after fact: @escaping @Sendable () -> Bool
    ) -> InterruptHandler.Installer {
        {
            let arrival = ScriptedArrival.after(
                ScriptedArrival.once(label, holds: fact), giving: InterruptHandler.firstArrival)
            return InterruptWatch(arrivals: arrival.arrivals, disarm: arrival.disarm)
        }
    }
}

/// The `SIGTERM` watch a case writes, in place of a real signal.
enum ScriptedTerminationWatch {
    /// An installer whose one arrival goes out only after `gate` returns.
    ///
    /// - Parameter gate: What must end before the arrival goes out.
    /// - Returns: The installer of that watch.
    static func armed(
        after gate: @escaping @Sendable () async throws -> Void
    ) -> TerminationHandler.Installer {
        {
            let arrival = ScriptedArrival.after(gate, giving: ())
            return TerminationWatch(arrivals: arrival.arrivals, disarm: arrival.disarm)
        }
    }

    /// An installer whose one arrival goes out only once `fact` holds.
    ///
    /// - Parameters:
    ///   - label: What the watch waits for, named in a timeout failure.
    ///   - fact: What must hold before the arrival goes out.
    /// - Returns: The installer of that watch.
    static func armed(
        waitingFor label: String, after fact: @escaping @Sendable () -> Bool
    ) -> TerminationHandler.Installer {
        armed(after: ScriptedArrival.once(label, holds: fact))
    }
}
