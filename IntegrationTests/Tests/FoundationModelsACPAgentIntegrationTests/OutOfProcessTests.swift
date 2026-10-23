import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

// MARK: - Tier 3: `--out-of-process` (cli-plan.md §5.4, §9)
//
// The suite that runs the built `acp-agent run --out-of-process` as a
// subprocess and reads what the process itself did. The CLI reaches the
// agent through an ACP connection in every mode, and only the transport
// changes (cli-plan.md §4), so the claim is that the answer does not change
// with the transport, and that the second copy of the binary never outlives
// the run that started it.
//
// Every run here carries `ACP_AGENT_STUB_MODEL=1`. Two processes running a
// real model do not write the same bytes, because sampling is not
// reproducible, so the comparison of this suite cannot be written without
// the deterministic echo model. The switch reaches the spawned child by
// inheritance — the client package gives each agent this process's own
// environment — and the byte-identical case is the proof that it arrived.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The `acp-agent acp` children one live run started, shared between the
/// case and the probe closure the runner calls inside the run.
///
/// A class, because `Mutex` is noncopyable: the probe closure captures this
/// reference, not the lock itself.
private final class ObservedAgents: Sendable {
    /// The identifiers seen so far, guarded for the reader against the
    /// probe's writes.
    private let guardedIdentifiers = Mutex([pid_t]())

    /// The exit events of the processes of each recorded child's group,
    /// armed while the child was alive.
    private let guardedGroupExits = Mutex([ArmedProcessExit]())

    /// Records what one reading of the live process table saw, and arms the
    /// exit event of each process of each child's group. The probe runs
    /// while the gate holds the prompt, so each child is alive.
    ///
    /// - Parameter identifiers: The identifiers of that reading.
    /// - Throws: The run error of `pgrep`.
    func record(_ identifiers: [pid_t]) async throws {
        var exits: [ArmedProcessExit] = []
        for child in identifiers {
            let members = try await ProcessCensus.identifiers(selectedBy: ["-g", String(child)])
            for member in Set(members + [child]) {
                exits.append(ArmedProcessExit(pid: member))
            }
        }
        guardedIdentifiers.withLock { $0.append(contentsOf: identifiers) }
        guardedGroupExits.withLock { $0.append(contentsOf: exits) }
    }

    /// The identifiers recorded so far.
    var snapshot: [pid_t] {
        guardedIdentifiers.withLock { $0 }
    }

    /// Waits until each process of each recorded child's group exited. The
    /// end of the waits is the result. A process that does not exit holds
    /// the test, and a hang is the failure.
    ///
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
    func waitForEachGroupProcessExit() async throws {
        for exit in guardedGroupExits.withLock({ $0 }) {
            try await exit.wait()
        }
    }
}

/// The `--out-of-process` contract of `acp-agent run`.
///
/// Serialized so at most one spawned prompt of this suite runs at a time.
@Suite(.serialized)
struct OutOfProcessTests {
    // MARK: - Constants

    /// The `run` subcommand, written out. A prompt word can be a subcommand
    /// name, so a script always names the mode (cli-plan.md §5.3).
    private static let runSubcommand = "run"

    /// The flag under test (cli-plan.md §5.4).
    private static let outOfProcessFlag = "--out-of-process"

    /// The option that continues a recorded session (cli-plan.md §5.4).
    private static let resumeOption = "--resume"

    /// A session id no recorded session carries. `--resume` on it makes the
    /// prompt fail after the child has started, which is the failing path the
    /// reap must also cover.
    private static let unknownSessionID = "no-session-carries-this-id"

    /// The prompt of the byte-identical case. The stub model echoes it, so
    /// the answer is deterministic and is not empty.
    private static let promptText = "the wire path gives one answer"

    /// The text of the cases that must hold a prompt open. The stub model
    /// echoes it word by word, so eight words are eight chunks.
    private static let gatedPromptText = "one two three four five six seven eight"

    /// How many agents one `--out-of-process` run starts: one.
    private static let expectedChildCount = 1

    /// The exit code of a run that reached the end of its prompt (§5.8).
    private static let endTurnExitCode: Int32 = 0

    /// The exit code of an error (§5.8).
    private static let errorExitCode: Int32 = 1

    /// The exit code of a cancelled run (§5.8).
    private static let cancelledExitCode: Int32 = 4

    // MARK: - The subprocess drivers

