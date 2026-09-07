import ArgumentParser
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The exit codes of `acp-agent` (cli-plan.md §5.8): one code for every
/// stop reason of the wire, and one for every failure the CLI can end on.
///
/// "Nonzero" is not enough for a script, so ``AgentExitCode`` states the
/// whole table and every exit path reads it. This suite holds one case
/// per row, and drives the row through the scripted model wherever a stop
/// reason is what decides the code.
///
/// The `0` row has a second half — "a report that ran" — which the
/// reporting suites already hold: `ConfigPathTests` and `ConfigShowTests`
/// build a `CommandReport` and throw nothing, and a subcommand whose
/// `run()` returns exits 0.
///
/// The `5` row belongs to `doctor`, whose body is a stub until its own
/// card lands. The code is declared here so the card that writes the
/// checks has one place to read it from.
struct ExitCodeTests {
    // MARK: - Constants

    /// The prompt of every turn here.
    private static let promptText = "write a haiku"

    /// The text the scripted model streams before a turn that ends well.
    private static let answeredText = "a finished answer"

    /// The text the scripted model streams before it holds, so a
    /// cancelled turn has text that already arrived.
    private static let arrivedText = "part of an answer"

    /// The fact the cancelled row waits for before it interrupts, named
    /// in a timeout failure.
    private static let arrivalOrderLabel = "the first delta reached the answer descriptor"

    /// A project `config.yaml` whose key no section declares, so the
    /// start-up load fails and the run never reaches the wire.
    private static let misspelledKeyDocument = "recording:\n  levle: full\n"

    /// The message of the usage error the ArgumentParser row throws.
    private static let usageErrorMessage = "--cwd cannot be combined with --resume"

    /// The `timeout(1)` code. cli-plan.md §5.8 lists it for the client
    /// CLI, which has a `--timeout`; §5.4 gives `run` none, so no code
    /// path of this package can produce it and the table declares no row
    /// for it.
    private static let timeoutExitCode: Int32 = 124

    /// The number of rows the table states.
    private static let tableRowCount = 6

    /// The code of a turn that ended on `end_turn`, and of a report that
    /// ran.
    private static let successCode: Int32 = 0

    /// The code of an error: configuration, spawn, protocol, or I/O.
    private static let errorCode: Int32 = 1

    /// The code of a usage error.
    private static let usageCode: Int32 = 2

    /// The code of a turn that ended on `refusal`.
    private static let refusalCode: Int32 = 3

    /// The code of a turn that ended on `cancelled`.
    private static let cancelledCode: Int32 = 4

    /// The code of a `doctor` run that found warnings and no error.
    private static let doctorWarningsCode: Int32 = 5

    /// The directory that holds the CLI's source files, under the
    /// repository root.
    private static let commandSourceDirectory = "Sources/acp-agent"

    /// The file that holds the exit-code table.
    private static let tableFileName = "ExitCode.swift"

    /// The line that opens the stop-reason switch.
    private static let switchOpeningLine = "self = switch stopReason {"

    /// The line that closes the stop-reason switch.
    private static let switchClosingLine = "}"

    /// Every arm of the stop-reason switch, in source order.
    ///
    /// Six arms for the six cases the wire declares, and no `default`:
    /// that is what makes a seventh case upstream a build failure.
    private static let stopReasonSwitchArms = [
        "case .endTurn: .success",
        "case .refusal: .refusal",
        "case .cancelled: .cancelled",
        "case .maxTokens: .error",
        "case .maxTurnRequests: .error",
        "case .unknown: .error",
    ]

    // MARK: - Fixtures

