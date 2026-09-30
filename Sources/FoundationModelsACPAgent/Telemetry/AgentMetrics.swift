import FoundationModelsACP
import Metrics

/// The metrics of the agent (the approved OpenTelemetry design, items 1 and
/// 4): the prompt count and duration, the active sessions, the slash-command
/// count and the MCP connect failures.
///
/// The package uses only the `swift-metrics` API. The executable bootstraps the
/// backend, and until it does so each metric is a no-op.
///
/// Each method makes its metric at the call, and never keeps it in a global or
/// a `static let`. A metric keeps the factory that `MetricsSystem` gave it when
/// it was made. Thus a metric made before the metrics bootstrap of the
/// executable, or before a `TelemetryCapture` of a test, does not go to the
/// factory of that bootstrap or capture.
///
/// The name of each metric and the key of each dimension come from
/// ``ACPAgentTelemetry``. Each dimension has a small, known set of values. A
/// session id is not a dimension, because its set of values has no bound. The
/// "No content" rule of ``ACPAgentTelemetry`` applies.
enum AgentMetrics {
    /// The ``ACPAgentTelemetry/MetricDimension/stopReason`` value of a prompt
    /// that has no ACP stop reason: the agent refused it, or it ended with no
    /// stop reason.
    static let errorStopReason = "error"

    /// The ``ACPAgentTelemetry/MetricDimension/commandKind`` value of a command
    /// that no source registers. The command name is never a dimension,
    /// because the set of names has no bound.
    static let unknownCommandKind = "unknown"

    /// How a slash command ended: the ``ACPAgentTelemetry/MetricDimension/outcome``
    /// value of the `commands` counter.
    enum CommandOutcome: String {
        /// The agent ran the command.
        case ok

        /// The agent refused the command: an unknown name, attachments on an
        /// action command, or a template that does not expand.
        case refused
    }

    /// Adds one to the `commands` counter.
    ///
    /// - Parameters:
    ///   - kind: The kind of the command, or `nil` for a name that no source
    ///     registers.
    ///   - outcome: How the command ended.
    static func recordCommand(kind: CommandKind?, outcome: CommandOutcome) {
        Counter(
            label: ACPAgentTelemetry.MetricName.commands,
            dimensions: [
                (ACPAgentTelemetry.MetricDimension.commandKind, kind?.rawValue ?? unknownCommandKind),
                (ACPAgentTelemetry.MetricDimension.outcome, outcome.rawValue),
            ]
        ).increment()
    }

    /// Adds one to the `mcp_connect_failures` counter.
    ///
    /// - Parameter transport: The transport of the MCP server: `stdio` or
    ///   `http`. Never the server name, the command or the URL.
    static func recordMCPConnectFailure(transport: String) {
        Counter(
            label: ACPAgentTelemetry.MetricName.mcpConnectFailures,
            dimensions: [(ACPAgentTelemetry.MetricDimension.transport, transport)]
        ).increment()
    }

    /// Sets the `active_sessions` gauge.
    ///
    /// - Parameter count: The number of sessions that are open now.
    static func recordActiveSessions(_ count: Int) {
        Gauge(label: ACPAgentTelemetry.MetricName.activeSessions).record(count)
    }
}

/// The measurement of one prompt: the `prompts` counter and the
/// `prompt_duration` timer, from the request in to the stop reason out.
///
/// The work of a prompt goes on after the `{}` response, and the connection
/// runs that work outside the task of the request handler. A task-local
/// metrics factory, such as the factory of a `TelemetryCapture`, does not reach
/// that work. Thus the measurement reads the factory when the request starts,
/// and it makes the counter and the timer with that factory when the stop
/// reason is known.
struct PromptMeasurement: Sendable {
    /// The metrics factory when the request started.
    private let factory: any MetricsFactory

    /// The time when the request started.
    private let start: ContinuousClock.Instant

    /// Starts the measurement of one prompt now.
    init() {
        factory = MetricsSystem.factory
        start = ContinuousClock.now
    }

    /// Adds one to the `prompts` counter and records the duration of the
    /// prompt, both with the `stop_reason` dimension.
    ///
    /// - Parameter stopReason: The stop reason that ended the prompt, or `nil`
    ///   when the agent refused the prompt or the prompt sent no stop reason.
    func record(stopReason: StopReason?) {
        let dimensions = [
            (ACPAgentTelemetry.MetricDimension.stopReason, stopReason?.wireValue ?? AgentMetrics.errorStopReason)
        ]
        Counter(label: ACPAgentTelemetry.MetricName.prompts, dimensions: dimensions, factory: factory).increment()
        Metrics.Timer(label: ACPAgentTelemetry.MetricName.promptDuration, dimensions: dimensions, factory: factory)
            .record(duration: start.duration(to: ContinuousClock.now))
    }
}
