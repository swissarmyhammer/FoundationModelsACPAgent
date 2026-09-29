import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - The telemetry flush on each exit path of acp-agent
//
// An OTLP batch exporter keeps spans, log records and metrics in memory and
// sends them later. So `acp-agent` shuts its telemetry down on each exit
// path, and the shutdown flushes the last batch. This suite spawns the built
// binary with an OTLP endpoint on a local receiver and a batch delay of ten
// minutes, so only the shutdown flush can send a span inside the case. Then
// it ends the agent on each exit path and reads what the receiver got.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The time limit of each case in minutes. The stub model loads nothing, so
/// the limit covers the spawn, one prompt and the flush.
private let telemetryFlushTimeLimitMinutes = 3

/// The exit paths of `acp-agent` that flush the telemetry.
enum TelemetryExitPath: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// `acp` mode after one prompt: the client closes stdin.
    case endOfStandardInput

    /// `run` mode: the first `SIGINT` during the prompt.
    case firstInterrupt

    /// `acp` mode after one prompt: `SIGTERM`.
    case termination

    /// `run` mode: `SIGTERM` during the prompt.
    case runTermination

    var testDescription: String {
        rawValue
    }
}

/// How one exit path ended.
private struct PathEnd {
    /// The exit code.
    let exitCode: Int32

    /// `true` when the agent called `exit`, and `false` when a signal with no
    /// handler ended it.
    let didExit: Bool

    /// The time from the end request to the end of the agent.
    let elapsed: Swift.Duration

    /// The stderr text of the agent.
    let standardError: String
}

/// The telemetry flush of each exit path of `acp-agent`.
///
/// Serialized so at most one spawned agent runs at a time.
@Suite(
    .serialized,
    .timeLimit(.minutes(telemetryFlushTimeLimitMinutes)))
struct TelemetryFlushTests {
    // MARK: - Constants

    /// The standard variable that turns on the OTLP exporters.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The standard variable that selects the OTLP protocol.
    private static let otlpProtocolVariable = "OTEL_EXPORTER_OTLP_PROTOCOL"

    /// The OTLP protocol with JSON bodies, so the receiver can read the span
    /// names.
    private static let httpJSONProtocol = "http/json"

    /// The standard variable of the delay between two exports of the batch
    /// span processor, in milliseconds.
    private static let batchDelayVariable = "OTEL_BSP_SCHEDULE_DELAY"

    /// A batch delay of ten minutes: longer than each case, so only the
    /// shutdown flush can send a span.
    private static let longBatchDelayMilliseconds = "600000"

    /// An OTLP endpoint with no listener: nothing listens on port 1 of the
    /// loopback address, so each export fails. Before the shutdown deadline,
    /// the flush to this endpoint held the process for more than 5 seconds.
    private static let unreachableCollectorEndpoint = "http://127.0.0.1:1"

    /// The prefix of each span name of FoundationModelsRouter.
    ///
    /// The case does not name one span: the pinned Router names the prompt
    /// span `FoundationModelsRouter.turn`, and a newer Router names it
    /// `FoundationModelsRouter.submission`.
    private static let routerSpanPrefix = "FoundationModelsRouter."

    /// The `run` subcommand.
    private static let runSubcommand = "run"

    /// The prompt of each case. The stub model echoes it word by word, so the
    /// words are the chunks, and eight chunks give a prompt with room for a
    /// signal in the middle of it.
    private static let promptText = "one two three four five six seven eight"

    /// The pause between two chunks of the paced stub, in milliseconds.
    private static let chunkDelayMilliseconds = 180

    /// The exit code of a normal end.
    private static let successExitCode: Int32 = 0

    /// The exit code of a cancelled prompt (cli-plan.md §5.8).
    private static let cancelledExitCode: Int32 = 4

    /// The exit code of an end by `SIGTERM`: 128 and the signal number 15.
    private static let terminationExitCode: Int32 = 143

    /// The number of seconds in ``deadCollectorExitLimit``.
    private static let deadCollectorExitLimitSeconds = 5

    /// How long an exit path may take with no receiver on the port, from the
    /// end request to the end of the agent. The shutdown deadline of the
    /// agent is 2 seconds, so a flush that waits on a dead collector cannot
    /// pass this limit.
    private static let deadCollectorExitLimit: Swift.Duration = .seconds(
        deadCollectorExitLimitSeconds)

