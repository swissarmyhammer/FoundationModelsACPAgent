import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - The telemetry bootstrap keeps stdout for ACP only
//
// `acp-agent` bootstraps logging, tracing and metrics as the first step of
// `main()` (the approved OpenTelemetry design, items 1 and 6). In `acp` mode
// stdout carries the ACP frames, so no log record and no exporter output can
// go there. This suite spawns the built binary and holds its stdout to the
// plan.md §17 framing rule, with no `OTEL_*` variable and with an OTLP
// endpoint that has no listener.
//
// Only a spawned process can prove this. The unit target links the
// `acp-agent` target, and no test in that process may bootstrap logging.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The time limit of each case in minutes. The stub model loads nothing, so
/// the limit covers only the spawn, one prompt and the exporter timeouts.
private let telemetryRunTimeLimitMinutes = 3

/// The stdout contract of the telemetry bootstrap of `acp-agent acp`.
///
/// Serialized so at most one spawned agent runs at a time.
@Suite(
    .serialized,
    .timeLimit(.minutes(telemetryRunTimeLimitMinutes)))
struct TelemetryStdoutTests {
    // MARK: - Constants

    /// The command that starts the agent with a changed environment. The
    /// suite does not change the environment of this process, because other
    /// suites spawn children at the same time.
    private static let environmentCommand = "/usr/bin/env"

    /// The `env` option that removes one variable from the environment.
    private static let unsetOption = "-u"

    /// The prefix of each standard OpenTelemetry environment variable.
    private static let openTelemetryVariablePrefix = "OTEL_"

    /// The standard variable that turns on the OTLP exporter of `acp-agent`.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// An OTLP endpoint with no listener: nothing listens on port 1 of the
    /// loopback address, so each export fails.
    private static let unreachableCollectorEndpoint = "http://127.0.0.1:1"

    /// The prompt of the one prompt. The stub model echoes it.
    private static let promptText = "keep stdout for the frames"

    // MARK: - The drive

    /// What one drive of the spawned agent gives back.
    private struct Drive {
        /// The response to `initialize`.
        let initialized: InitializeResponse

        /// The stop reason of the prompt, or `nil` when the prompt did not
        /// end.
        let stopReason: StopReason?

        /// The raw bytes the agent wrote to its stdout.
        let standardOutput: Data
    }

    /// Makes the `env` arguments that remove each `OTEL_*` variable of this
    /// process and then set each pair of `environment`.
    ///
    /// - Parameter environment: The pairs to set in the child.
    /// - Returns: The arguments, before the command that `env` runs.
    private static func makeEnvironmentArguments(setting environment: [String: String]) -> [String] {
        let removals = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix(openTelemetryVariablePrefix) }
            .sorted()
            .flatMap { [unsetOption, $0] }
        let assignments = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return removals + assignments
    }

    /// Spawns the built `acp-agent acp` over the stub model, with no
    /// `OTEL_*` variable of this process and with each pair of
    /// `environment`. Then it runs `initialize`, `session/new` and one
    /// prompt, and closes the connection.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory tells where
    ///     it came from.
    ///   - environment: The extra pairs for the agent.
    /// - Returns: The drive.
    /// - Throws: The locator, spawn or request error.
    private static func driveOnePrompt(
        label: String, environment: [String: String] = [:]
    ) async throws -> Drive {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let configHome = makeResolvedDirectory(label: "\(label)-config")
        let agentPath = try BuiltProductLocator.executableURL(
            named: TierThreeFixture.agentExecutableName
        ).path
        let childEnvironment = TierThreeFixture.stubModelEnvironment
            .merging(environment) { _, extra in extra }
            .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
        let agent = try AgentProcess(
            command: environmentCommand,
            arguments: makeEnvironmentArguments(setting: childEnvironment)
                + [agentPath, TierThreeFixture.acpSubcommand])
        let tap = InboundTapTransport(wrapping: agent.transport)
        let client = await SwiftUIACPClient()
        let connection = await client.connect(over: tap)

        let initialized = try await connection.initialize(
            AgentClientHarness.makeInitializeRequest())
        let session = try await connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        // Subscribe before the prompt: the router drops an update that has
        // no subscriber.
        let updates = connection.updates(for: session.sessionId)
        _ = try await connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: session.sessionId, text: promptText))
        let stopReason = await StdoutFrameChecks.waitForIdle(on: updates)

        await connection.close()
        agent.shutdown()
        return Drive(
            initialized: initialized, stopReason: stopReason,
            standardOutput: tap.recordedBytes)
    }

    // MARK: - The contract

    /// With no `OTEL_*` variable, the agent bootstraps a stderr log handler,
    /// and stdout carries only JSON-RPC frames through `initialize`,
    /// `session/new` and one prompt.
    @Test func stdoutCarriesOnlyFramesWithNoOpenTelemetryVariable() async throws {
        let drive = try await Self.driveOnePrompt(label: "TelemetryStdout-none")

        #expect(drive.stopReason != nil, "the prompt never reached an idle state update")
        try StdoutFrameChecks.assertFramesArePureJSONRPC(in: drive.standardOutput)
    }

    /// With an OTLP endpoint that has no listener, the agent still starts,
    /// answers `initialize`, and stdout carries only JSON-RPC frames. A
    /// failed export writes its diagnostic to stderr, never to stdout.
    @Test func stdoutCarriesOnlyFramesWithAnUnreachableCollector() async throws {
        let drive = try await Self.driveOnePrompt(
            label: "TelemetryStdout-unreachable",
            environment: [Self.otlpEndpointVariable: Self.unreachableCollectorEndpoint])

        #expect(drive.initialized.info.name == RoutedACPAgent.implementation.name)
        #expect(drive.initialized.protocolVersion == RoutedACPAgent.latestProtocolVersion)
        #expect(drive.stopReason != nil, "the prompt never reached an idle state update")
        try StdoutFrameChecks.assertFramesArePureJSONRPC(in: drive.standardOutput)
    }
}
