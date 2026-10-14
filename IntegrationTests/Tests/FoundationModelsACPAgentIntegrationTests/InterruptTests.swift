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
// weights, and `ACP_AGENT_STUB_CHUNK_GATE` holds its prompt open until the
// signal landed inside it, with no clock.

/// The `SIGINT` contract of a running `acp-agent run`.
struct InterruptTests {
    // MARK: - Constants

    /// The exit code of a cancelled run (cli-plan.md §5.8).
    private static let cancelledExitCode: Int32 = 4

    /// The exit code of a run that reached the end of its prompt.
    private static let endTurnExitCode: Int32 = 0

    /// The text of every prompt here. The stub model echoes it word by
    /// word, so the words are the chunks, and eight chunks give a prompt
    /// with room for a signal in the middle of it.
    private static let prompt = "one two three four five six seven eight"

    // MARK: - The subprocess driver

    /// Runs `acp-agent run <prompt>` over the gated stub model, and
    /// sends `signalCount` interrupts once its first answer bytes
    /// arrive. The gate holds the prompt after its first chunk, so each
    /// signal lands inside the prompt.
    ///
    /// - Parameters:
    ///   - signalCount: How many `SIGINT`s to send. Zero runs the prompt
    ///     to its end, which gives the answer an interrupted run is
    ///     compared against.
    ///   - label: The directory label, so a leftover directory says
    ///     where it came from.
    /// - Returns: The finished run.
    /// - Throws: The wait, locator or spawn error.
    private static func runAgentCLI(
        signalCount: Int, label: String
    ) async throws -> SignalledExecutableRun {
        let gated = try TierThreeFixture.gatedStubModel(label: label)
        return try await SignalledExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: ["run", Self.prompt],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: gated.environment,
            signalCount: signalCount,
            chunkGate: gated.gate)
    }

    // MARK: - The contract

    /// A `SIGINT` during a prompt does not kill the process. The run ends
    /// itself with exit 4, and the text that already arrived stays on
    /// stdout.
    ///
    /// A killed process would carry a signal status and would never
    /// reach an exit code of the §5.8 table. So the 4 is the proof that
    /// the CLI answered the signal: it sent `session/cancel`, the prompt
    /// ended `cancelled`, and the run mapped that to its code.
    ///
    /// The uninterrupted run of the same prompt is the yardstick for the
    /// text. The interrupted answer must be a **strict** prefix of it:
    /// not empty, so the chunks that arrived were kept; and not the
    /// whole answer, so the prompt really stopped early.
    @Test
    func aSignalDuringAPromptExitsFourWithTheTextThatArrived() async throws {
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
            "the whole answer arrived, so the prompt never stopped early")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }

    /// Two `SIGINT`s, back to back, end the process on the cancelled exit
    /// code and with nothing on stderr.
    ///
    /// The runner waits for the exit event of the child, with no clock: a
    /// child that does not end holds the test, and a sample of the test
    /// process shows where it waits.
    ///
    /// **What this case does and does not prove.** Both signals reach a
    /// live child, so the second-signal path is exercised, and the case
    /// proves that a second `Ctrl-C` never wedges the process and never
    /// changes the outcome a script reads. It does not prove that the
    /// second signal is the only way out: this runtime ends a cancelled
    /// stream at its consumer, so the first signal already ends this
    /// prompt, and no spawned prompt of the stub model can be made to ignore
    /// a cancellation.
    @Test
    func twoSignalsEndTheProcess() async throws {
        let run = try await Self.runAgentCLI(signalCount: 2, label: "InterruptTests-second")

        #expect(run.exitCode == Self.cancelledExitCode, "stderr: \(run.standardError)")
        #expect(run.signalsSent == 2, "only \(run.signalsSent) signal(s) reached the child")
        #expect(run.standardError.isEmpty, "stderr: \(run.standardError)")
    }
}