    /// The number of seconds in ``flushExitLimit``.
    private static let flushExitLimitSeconds = 30

    /// How long an exit path may take with a live receiver. The flush itself
    /// takes milliseconds, but the other suites of this package spawn agents
    /// and load models at the same time, and that load can hold a process
    /// for seconds. This limit only keeps a hung agent from holding the case.
    private static let flushExitLimit: Swift.Duration = .seconds(flushExitLimitSeconds)

    /// The number of seconds in ``firstOutputLimit``.
    private static let firstOutputLimitSeconds = 60

    /// How long a `run` child may take to write its first stdout byte.
    private static let firstOutputLimit: Swift.Duration = .seconds(firstOutputLimitSeconds)

    // MARK: - The drive

    /// The environment pairs that send the telemetry to `endpoint`, with a
    /// batch delay that only the shutdown flush beats.
    ///
    /// - Parameter endpoint: The OTLP endpoint.
    /// - Returns: The pairs.
    private static func flushEnvironment(endpoint: String) -> [String: String] {
        [
            otlpEndpointVariable: endpoint,
            otlpProtocolVariable: httpJSONProtocol,
            batchDelayVariable: longBatchDelayMilliseconds,
        ]
    }

    /// Runs `path` against the OTLP endpoint `endpoint`, and ends the agent on
    /// that path.
    ///
    /// - Parameters:
    ///   - path: The exit path.
    ///   - endpoint: The OTLP endpoint.
    ///   - exitLimit: How long the agent may take to end after the end
    ///     request.
    /// - Returns: How the path ended.
    /// - Throws: The spawn, request or wait error. `SignalledRunError` names
    ///   an agent that did not end inside `exitLimit`.
    private static func end(
        _ path: TelemetryExitPath, endpoint: String, exitLimit: Swift.Duration
    ) async throws -> PathEnd {
        let label = "TelemetryFlush-\(path.rawValue)"
        switch path {
        case .endOfStandardInput:
            return try await endInACPMode(label: label, endpoint: endpoint) { agent in
                try await agent.closeStandardInputAndWait(within: exitLimit)
            }
        case .termination:
            return try await endInACPMode(label: label, endpoint: endpoint) { agent in
                try await agent.terminateAndWait(within: exitLimit)
            }
        case .firstInterrupt:
            return try await signalInRunMode(
                SIGINT, label: label, endpoint: endpoint, exitLimit: exitLimit)
        case .runTermination:
            return try await signalInRunMode(
                SIGTERM, label: label, endpoint: endpoint, exitLimit: exitLimit)
        }
    }

    /// Spawns `acp-agent acp` over the stub model, runs `initialize`,
    /// `session/new` and one prompt, and then ends the agent with `ending`.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory tells where it
    ///     came from.
    ///   - endpoint: The OTLP endpoint.
    ///   - ending: The end request and the wait for the end.
    /// - Returns: How the agent ended.
    /// - Throws: The spawn, request or wait error.
    private static func endInACPMode(
        label: String, endpoint: String,
        ending: (SpawnedACPAgent) async throws -> SpawnedAgentExit
    ) async throws -> PathEnd {
        let drive = try await SpawnedAgentPromptDrive.run(
            label: label, environment: flushEnvironment(endpoint: endpoint),
            promptText: promptText, ending: ending)
        #expect(drive.stopReason == .endTurn, "the prompt did not end on end_turn")

        let exit = drive.exit
        return PathEnd(
            exitCode: exit.status, didExit: exit.didExit, elapsed: exit.elapsed,
            standardError: exit.standardError)
    }

