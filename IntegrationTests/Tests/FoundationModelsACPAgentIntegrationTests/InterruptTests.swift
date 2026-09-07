import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - Tier 3: the interrupt of the agent CLI (cli-plan.md §5.9, §9)
//
// The suite that sends a real `SIGINT` to a real `acp-agent`, and reads
// what the process did. The in-process suite of the root package proves
// the reaction — the `session/cancel`, the stop reason, the exit code —
// against a scripted watch. Only a spawned binary can prove that a
// keyboard interrupt reaches that reaction at all, and that the process
// does not simply die of the signal.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.
//
// `ACP_AGENT_STUB_MODEL=1` makes the child deterministic and needs no
// weights, and `ACP_AGENT_STUB_CHUNK_DELAY_MS` holds its turn open long
// enough for the signal to land inside it.

/// The `SIGINT` contract of a running `acp-agent run`.
struct InterruptTests {
    // MARK: - Constants

    /// The exit code of a cancelled run (cli-plan.md §5.8).
    private static let cancelledExitCode: Int32 = 4

    /// The exit code of a run that reached the end of its turn.
    private static let endTurnExitCode: Int32 = 0

    /// The prompt of every turn here. The stub model echoes it word by
    /// word, so the words are the chunks, and eight chunks give a turn
    /// with room for a signal in the middle of it.
    private static let prompt = "one two three four five six seven eight"

    /// The pause between two chunks, in milliseconds. Eight chunks at
    /// this pause make a turn of about one and a half seconds.
    private static let chunkDelayMilliseconds = 180

    /// The pause between the two signals of the second case: none. The
    /// two `SIGINT`s go out back to back, so both reach a child that is
    /// still alive. A pause wide enough to be worth naming would let the
    /// first signal end the run, and the second would then have nothing
    /// to reach.
    private static let signalGap: Swift.Duration = .zero

    /// The number of seconds in ``firstOutputLimit``.
    private static let firstOutputLimitSeconds = 60

    /// How long a child may take to write its first stdout byte. It
    /// covers the process start and the stub composition, which
    /// downloads nothing.
    private static let firstOutputLimit: Swift.Duration = .seconds(firstOutputLimitSeconds)

    /// The number of seconds in ``exitLimit``.
    private static let exitLimitSeconds = 30

    /// How long a child may take to end after its last signal. A
    /// cancelled turn ends in milliseconds, and the whole uninterrupted
    /// turn lasts under two seconds, so this bound is generous for both.
    private static let exitLimit: Swift.Duration = .seconds(exitLimitSeconds)

    // MARK: - The subprocess driver

    /// Runs `acp-agent run <prompt>` over the paced stub model, and
    /// sends `signalCount` interrupts once its first answer bytes
    /// arrive.
    ///
    /// - Parameters:
    ///   - signalCount: How many `SIGINT`s to send. Zero runs the turn
    ///     to its end, which gives the answer an interrupted run is
    ///     compared against.
    ///   - label: The directory label, so a leftover directory says
    ///     where it came from.
    /// - Returns: The finished run.
    /// - Throws: The wait, locator or spawn error.
    private static func runAgentCLI(
        signalCount: Int, label: String
    ) async throws -> SignalledExecutableRun {
        try await SignalledExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: ["run", Self.prompt],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: [
                TierThreeFixture.stubModelVariable: TierThreeFixture.stubModelEnabledValue,
                TierThreeFixture.stubChunkDelayVariable: String(Self.chunkDelayMilliseconds),
            ],
            signalCount: signalCount,
            gap: Self.signalGap,
            firstOutputLimit: Self.firstOutputLimit,
            exitLimit: Self.exitLimit)
    }

    // MARK: - The contract

    /// A `SIGINT` during a turn does not kill the process. The run ends
    /// itself with exit 4, and the text that already arrived stays on
    /// stdout.
    ///
    /// A killed process would carry a signal status and would never
    /// reach an exit code of the §5.8 table. So the 4 is the proof that
    /// the CLI answered the signal: it sent `session/cancel`, the turn
    /// ended `cancelled`, and the run mapped that to its code.
    ///
    /// The uninterrupted run of the same prompt is the yardstick for the
    /// text. The interrupted answer must be a **strict** prefix of it:
    /// not empty, so the chunks that arrived were kept; and not the
    /// whole answer, so the turn really stopped early.
    @Test(.timeLimit(.minutes(3)))
    func aSignalDuringATurnExitsFourWithTheTextThatArrived() async throws {
        let whole = try await Self.runAgentCLI(signalCount: 0, label: "InterruptTests-whole")
        #expect(whole.exitCode == Self.endTurnExitCode, "stderr: \(whole.standardError)")

        let run = try await Self.runAgentCLI(signalCount: 1, label: "InterruptTests-first")

        #expect(run.exitCode == Self.cancelledExitCode, "stderr: \(run.standardError)")
        #expect(!run.standardOutput.isEmpty, "no answer text reached stdout")
        #expect(
            whole.standardOutput.hasPrefix(run.standardOutput),
            "the interrupted answer is not a prefix of the whole one: \(run.standardOutput)")
        #expect(
            run.standardOutput != whole.standardOutput,
            "the whole answer arrived, so the turn never stopped early")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }

    /// Two `SIGINT`s end the process inside ``exitLimit``, on the
    /// cancelled exit code and with nothing on stderr.
    ///
    /// The time limit is the runner's, not an assertion here: a child
    /// that outlives ``exitLimit`` raises `SignalledRunError`, which
    /// names the limit it passed.
    ///
    /// **What this case does and does not prove.** Both signals reach a
    /// live child, so the second-signal path is exercised, and the case
    /// proves that a second `Ctrl-C` never wedges the process and never
    /// changes the outcome a script reads. It does not prove that the
    /// second signal is the only way out: this runtime ends a cancelled
    /// stream at its consumer, so the first signal already ends this
    /// turn, and no spawned turn of the stub model can be made to ignore
    /// a cancellation.
    @Test(.timeLimit(.minutes(3)))
    func twoSignalsEndTheProcessInsideTheTimeLimit() async throws {
        let run = try await Self.runAgentCLI(signalCount: 2, label: "InterruptTests-second")

        #expect(run.exitCode == Self.cancelledExitCode, "stderr: \(run.standardError)")
        #expect(run.signalsSent == 2, "only \(run.signalsSent) signal(s) reached the child")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }
}
