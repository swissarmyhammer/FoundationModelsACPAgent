import Foundation
import Testing

@testable import acp_agent

/// The deadline of the telemetry shutdown of `acp-agent`.
///
/// A flush can wait on the network, and a collector that does not answer
/// must not hold the process. So the shutdown waits for the end of the
/// telemetry service for a fixed time, and then goes on.
///
/// **No case here bootstraps the telemetry.** swift-log permits one
/// bootstrap for each process, and this process is the test runner. So each
/// case gives the deadline wait a task of its own, and the spawned-binary
/// suite of the nested package proves the flush of a real `acp-agent`.
struct TelemetryShutdownTests {
    // MARK: - Constants

    /// The number of milliseconds in ``shortDeadline``.
    private static let shortDeadlineMilliseconds = 100

    /// A deadline that a test can wait for.
    private static let shortDeadline: Duration = .milliseconds(shortDeadlineMilliseconds)

    /// The number of seconds in ``waitBound``.
    private static let waitBoundSeconds = 5

    /// The longest time a wait with ``shortDeadline`` may take. A wait that
    /// does not stop at its deadline goes past it.
    private static let waitBound: Duration = .seconds(waitBoundSeconds)

    /// The number of seconds of the shutdown deadline of the card.
    private static let shutdownDeadlineSeconds = 2

    // MARK: - The deadline wait

    /// A task that does not end holds the wait only until the deadline, and
    /// the wait then reports that the task did not end.
    @Test(.timeLimit(.minutes(1)))
    func aTaskThatDoesNotEndHoldsTheWaitOnlyUntilTheDeadline() async {
        let (gate, open) = AsyncStream<Never>.makeStream()
        let service = Task { for await _ in gate {} }
        defer { open.finish() }
        let clock = ContinuousClock()
        let start = clock.now

        let ended = await TelemetryBootstrap.waitForEnd(of: service, within: Self.shortDeadline)

        let elapsed = clock.now - start
        #expect(!ended)
        #expect(elapsed >= Self.shortDeadline, "the wait ended before its deadline")
        #expect(elapsed < Self.waitBound, "the wait took \(elapsed)")
    }

    /// A task that ends releases the wait at once, and the wait reports the
    /// end.
    @Test(.timeLimit(.minutes(1)))
    func aTaskThatEndsReleasesTheWait() async {
        let service = Task {}

        let ended = await TelemetryBootstrap.waitForEnd(of: service, within: Self.waitBound)

        #expect(ended)
    }

    /// The shutdown waits for the telemetry service for 2 seconds at most.
    @Test func theShutdownDeadlineIsTwoSeconds() {
        #expect(TelemetryBootstrap.shutdownDeadline == .seconds(Self.shutdownDeadlineSeconds))
    }
}