    /// Runs `acp-agent run` over the paced stub model and sends one
    /// `signalNumber` once its first answer bytes arrive.
    ///
    /// - Parameters:
    ///   - signalNumber: The signal to send: `SIGINT` or `SIGTERM`.
    ///   - label: The directory label.
    ///   - endpoint: The OTLP endpoint.
    ///   - exitLimit: How long the agent may take to end after the signal.
    /// - Returns: How the agent ended.
    /// - Throws: The wait, locator or spawn error. `SignalledRunError` names
    ///   an agent that did not end inside `exitLimit` after the signal.
    private static func signalInRunMode(
        _ signalNumber: Int32, label: String, endpoint: String, exitLimit: Swift.Duration
    ) async throws -> PathEnd {
        let run = try await SignalledExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: [runSubcommand, promptText],
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            inheritedEnvironment: SpawnedACPAgent.environmentWithoutOpenTelemetry,
            environment: TierThreeFixture.pacedStubModelEnvironment(
                chunkDelayMilliseconds: chunkDelayMilliseconds
            ).merging(flushEnvironment(endpoint: endpoint)) { _, flush in flush },
            signalNumber: signalNumber,
            signalCount: 1,
            gap: .zero,
            firstOutputLimit: firstOutputLimit,
            exitLimit: exitLimit)
        return PathEnd(
            exitCode: run.exitCode, didExit: run.didExit, elapsed: run.exitWait,
            standardError: run.standardError)
    }

    /// The exit code each path ends with.
    ///
    /// - Parameter path: The exit path.
    /// - Returns: The usual exit code of the path.
    private static func expectedExitCode(of path: TelemetryExitPath) -> Int32 {
        switch path {
        case .endOfStandardInput: successExitCode
        case .firstInterrupt: cancelledExitCode
        case .termination, .runTermination: terminationExitCode
        }
    }

    /// Runs `path` against a live receiver and checks that the last spans of
    /// the run reached it.
    ///
    /// - Parameter path: The exit path.
    /// - Throws: The receiver, spawn, request or wait error.
    private static func assertTheLastSpansArrive(on path: TelemetryExitPath) async throws {
        let receiver = try await OTLPTestReceiver.start()
        defer { receiver.stop() }

        let end = try await Self.end(path, endpoint: receiver.endpoint, exitLimit: flushExitLimit)

        #expect(end.didExit, "a signal ended the agent with no handler")
        #expect(end.exitCode == expectedExitCode(of: path), "stderr: \(end.standardError)")
        let names = receiver.spanNames
        #expect(
            names.contains { $0.hasPrefix(routerSpanPrefix) },
            "no \(routerSpanPrefix) span reached the receiver; spans: \(names); stderr: \(end.standardError)")
    }

    // MARK: - The flush on each exit path

    /// `acp` mode, after one prompt, when the client closes stdin: the agent
    /// exits 0, and the Router spans of the run reach the receiver.
    @Test func theEndOfStandardInputFlushesTheLastSpans() async throws {
        try await Self.assertTheLastSpansArrive(on: .endOfStandardInput)
    }

    /// `run` mode, when the first `SIGINT` lands during the prompt: the agent
    /// exits 4, and the Router spans of the run reach the receiver.
    @Test func theFirstInterruptFlushesTheLastSpans() async throws {
        try await Self.assertTheLastSpansArrive(on: .firstInterrupt)
    }

    /// `acp` mode, after one prompt, on `SIGTERM`: the agent exits 143, and
    /// the Router spans of the run reach the receiver.
    @Test func aTerminationFlushesTheLastSpans() async throws {
        try await Self.assertTheLastSpansArrive(on: .termination)
    }

    /// `run` mode, when `SIGTERM` lands during the prompt: the agent sends
    /// `session/cancel`, exits 143, and the Router spans of the run reach the
    /// receiver.
    @Test func aTerminationDuringARunPromptFlushesTheLastSpans() async throws {
        try await Self.assertTheLastSpansArrive(on: .runTermination)
    }

    // MARK: - No receiver

    /// With nothing on the port, each exit path still ends inside
    /// ``deadCollectorExitLimit``, with its usual exit code: a dead collector
    /// cannot hold the process.
    @Test(arguments: TelemetryExitPath.allCases)
    func eachPathEndsInTimeWithNoReceiver(path: TelemetryExitPath) async throws {
        let end = try await Self.end(
            path, endpoint: Self.unreachableCollectorEndpoint, exitLimit: Self.deadCollectorExitLimit)

        #expect(end.didExit, "a signal ended the agent with no handler")
        #expect(end.exitCode == Self.expectedExitCode(of: path), "stderr: \(end.standardError)")
        #expect(end.elapsed < Self.deadCollectorExitLimit, "the exit took \(end.elapsed)")
    }
}
