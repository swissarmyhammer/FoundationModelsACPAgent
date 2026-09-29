import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - The telemetry bootstrap keeps stdout for ACP only
//
// `acp-agent` bootstraps logging, tracing and metrics as the first step of
// `main()` (the approved OpenTelemetry design, items 1 and 6). In `acp` mode
// stdout carries the ACP frames, so no log record and no exporter output can
// go there. This suite spawns the built binary and holds its stdout to the
// plan.md §17 framing rule, with no `OTEL_*` variable, with an OTLP
// endpoint that has no listener, and with a traces configuration that
// swift-otel cannot build. It also holds the agent to `OTEL_SDK_DISABLED`,
// and holds each bootstrap path to a clean exit: a second bootstrap of
// swift-log stops the process.
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

    /// The standard variable that enables the OTLP exporter of `acp-agent`.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The standard variable that selects the span exporter.
    private static let tracesExporterVariable = "OTEL_TRACES_EXPORTER"

    /// A span exporter that swift-otel 1.5.1 knows by name but does not
    /// implement: the traces bootstrap throws `NotImplementedError`. (A name
    /// that swift-otel does not know gives only a warning, and the default
    /// exporter stays.)
    private static let unimplementedTracesExporter = "zipkin"

    /// The standard variable that turns off the whole OpenTelemetry SDK.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// An OTLP endpoint with no listener: nothing listens on port 1 of the
    /// loopback address, so each export fails.
    private static let unreachableCollectorEndpoint = "http://127.0.0.1:1"

    /// The prompt of the one prompt. The stub model echoes it.
    private static let promptText = "keep stdout for the frames"

    /// The exit code of a normal end.
    private static let successExitCode: Int32 = 0

    /// The number of seconds in ``exitLimit``.
    private static let exitLimitSeconds = 30

    /// How long the agent may take to end after the client closes stdin. The
    /// shutdown flush waits 2 seconds at most, and this limit only keeps a
    /// hung agent from holding the case.
    private static let exitLimit: Swift.Duration = .seconds(exitLimitSeconds)

    // MARK: - The drive

    /// Spawns the built `acp-agent acp` over the stub model, with no
    /// `OTEL_*` variable of this process and with each pair of
    /// `environment`. Then it runs `initialize`, `session/new` and one
    /// prompt, closes stdin, and waits for the exit, so the shutdown flush of
    /// the agent runs.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory tells where
    ///     it came from.
    ///   - environment: The extra pairs for the agent.
    /// - Returns: The drive.
    /// - Throws: The spawn, request or wait error.
    private static func driveOnePrompt(
        label: String, environment: [String: String] = [:]
    ) async throws -> SpawnedAgentPromptDrive {
        try await SpawnedAgentPromptDrive.run(
            label: label, environment: environment, promptText: promptText
        ) { agent in
            try await agent.closeStandardInputAndWait(within: exitLimit)
        }
    }

    /// Checks the contract of one drive: a good `initialize`, a prompt that
    /// ends, only JSON-RPC frames on stdout, and a clean exit.
    ///
    /// - Parameter drive: The drive to check.
    /// - Throws: The frame check error.
    private static func assertCleanDrive(_ drive: SpawnedAgentPromptDrive) throws {
        #expect(drive.initialized.info.name == RoutedACPAgent.implementation.name)
        #expect(drive.initialized.protocolVersion == RoutedACPAgent.latestProtocolVersion)
        #expect(drive.stopReason != nil, "the prompt never reached an idle state update")
        #expect(drive.exit.didExit, "a signal ended the agent; stderr: \(drive.exit.standardError)")
        #expect(
            drive.exit.status == successExitCode, "stderr: \(drive.exit.standardError)")
        try StdoutFrameChecks.assertFramesArePureJSONRPC(in: drive.standardOutput)
    }

    // MARK: - The contract

    /// With no `OTEL_*` variable, the agent bootstraps a stderr log handler,
    /// and stdout carries only JSON-RPC frames through `initialize`,
    /// `session/new` and one prompt.
    @Test func stdoutCarriesOnlyFramesWithNoOpenTelemetryVariable() async throws {
        let drive = try await Self.driveOnePrompt(label: "TelemetryStdout-none")

        try Self.assertCleanDrive(drive)
    }

    /// With an OTLP endpoint that has no listener, the agent still starts,
    /// answers `initialize`, and stdout carries only JSON-RPC frames. A
    /// failed export writes its diagnostic to stderr, never to stdout.
    @Test func stdoutCarriesOnlyFramesWithAnUnreachableCollector() async throws {
        let drive = try await Self.driveOnePrompt(
            label: "TelemetryStdout-unreachable",
            environment: [Self.otlpEndpointVariable: Self.unreachableCollectorEndpoint])

        try Self.assertCleanDrive(drive)
    }

    /// With a traces configuration that swift-otel cannot build, the traces
    /// and metrics bootstrap fails after the logging bootstrap. The agent
    /// does not bootstrap logging again, so it does not stop: it answers
    /// `initialize`, and stdout carries only JSON-RPC frames.
    @Test func aFailedTracesConfigurationKeepsTheAgentRunning() async throws {
        let drive = try await Self.driveOnePrompt(
            label: "TelemetryStdout-traces-failure",
            environment: [
                Self.otlpEndpointVariable: Self.unreachableCollectorEndpoint,
                Self.tracesExporterVariable: Self.unimplementedTracesExporter,
            ])

        try Self.assertCleanDrive(drive)
    }

    /// `OTEL_SDK_DISABLED=false` keeps the export on. swift-otel reads that
    /// value as "enable the logs" too, and the logs have their own
    /// bootstrap. So the agent must not give the value to the traces and
    /// metrics bootstrap, or swift-log gets a second bootstrap and the
    /// process stops.
    @Test func anSDKSwitchOfFalseKeepsTheAgentRunning() async throws {
        let drive = try await Self.driveOnePrompt(
            label: "TelemetryStdout-sdk-enabled",
            environment: [
                Self.otlpEndpointVariable: Self.unreachableCollectorEndpoint,
                Self.sdkDisabledVariable: "false",
            ])

        try Self.assertCleanDrive(drive)
    }

    /// With `OTEL_SDK_DISABLED` set to `true` in any case, and an OTLP
    /// endpoint on a live receiver, the agent sends nothing to the endpoint,
    /// also at the shutdown flush of its exit. `TelemetryFlushTests` proves
    /// that the same drive with no switch sends spans to the receiver.
    @Test(arguments: ["TRUE", "true"])
    func theSDKSwitchStopsEachExport(value: String) async throws {
        let receiver = try await OTLPTestReceiver.start()
        defer { receiver.stop() }

        let drive = try await Self.driveOnePrompt(
            label: "TelemetryStdout-sdk-disabled",
            environment: [
                Self.otlpEndpointVariable: receiver.endpoint,
                Self.sdkDisabledVariable: value,
            ])

        try Self.assertCleanDrive(drive)
        let paths = receiver.requests.map(\.path)
        #expect(paths.isEmpty, "the receiver got requests: \(paths)")
    }
}