    /// Runs the built `acp-agent` with `arguments` over the stub model, in
    /// fresh directories.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-agent`.
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runAgentCLI(
        arguments: [String], label: String
    ) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.runAgent(
            arguments: arguments, label: label,
            environment: TierThreeFixture.stubModelEnvironment)
    }

    /// Runs the built `acp-agent` over the gated stub model, records the
    /// agents the run has started once its first answer bytes arrive, and
    /// sends `signalCount` interrupts. The gate holds the prompt after its
    /// first chunk, so the live process table is read inside the prompt.
    ///
    /// - Parameters:
    ///   - label: The directory label.
    ///   - signalCount: How many `SIGINT`s to send. Zero runs the prompt to
    ///     its end.
    ///   - observed: Where the reading of the live run goes.
    /// - Returns: The finished run.
    /// - Throws: The wait, locator or spawn error.
    private static func runGatedAgentCLI(
        label: String, signalCount: Int, observed: ObservedAgents
    ) async throws -> SignalledExecutableRun {
        let gated = try TierThreeFixture.gatedStubModel(label: label)
        return try await SignalledExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: [runSubcommand, outOfProcessFlag, gatedPromptText],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: gated.environment,
            atFirstOutput: { runIdentifier in
                try await observed.record(ProcessCensus.agentsServingACP(startedBy: runIdentifier))
            },
            signalCount: signalCount,
            chunkGate: gated.gate)
    }

    // MARK: - The contract

    /// The two modes answer one prompt with the same bytes.
    ///
    /// The stub model makes that comparison possible at all, and it also
    /// makes it a proof of the pass-through: an out-of-process run whose
    /// child never saw `ACP_AGENT_STUB_MODEL` would resolve a real model and
    /// write other bytes.
    @Test
    func theTwoModesAnswerOnePromptWithTheSameBytes() async throws {
        let inProcess = try await Self.runAgentCLI(
            arguments: [Self.runSubcommand, Self.promptText],
            label: "OutOfProcess-in-process")
        let outOfProcess = try await Self.runAgentCLI(
            arguments: [Self.runSubcommand, Self.outOfProcessFlag, Self.promptText],
            label: "OutOfProcess-out-of-process")

        #expect(inProcess.exitCode == Self.endTurnExitCode, "stderr: \(inProcess.standardError)")
        #expect(
            outOfProcess.exitCode == Self.endTurnExitCode,
            "stderr: \(outOfProcess.standardError)")
        #expect(!inProcess.standardOutput.isEmpty, "the in-process run wrote no answer")
        #expect(
            outOfProcess.standardOutput == inProcess.standardOutput,
            "out of process: \(outOfProcess.standardOutput)")
    }

    /// No process of the child's process group outlives the run, in each of
    /// success, failure and interrupt.
    ///
    /// The success row reads the run's own child while the prompt streams,
    /// which is the one moment that child can be named. Then it arms the
    /// exit event of each process of the child's group, and after the run it
    /// waits for each of those events. The other two rows
    /// never see the child, so each asks whether any agent has outlived the
    /// run that started it — an orphan, which is what a leak is.
    @Test
    func noProcessOfTheChildsGroupOutlivesTheRun() async throws {
        let observed = ObservedAgents()
        let completed = try await Self.runGatedAgentCLI(
            label: "OutOfProcess-success", signalCount: 0, observed: observed)
        #expect(completed.exitCode == Self.endTurnExitCode, "stderr: \(completed.standardError)")
        #expect(
            observed.snapshot.count == Self.expectedChildCount,
            "one run started \(observed.snapshot.count) agents: \(observed.snapshot)")
        _ = try #require(
            observed.snapshot.first,
            "no `acp-agent acp` child was alive while the run streamed its answer")
        // Each process of the child's group sent its exit event. No read of
        // the pids follows the run: after the reap, the system can give a
        // pid to a new process.
        try await observed.waitForEachGroupProcessExit()

        // The failing row. `--resume` names a session no listing carries, so
        // the prompt fails after the child has started, and the reap of the
        // failing path is what this row reads.
        let failed = try await Self.runAgentCLI(
            arguments: [
                Self.runSubcommand, Self.outOfProcessFlag,
                Self.resumeOption, Self.unknownSessionID, Self.promptText,
            ],
            label: "OutOfProcess-failure")
        #expect(failed.exitCode == Self.errorExitCode, "stderr: \(failed.standardError)")
        #expect(failed.standardOutput.isEmpty, "a failed prompt wrote to stdout")
        try await ProcessCensus.expectNoAgentOutlivedItsRun()

        // The interrupted row. The first `Ctrl-C` sends `session/cancel` over
        // the real pipe, and the run ends itself with exit 4 (§5.9).
        let interrupted = try await Self.runGatedAgentCLI(
            label: "OutOfProcess-interrupt", signalCount: 1, observed: ObservedAgents())
        #expect(
            interrupted.exitCode == Self.cancelledExitCode,
            "stderr: \(interrupted.standardError)")
        try await ProcessCensus.expectNoAgentOutlivedItsRun()
    }
}
