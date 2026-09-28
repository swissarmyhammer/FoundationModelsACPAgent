import Testing

@testable import FoundationModelsACPAgent

/// The telemetry vocabulary of the agent: each span name and each metric
/// name has the module prefix, and no name is written two times.
@Suite struct ACPAgentTelemetryTests {
    /// The prefix of each span name that the agent opens.
    private static let spanNamePrefix = "FoundationModelsACPAgent."

    /// The prefix of each metric name that the agent records.
    private static let metricNamePrefix = "foundation_models_acp_agent."

    /// All the span names of ``ACPAgentTelemetry/SpanName``.
    private static let spanNames = [
        ACPAgentTelemetry.SpanName.initialize,
        ACPAgentTelemetry.SpanName.sessionNew,
        ACPAgentTelemetry.SpanName.sessionResume,
        ACPAgentTelemetry.SpanName.prompt,
        ACPAgentTelemetry.SpanName.cancel,
        ACPAgentTelemetry.SpanName.command,
        ACPAgentTelemetry.SpanName.elicitation,
        ACPAgentTelemetry.SpanName.mcpConnect,
    ]

    /// All the metric names of ``ACPAgentTelemetry/MetricName``.
    private static let metricNames = [
        ACPAgentTelemetry.MetricName.prompts,
        ACPAgentTelemetry.MetricName.promptDuration,
        ACPAgentTelemetry.MetricName.activeSessions,
        ACPAgentTelemetry.MetricName.commands,
        ACPAgentTelemetry.MetricName.mcpConnectFailures,
    ]

    /// Each span name starts with the module prefix and has a word after it.
    @Test(arguments: spanNames)
    func spanNameHasTheModulePrefix(name: String) {
        #expect(name.hasPrefix(Self.spanNamePrefix))
        #expect(name.count > Self.spanNamePrefix.count)
    }

    /// Each metric name starts with the module prefix and has a word after it.
    @Test(arguments: metricNames)
    func metricNameHasTheModulePrefix(name: String) {
        #expect(name.hasPrefix(Self.metricNamePrefix))
        #expect(name.count > Self.metricNamePrefix.count)
    }

    /// No span name and no metric name is written two times.
    @Test func namesAreUnique() {
        let names = Self.spanNames + Self.metricNames
        #expect(Set(names).count == names.count)
    }
}
