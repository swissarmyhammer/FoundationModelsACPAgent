import ArgumentParser
import Foundation
import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `SIGTERM` end of `acp-agent`: each watched window stops its work, and
/// the process ends with the code of an end by a signal, through the exit
/// path that flushes the telemetry.
///
/// The windows are the ACP serve window of `acp-agent acp`, which closes the
/// ACP connection, and the prompt window of `acp-agent run`, which sends
/// `session/cancel`. The composition window is ``CompositionInterruptTests``.
///
/// **No case here arms a real signal.** `signal(SIGTERM, SIG_IGN)` changes
/// the disposition of the whole process, and this process is the test
/// runner. So each case gives the window a scripted watch, and the
/// spawned-binary suite of the nested package sends the real `SIGTERM` to a
/// real `acp-agent`.
struct TerminationHandlerTests {
    // MARK: - Constants

    /// The exit code a shell gives to a process that `SIGTERM` ended: 128
    /// and the signal number 15.
    private static let signalEndExitCode: Int32 = 143

    /// The value the work of a window gives back when no `SIGTERM` arrives.
    private static let workValue = "the work ended"

    /// The text the scripted model streams before it holds, so a prompt
    /// that `SIGTERM` stopped has text that already arrived.
    private static let arrivedText = "working"

    /// The prompt of the prompt window case.
    private static let promptText = "write a haiku"

    /// The fact the prompt window case waits for before the `SIGTERM`, named
    /// in a timeout failure.
    private static let arrivalOrderLabel = "the first delta reached the answer descriptor"

    // MARK: - Fixtures

    /// Counts the calls of one reaction: the close of the ACP connection, or
    /// the stop of a window.
    private final class ReactionCounter: Sendable {
        /// The number of calls so far.
        private let calls = Mutex(0)

        /// Records one call.
        func record() {
            calls.withLock { $0 += 1 }
        }

        /// The number of calls so far.
        var count: Int {
            calls.withLock { $0 }
        }
    }

    /// Records whether the window disarmed its watch.
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
        let closes = ReactionCounter()
        let disarmed = DisarmFlag()
        let inbound = Self.neverEndingInbound()
        defer { inbound.gate.finish() }

        let thrown = await #expect(throws: ExitCode.self) {
            try await TerminationHandler.serve(
                untilInboundEnd: inbound.wait,
                closing: { closes.record() },
                watchedBy: Self.oneArrival(disarmed: disarmed))
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
        #expect(closes.count == 1)
        #expect(disarmed.isDisarmed)
    }

    /// The end of the inbound stream closes the ACP connection, and the
    /// window returns: the process ends on the normal return of `main()`.
    @Test(.timeLimit(.minutes(1)))
    func anInboundEndClosesTheConnectionAndReturns() async throws {
        let closes = ReactionCounter()
        let disarmed = DisarmFlag()

        try await TerminationHandler.serve(
            untilInboundEnd: {},
            closing: { closes.record() },
            watchedBy: Self.noArrival(disarmed: disarmed))

        #expect(closes.count == 1)
        #expect(disarmed.isDisarmed)
    }

    // MARK: - A watched window

    /// A `SIGTERM` in a watched window runs the stop of the window one time.
    /// The work ends because of the stop, and then the window throws the exit
    /// code of an end by a signal.
    @Test(.timeLimit(.minutes(1)))
    func aTerminationStopsTheWorkAndThrowsTheSignalEndCode() async throws {
        let stops = ReactionCounter()
        let disarmed = DisarmFlag()
        let (stopped, stopGate) = AsyncStream<Never>.makeStream()

        let thrown = await #expect(throws: ExitCode.self) {
            try await TerminationHandler.run(
                watchedBy: Self.oneArrival(disarmed: disarmed),
                stoppingWith: {
                    stops.record()
                    stopGate.finish()
                }
            ) {
                for await _ in stopped {}
            }
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
        #expect(stops.count == 1)
        #expect(disarmed.isDisarmed)
    }

    /// With no `SIGTERM`, a watched window gives back the value of its work,
    /// runs no stop, and disarms its watch.
    @Test(.timeLimit(.minutes(1)))
    func aWindowWithNoTerminationReturnsTheWorkValue() async throws {
        let stops = ReactionCounter()
        let disarmed = DisarmFlag()

        let value = try await TerminationHandler.run(
            watchedBy: Self.noArrival(disarmed: disarmed),
            stoppingWith: { stops.record() }
        ) {
            Self.workValue
        }

        #expect(value == Self.workValue)
        #expect(stops.count == 0)
        #expect(disarmed.isDisarmed)
    }

    // MARK: - The prompt window of `run`

    /// A `SIGTERM` during a `run` prompt sends `session/cancel`, as the first
    /// `Ctrl-C` does, and the run throws the exit code of an end by a signal.
    /// The text that already arrived stays on the answer descriptor.
    ///
    /// The scripted model streams one delta and then holds, so the prompt
    /// ends for one reason only: a `session/cancel` reached the agent.
    @Test(.timeLimit(.minutes(1)))
    func aTerminationDuringThePromptCancelsItAndThrowsTheSignalEndCode() async throws {
        let workspace = makeResolvedDirectory(label: "TerminationHandlerTests-prompt-repo")
        let composed = try await CLICompositionFixture.scripted(
            script: [.textDelta(Self.arrivedText), .hold], label: "TerminationHandlerTests-prompt")
        let capture = try AnswerCapture(label: "TerminationHandlerTests-prompt-answer")

        let thrown = await #expect(throws: ExitCode.self) {
            _ = try await RunPrompt.answer(
                of: composed,
                in: .new(workingDirectory: workspace),
                prompt: Self.promptText,
                into: capture.writer,
                terminatedBy: ScriptedTerminationWatch.armed(
                    waitingFor: Self.arrivalOrderLabel, after: capture.holds(Self.arrivedText)))
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
        #expect(try capture.text() == Self.arrivedText)
    }

    // MARK: - The exit code

    /// The code of an end by `SIGTERM` is the shell's 143, and the exit
    /// path of `main()` keeps it, with nothing on stdout.
    @Test func theSignalEndCodeReachesTheExitOutcomeUnchanged() {
        let outcome = AcpAgentCommand.exitOutcome(for: TerminationHandler.signalEnd)

        #expect(
            outcome
                == AcpAgentCommand.ExitOutcome(code: Self.signalEndExitCode, writesToStandardError: true))
    }
}
