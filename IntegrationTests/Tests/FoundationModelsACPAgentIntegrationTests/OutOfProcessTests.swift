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

    /// Records what one reading of the live process table saw.
    ///
    /// - Parameter identifiers: The identifiers of that reading.
    func record(_ identifiers: [pid_t]) {
        guardedIdentifiers.withLock { $0.append(contentsOf: identifiers) }
    }

    /// The identifiers recorded so far.
    var snapshot: [pid_t] {
        guardedIdentifiers.withLock { $0 }
    }
}

/// The `--out-of-process` contract of `acp-agent run`.
///
/// Serialized so at most one spawned turn of this suite runs at a time.
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
    /// turn fail after the child has started, which is the failing path the
    /// reap must also cover.
    private static let unknownSessionID = "no-session-carries-this-id"

    /// The prompt of the byte-identical case. The stub model echoes it, so
    /// the answer is deterministic and is not empty.
    private static let promptText = "the wire path gives one answer"

    /// The prompt of the cases that must hold a turn open. The stub model
    /// echoes it word by word, so eight words are eight chunks.
    private static let pacedPromptText = "one two three four five six seven eight"

    /// The pause between two chunks, in milliseconds. Eight chunks at this
    /// pause make a turn of about one and a half seconds, which is long
    /// enough to read the live process table inside it.
    private static let chunkDelayMilliseconds = 180

    /// How many agents one `--out-of-process` run starts: one.
    private static let expectedChildCount = 1

    /// The exit code of a run that reached the end of its turn (§5.8).
    private static let endTurnExitCode: Int32 = 0

    /// The exit code of an error (§5.8).
    private static let errorExitCode: Int32 = 1

    /// The exit code of a cancelled run (§5.8).
    private static let cancelledExitCode: Int32 = 4

    /// The number of seconds in ``firstOutputLimit``.
    private static let firstOutputLimitSeconds = 60

    /// How long a child may take to write its first stdout byte. It covers
    /// the process start of two binaries and the stub composition of the
    /// spawned one, which downloads nothing.
    private static let firstOutputLimit: Swift.Duration = .seconds(firstOutputLimitSeconds)

    /// The number of seconds in ``exitLimit``.
    private static let exitLimitSeconds = 30

    /// How long a child may take to end after its last signal. A cancelled
    /// turn ends in milliseconds, and the whole uninterrupted turn lasts
    /// under two seconds, so this bound is generous for both.
    private static let exitLimit: Swift.Duration = .seconds(exitLimitSeconds)

    /// The pause between two signals. One signal goes out here, so no pause
    /// is ever taken.
    private static let signalGap: Swift.Duration = .zero

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
        try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: arguments,
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: TierThreeFixture.stubModelEnvironment)
    }

    /// Runs the built `acp-agent` over the paced stub model, records the
    /// agents the run has started once its first answer bytes arrive, and
    /// sends `signalCount` interrupts.
    ///
    /// - Parameters:
    ///   - label: The directory label.
    ///   - signalCount: How many `SIGINT`s to send. Zero runs the turn to
    ///     its end.
    ///   - observed: Where the reading of the live run goes.
    /// - Returns: The finished run.
    /// - Throws: The wait, locator or spawn error.
    private static func runPacedAgentCLI(
        label: String, signalCount: Int, observed: ObservedAgents
    ) async throws -> SignalledExecutableRun {
        try await SignalledExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: [runSubcommand, outOfProcessFlag, pacedPromptText],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: TierThreeFixture.pacedStubModelEnvironment(
                chunkDelayMilliseconds: chunkDelayMilliseconds),
            atFirstOutput: { runIdentifier in
                observed.record(try ProcessCensus.agentsServingACP(startedBy: runIdentifier))
            },
            signalCount: signalCount,
            gap: signalGap,
            firstOutputLimit: firstOutputLimit,
            exitLimit: exitLimit)
    }

    // MARK: - The contract

    /// The two modes answer one prompt with the same bytes.
    ///
    /// The stub model makes that comparison possible at all, and it also
    /// makes it a proof of the pass-through: an out-of-process run whose
    /// child never saw `ACP_AGENT_STUB_MODEL` would resolve a real model and
    /// write other bytes.
    @Test(.timeLimit(.minutes(3)))
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
    /// The success row reads the run's own child while the turn streams,
    /// which is the one moment that child can be named, and then asks
    /// whether its whole process group is still alive. The other two rows
    /// never see the child, so each asks whether any agent has outlived the
    /// run that started it — an orphan, which is what a leak is.
    @Test(.timeLimit(.minutes(5)))
    func noProcessOfTheChildsGroupOutlivesTheRun() async throws {
        let observed = ObservedAgents()
        let completed = try await Self.runPacedAgentCLI(
            label: "OutOfProcess-success", signalCount: 0, observed: observed)
        #expect(completed.exitCode == Self.endTurnExitCode, "stderr: \(completed.standardError)")
        #expect(
            observed.snapshot.count == Self.expectedChildCount,
            "one run started \(observed.snapshot.count) agents: \(observed.snapshot)")
        let child = try #require(
            observed.snapshot.first,
            "no `acp-agent acp` child was alive while the run streamed its answer")
        #expect(
            !ProcessCensus.isProcessGroupAlive(leader: child),
            "a process of the child's group outlived the successful run")

        // The failing row. `--resume` names a session no listing carries, so
        // the turn fails after the child has started, and the reap of the
        // failing path is what this row reads.
        let failed = try await Self.runAgentCLI(
            arguments: [
                Self.runSubcommand, Self.outOfProcessFlag,
                Self.resumeOption, Self.unknownSessionID, Self.promptText,
            ],
            label: "OutOfProcess-failure")
        #expect(failed.exitCode == Self.errorExitCode, "stderr: \(failed.standardError)")
        #expect(failed.standardOutput.isEmpty, "a failed turn wrote to stdout")
        try ProcessCensus.expectNoAgentOutlivedItsRun()

        // The interrupted row. The first `Ctrl-C` sends `session/cancel` over
        // the real pipe, and the run ends itself with exit 4 (§5.9).
        let interrupted = try await Self.runPacedAgentCLI(
            label: "OutOfProcess-interrupt", signalCount: 1, observed: ObservedAgents())
        #expect(
            interrupted.exitCode == Self.cancelledExitCode,
            "stderr: \(interrupted.standardError)")
        try ProcessCensus.expectNoAgentOutlivedItsRun()
    }
}
