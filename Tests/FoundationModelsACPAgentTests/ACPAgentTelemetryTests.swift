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

    /// A struct with a stored property. Its mirror shows the property label
    /// as its first child, thus it looks like an enum case with a payload.
    private struct LabelledValue {
        /// The stored property that gives the mirror a child label.
        let content: String
    }

    /// The fallback text that the struct test expects from `caseName`.
    private static let structFallback = "not-an-enum"

    /// A value that is not an enum gives the fallback, not the label of its
    /// first stored property.
    @Test func caseNameOfAStructGivesTheFallback() {
        let value = LabelledValue(content: "secret text")
        #expect(ACPAgentTelemetry.caseName(of: value, fallback: Self.structFallback) == Self.structFallback)
    }

    /// The error of the metadata test. Its message must not go in the
    /// metadata.
    private struct ProbeError: Error, CustomStringConvertible {
        /// A message that the metadata must not hold.
        var description: String { "secret message" }
    }

    /// The error metadata of a record with no session holds the full type
    /// name of the error, and no session id and no message.
    @Test func errorMetadataWithNoSessionHoldsTheErrorTypeOnly() {
        let metadata = ACPAgentTelemetry.errorMetadata(ProbeError())

        #expect(metadata == [ACPAgentTelemetry.LogMetadataKey.errorType: "\(String(reflecting: ProbeError.self))"])
    }
}
