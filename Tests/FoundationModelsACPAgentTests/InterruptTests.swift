import ArgumentParser
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The interrupt of one `run` turn (cli-plan.md §5.9): `Ctrl-C` sends
/// `session/cancel`, the turn ends `cancelled`, the text that already
/// arrived stays on the answer descriptor, and the run exits 4.
///
/// **No case here arms a real signal.** `signal(SIGINT, SIG_IGN)` changes
/// the disposition of the whole process, and this process is the test
/// runner. So each case drives the production reaction through a scripted
/// watch, and the spawned-binary suite of the nested package sends the
/// real `SIGINT` to a real `acp-agent`.
///
/// The scope of this suite is the turn, and only the turn. The other
/// window of §5.9 — a `Ctrl-C` during a model download, before the wire
/// opens — is ``CompositionInterruptTests``.
struct InterruptTests {
    // MARK: - Constants

    /// The text the scripted model streams before it holds, so a
    /// cancelled turn has text that already arrived.
    private static let arrivedText = "working"

    /// The prompt of every turn here.
    private static let promptText = "write a haiku"

    /// The number of milliseconds in ``arrivalInterval``.
    private static let arrivalIntervalMilliseconds = 50

    /// The pause between two repeats of the scripted first arrival.
    private static let arrivalInterval: Swift.Duration = .milliseconds(arrivalIntervalMilliseconds)

    /// The wire method of the cancel notification, as
    /// `MethodTable.generated.swift` spells it.
    private static let cancelWireMethod = "session/cancel"

    /// The directory that holds the CLI's source files, under the
    /// repository root.
    private static let commandSourceDirectory = "Sources/acp-agent"

    /// The file that holds the signal source.
    private static let handlerFileName = "InterruptHandler.swift"

    /// The line that opens the signal handler body.
    private static let handlerOpeningLine = "source.setEventHandler {"

    /// The line that closes the signal handler body.
    private static let handlerClosingLine = "}"

    /// The whole body of the signal handler: one atomic add, and one
    /// resume of the continuation the waiting task is parked on. A
    /// handler that called anything else would not be async-signal-safe.
    private static let handlerStatements = [
        "let ordinal = state.count.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue",
        "state.arrivals.yield(ordinal)",
    ]

    // MARK: - Fixtures

    /// A watch that repeats the first arrival until it is disarmed.
    ///
    /// A cancel that lands before the turn is running reaches an agent
    /// with no active turn, and that agent ignores it (plan.md §8.6). So
    /// the scripted watch keeps offering the first arrival, and no run of
    /// this suite depends on the turn having started at a fixed moment.
    /// A cancel of a turn that already ended is a no-op, so the repeat
    /// costs nothing.
    ///
    /// - Returns: The installer of the repeating watch.
    private static func repeatingFirstArrival() -> InterruptHandler.Installer {
        {
            let (arrivals, continuation) = AsyncStream<Int>.makeStream()
            let ticker = Task {
                while !Task.isCancelled {
                    continuation.yield(InterruptHandler.firstArrival)
                    try? await Task.sleep(for: Self.arrivalInterval)
                }
            }
            return InterruptWatch(
                arrivals: arrivals,
                disarm: {
                    ticker.cancel()
                    continuation.finish()
                })
        }
    }

    /// A stream of exactly one first arrival.
    ///
    /// - Returns: The stream, already finished after the one value.
    private static func oneArrival() -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.yield(InterruptHandler.firstArrival)
            continuation.finish()
        }
    }

    /// The statements of the signal handler body in `source`.
    ///
    /// - Parameter source: The text of the file that holds the handler.
    /// - Returns: The trimmed statements between the opening line and the
    ///   first closing line.
    /// - Throws: When `source` holds no handler.
    private static func handlerBody(of source: String) throws -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let opening = try #require(lines.firstIndex(of: handlerOpeningLine))
        let body = lines[lines.index(after: opening)...]
        return Array(body.prefix { $0 != handlerClosingLine })
    }

    // MARK: - The first signal (cli-plan.md §5.9)

    /// The first interrupt cancels the running turn, and the text that
    /// already arrived stays on the answer descriptor.
    ///
    /// The scripted model streams one delta and then holds, so the turn
    /// ends for one reason only: a `session/cancel` reached the agent.
    @Test(.timeLimit(.minutes(1)))
    func aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived() async throws {
        let workspace = makeResolvedDirectory(label: "InterruptTests-first-repo")
        let composed = try await CLICompositionFixture.scripted(
            script: [.textDelta(Self.arrivedText), .hold], label: "InterruptTests-first")
        let capture = try AnswerCapture(label: "InterruptTests-first-answer")

        let result = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: Self.promptText,
            into: capture.writer,
            interruptedBy: Self.repeatingFirstArrival())

        #expect(result.stopReason == .cancelled)
        #expect(try capture.text() == Self.arrivedText)
    }

    /// The reaction puts a `session/cancel` on the wire, and the agent
    /// end receives it.
    ///
    /// The tap stands on the agent end, so its lines are the ones the
    /// client sent. That is the direct reading of the claim: a
    /// `session/cancel` reached the agent before the run ended.
    @Test(.timeLimit(.minutes(1)))
    func theInterruptSendsSessionCancelToTheAgent() async throws {
        let fixture = try await ScriptedTurnFixture.make(
            script: [.textDelta(Self.arrivedText), .hold],
            label: "InterruptTests-wire",
            tapsAgentWire: true)
        let prompting = Task {
            try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(
                    sessionId: fixture.sessionId, text: Self.promptText))
        }
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)

        await RunTurn.react(
            to: Self.oneArrival(),
            cancelling: fixture.sessionId,
            over: fixture.harness.connection)

        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        let tap = try #require(fixture.harness.agentWireTap)
        let lines = await tap.lines
        let cancels = lines.filter { $0.contains(Self.cancelWireMethod) }
        #expect(cancels.count == 1, "the agent end read: \(lines)")
        _ = try await prompting.value
        await fixture.close()
    }

    // MARK: - The exit code (cli-plan.md §5.8, §5.9)

    /// A cancelled turn exits 4.
    @Test func aCancelledTurnExitsFour() {
        #expect(
            AcpAgentCommand.Run.exitCode(of: RunTurnResult(stopReason: .cancelled))
                == ExitCode(InterruptHandler.cancelledExitCode))
    }

    /// A turn that ran to its end exits 0, so the interrupt code never
    /// leaks into an ordinary run.
    @Test func aFinishedTurnDoesNotExitFour() {
        #expect(AcpAgentCommand.Run.exitCode(of: RunTurnResult(stopReason: .endTurn)) == nil)
        #expect(AcpAgentCommand.Run.exitCode(of: RunTurnResult(stopReason: nil)) == nil)
    }

    // MARK: - The handler is async-signal-safe (cli-plan.md §5.9)

    /// The `DispatchSourceSignal` handler body sets the atomic flag and
    /// resumes the continuation, and does nothing else.
    ///
    /// "Calls nothing that is not async-signal-safe" cannot be asserted
    /// at runtime, so the source itself is the assertion. Every other
    /// step of the interrupt — the `session/cancel`, the wait for the
    /// stop reason, the exit — happens on the normal task that reads the
    /// arrivals.
    @Test func theSignalHandlerBodySetsTheFlagAndResumesTheContinuation() throws {
        let handler = try PackageRoot.directory()
            .appendingPathComponent(Self.commandSourceDirectory, isDirectory: true)
            .appendingPathComponent(Self.handlerFileName)

        let body = try Self.handlerBody(of: String(contentsOf: handler, encoding: .utf8))

        #expect(body == Self.handlerStatements)
    }
}