    /// Runs one turn against a model that plays `script`, and gives back
    /// the exit code of the finished turn.
    ///
    /// - Parameters:
    ///   - script: The steps the model plays.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    ///   - arrivedText: The text that, once it has reached the answer
    ///     descriptor, offers one `Ctrl-C` to the turn. The default arms
    ///     no watch, so a row that needs no interrupt gets none.
    /// - Returns: The exit code of the finished turn.
    /// - Throws: Whatever the composition or the turn throws.
    private static func exitCode(
        ofTurnPlaying script: [ScriptedTurnStep],
        label: String,
        interruptedAfter arrivedText: String? = nil
    ) async throws -> AgentExitCode {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let composed = try await CLICompositionFixture.scripted(script: script, label: label)
        let capture = try AnswerCapture(label: "\(label)-answer")
        let install =
            arrivedText.map {
                ScriptedInterruptWatch.armed(
                    waitingFor: arrivalOrderLabel, after: capture.holds($0))
            } ?? InterruptHandler.unwatched
        let result = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: promptText,
            into: capture.writer,
            interruptedBy: install)
        return AgentExitCode(turn: result)
    }

    /// The arms of the stop-reason switch, read out of the shipped
    /// source.
    ///
    /// - Parameter source: The text of the file that holds the table.
    /// - Returns: The trimmed lines between the opening line and the
    ///   first closing line.
    /// - Throws: When `source` holds no such switch.
    private static func switchArms(of source: String) throws -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let opening = try #require(lines.firstIndex(of: switchOpeningLine))
        let body = lines[lines.index(after: opening)...]
        return Array(body.prefix { $0 != switchClosingLine })
    }

    // MARK: - The table (cli-plan.md §5.8)

    /// One code for each row of the six-row table, and no seventh row.
    @Test func theTableStatesOneCodeForEachRow() {
        #expect(AgentExitCode.success.rawValue == Self.successCode)
        #expect(AgentExitCode.error.rawValue == Self.errorCode)
        #expect(AgentExitCode.usage.rawValue == Self.usageCode)
        #expect(AgentExitCode.refusal.rawValue == Self.refusalCode)
        #expect(AgentExitCode.cancelled.rawValue == Self.cancelledCode)
        #expect(AgentExitCode.doctorWarnings.rawValue == Self.doctorWarningsCode)
        #expect(AgentExitCode.allCases.count == Self.tableRowCount)
    }

    /// The table declares no 124 row. `run` has no `--timeout`, so no
    /// code path of this package can time out, and a row nothing can
    /// produce would be a promise the binary cannot keep.
    @Test func theTableDeclaresNoTimeoutCode() {
        #expect(!AgentExitCode.allCases.contains { $0.rawValue == Self.timeoutExitCode })
    }

    // MARK: - The rows a stop reason decides

    /// A scripted `end_turn` exits 0.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedEndTurnExitsSuccess() async throws {
        let code = try await Self.exitCode(
            ofTurnPlaying: [.textDelta(Self.answeredText), .endTurn],
            label: "ExitCodeTests-end-turn")

        #expect(code == .success)
    }

    /// A scripted refusal exits 3. The model throws the guardrail
    /// violation, which the turn owner maps to the `refusal` stop reason.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedRefusalExitsRefusal() async throws {
        let code = try await Self.exitCode(
            ofTurnPlaying: [.fail(.guardrailViolation)],
            label: "ExitCodeTests-refusal")

        #expect(code == .refusal)
    }

    /// A scripted cancellation exits 4. The model streams one delta and
    /// then holds, and the watch offers its one arrival once that delta
    /// is on the answer descriptor, so the turn ends for one reason only.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedCancellationExitsCancelled() async throws {
        let code = try await Self.exitCode(
            ofTurnPlaying: [.textDelta(Self.arrivedText), .hold],
            label: "ExitCodeTests-cancelled",
            interruptedAfter: Self.arrivedText)

        #expect(code == .cancelled)
    }

    /// A turn whose wire ended before an idle update arrived exits 1. The
    /// turn has no outcome to report, and a script must not read that as
    /// a finished answer.
    @Test func aTurnWithNoStopReasonExitsError() {
        #expect(AgentExitCode(turn: RunTurnResult(stopReason: nil)) == .error)
    }

    // MARK: - The rows a failure decides

    /// A configuration that fails to load exits 1, with the reason on
    /// stderr and nothing on stdout.
    @Test(.timeLimit(.minutes(1)))
    func aConfigurationThatFailsToLoadExitsError() async throws {
        let fixture = ConfigCommandFixture(label: "ExitCodeTests-config")
        try fixture.writeProjectConfig(Self.misspelledKeyDocument)
        let capture = try AnswerCapture(label: "ExitCodeTests-config-answer")
        let run = try #require(
            try AcpAgentCommand.parseAsRoot(
                ["run", "--cwd", fixture.workspace.path, Self.promptText])
                as? AcpAgentCommand.Run)

        let error = try #require(
            await #expect(throws: (any Error).self) {
                _ = try await run.perform(
                    environment: fixture.stubEnvironment, into: capture.writer)
            })

        #expect(AcpAgentCommand.exitOutcome(for: error) == AcpAgentCommand.ExitOutcome(.error))
        #expect(!AcpAgentCommand.fullMessage(for: error).isEmpty)
        #expect(try capture.bytes().isEmpty)
    }

    /// The ArgumentParser usage error exits 2, and not the library's own
    /// `EX_USAGE`.
    @Test func theArgumentParserUsageErrorExitsUsage() {
        let error = ValidationError(Self.usageErrorMessage)

        #expect(AcpAgentCommand.exitOutcome(for: error) == AcpAgentCommand.ExitOutcome(.usage))
        #expect(ExitCode.validationFailure.rawValue != AgentExitCode.usage.rawValue)
    }

    // MARK: - The reason line never reaches stdout (cli-plan.md §5.6)

    /// Every nonzero exit puts its reason on stderr, so stdout carries
    /// the answer bytes and nothing else.
    @Test(arguments: AgentExitCode.allCases.filter { $0 != .success })
    func aNonzeroExitWritesItsReasonToStandardError(code: AgentExitCode) {
        let outcome = AcpAgentCommand.exitOutcome(for: code.parserError)

        #expect(outcome == AcpAgentCommand.ExitOutcome(code))
        #expect(outcome.writesToStandardError)
    }

    /// Exit 0 writes its text to stdout: `--help` and `--version` are the
    /// two that carry one, and neither is an error.
    @Test func aCleanExitWritesItsTextToStandardOutput() {
        #expect(!AcpAgentCommand.ExitOutcome(.success).writesToStandardError)
    }

    // MARK: - The switch is total (cli-plan.md §5.8)

    /// The stop-reason switch holds one arm per wire case and no
    /// `default`.
    ///
    /// **What this buys.** A `default` arm answers every case the wire
    /// gains later, so a new stop reason would exit 0 without a word. With
    /// no `default` the compiler refuses the file — "switch must be
    /// exhaustive" — and the build fails until somebody names the code of
    /// the new reason. That is a compile-time claim, and no call can read
    /// it back at run time: a `default` arm would leave the program
    /// running and every case answered. So the source itself is the
    /// assertion, in the shape ``InterruptTests`` uses for the signal
    /// handler body.
    @Test func theStopReasonSwitchHoldsOneArmPerWireCaseAndNoDefault() throws {
        let table = try PackageRoot.directory()
            .appendingPathComponent(Self.commandSourceDirectory, isDirectory: true)
            .appendingPathComponent(Self.tableFileName)

        let arms = try Self.switchArms(of: String(contentsOf: table, encoding: .utf8))

        #expect(arms == Self.stopReasonSwitchArms)
    }
}
