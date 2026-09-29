import ArgumentParser
import Foundation
import Synchronization
import Testing

@testable import acp_agent

/// The `SIGTERM` end of the ACP serve window of `acp-agent acp`: the watch
/// closes the ACP connection, and the process ends with the code of an end
/// by a signal, through the exit path that flushes the telemetry.
///
/// **No case here arms a real signal.** `signal(SIGTERM, SIG_IGN)` changes
/// the disposition of the whole process, and this process is the test
/// runner. So each case gives the serve window a scripted watch, and the
/// spawned-binary suite of the nested package sends the real `SIGTERM` to a
/// real `acp-agent`.
struct TerminationHandlerTests {
    // MARK: - Constants

    /// The exit code a shell gives to a process that `SIGTERM` ended: 128
    /// and the signal number 15.
    private static let signalEndExitCode: Int32 = 143

    // MARK: - Fixtures

    /// Counts the closes of the ACP connection.
    private final class CloseCounter: Sendable {
        /// The number of closes so far.
        private let count = Mutex(0)

        /// Records one close.
        func recordClose() {
            count.withLock { $0 += 1 }
        }

        /// The number of closes so far.
        var closes: Int {
            count.withLock { $0 }
        }
    }

    /// Records whether the serve window disarmed its watch.
    private final class DisarmFlag: Sendable {
        /// `true` once the watch is disarmed.
        private let flag = Mutex(false)

        /// Records the disarm.
        func recordDisarm() {
            flag.withLock { $0 = true }
        }

        /// `true` once the watch is disarmed.
        var isDisarmed: Bool {
            flag.withLock { $0 }
        }
    }

    /// A watch that reports one `SIGTERM` at once.
    ///
    /// - Parameter disarmed: Records the disarm of the watch.
    /// - Returns: The installer of the watch.
    private static func oneArrival(disarmed: DisarmFlag) -> TerminationHandler.Installer {
        {
            let arrivals = AsyncStream<Void> { continuation in
                continuation.yield()
                continuation.finish()
            }
            return TerminationWatch(arrivals: arrivals, disarm: { disarmed.recordDisarm() })
        }
    }

    /// A watch that reports no `SIGTERM`: its stream stays open until the
    /// window disarms the watch.
    ///
    /// - Parameter disarmed: Records the disarm of the watch.
    /// - Returns: The installer of the watch.
    private static func noArrival(disarmed: DisarmFlag) -> TerminationHandler.Installer {
        {
            let (arrivals, continuation) = AsyncStream<Void>.makeStream()
            return TerminationWatch(
                arrivals: arrivals,
                disarm: {
                    disarmed.recordDisarm()
                    continuation.finish()
                })
        }
    }

    /// Makes an inbound end that never comes: the wait parks on a stream
    /// that stays open until its task is cancelled.
    ///
    /// - Returns: The wait, and the continuation that the test finishes at
    ///   its end.
    private static func neverEndingInbound() -> (
        wait: @Sendable () async -> Void, gate: AsyncStream<Never>.Continuation
    ) {
        let (stream, gate) = AsyncStream<Never>.makeStream()
        return ({ for await _ in stream {} }, gate)
    }

    // MARK: - The serve window

    /// A `SIGTERM` in the serve window closes the ACP connection, and then
    /// the window throws the exit code of an end by a signal. The code goes
    /// to ``AcpAgentCommand/main()``, whose failure path flushes the
    /// telemetry before the process exits.
    @Test(.timeLimit(.minutes(1)))
    func aTerminationClosesTheConnectionAndThrowsTheSignalEndCode() async throws {
        let closes = CloseCounter()
        let disarmed = DisarmFlag()
        let inbound = Self.neverEndingInbound()
        defer { inbound.gate.finish() }

        let thrown = await #expect(throws: ExitCode.self) {
            try await TerminationHandler.serve(
                untilInboundEnd: inbound.wait,
                closing: { closes.recordClose() },
                watchedBy: Self.oneArrival(disarmed: disarmed))
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
        #expect(closes.closes == 1)
        #expect(disarmed.isDisarmed)
    }

    /// The end of the inbound stream closes the ACP connection, and the
    /// window returns: the process ends on the normal return of `main()`.
    @Test(.timeLimit(.minutes(1)))
    func anInboundEndClosesTheConnectionAndReturns() async throws {
        let closes = CloseCounter()
        let disarmed = DisarmFlag()

        try await TerminationHandler.serve(
            untilInboundEnd: {},
            closing: { closes.recordClose() },
            watchedBy: Self.noArrival(disarmed: disarmed))

        #expect(closes.closes == 1)
        #expect(disarmed.isDisarmed)
    }

    /// The code of an end by `SIGTERM` is the shell's 143, and the exit
    /// path of `main()` keeps it, with nothing on stdout.
    @Test func theSignalEndCodeReachesTheExitOutcomeUnchanged() {
        let outcome = AcpAgentCommand.exitOutcome(for: TerminationHandler.signalEnd)

        #expect(
            outcome
                == AcpAgentCommand.ExitOutcome(code: Self.signalEndExitCode, writesToStandardError: true))
    }
}
