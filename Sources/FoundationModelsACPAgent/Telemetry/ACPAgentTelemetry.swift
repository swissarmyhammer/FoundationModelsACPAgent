import Tracing

/// The telemetry vocabulary of the agent: the name of each span it opens, the
/// key of each attribute those spans carry, the name and the dimensions of each
/// metric it records, the key of each log metadata value it writes, and the
/// rule that selects the tracer a call opens its span through.
///
/// This is the one location of the vocabulary, so each name is written one
/// time and each call site reads it from here. A name here is part of the
/// observable surface of the agent: a dashboard, a query or an alert can use
/// it. Change a name only as a deliberate break.
///
/// The package uses only the telemetry APIs: `swift-distributed-tracing`,
/// `swift-log` and `swift-metrics`. These are abstractions and not exporters.
/// Until an executable bootstraps a backend, each API is a no-op, so an
/// application that does not collect telemetry pays nothing.
///
/// ## No content
///
/// A span attribute, a log message, a log metadata value and a metric
/// dimension must never carry prompt text, response text, tool arguments, tool
/// output or file content. The telemetry leaves the process through the
/// backend that the executable bootstrapped, and the agent cannot know where
/// that backend sends the data. Identifiers, names, counts and sizes are safe.
/// Content is not safe.
enum ACPAgentTelemetry {
    /// The operation name of each span the agent opens.
    ///
    /// Each name starts with the module prefix, so a reader can find the spans
    /// of the agent in a trace that also holds the spans of Router and of the
    /// client.
    enum SpanName {
        /// The text at the start of each name below.
        private static let prefix = "FoundationModelsACPAgent."

        /// One ACP `initialize` request.
        static let initialize = prefix + "initialize"

        /// One ACP `session/new` request.
        static let sessionNew = prefix + "sessionNew"

        /// One ACP `session/resume` request.
        static let sessionResume = prefix + "sessionResume"

        /// One ACP `session/prompt` request, from the prompt in to the stop
        /// reason out.
        static let prompt = prefix + "prompt"

        /// One ACP `session/cancel` notification.
        static let cancel = prefix + "cancel"

        /// One slash command that the agent runs.
        static let command = prefix + "command"

        /// One elicitation that the relay sends to the client.
        static let elicitation = prefix + "elicitation"

        /// One connection to an MCP server.
        static let mcpConnect = prefix + "mcpConnect"
    }

    /// The key of each attribute that a span of the agent carries.
    ///
    /// Obey the "No content" rule of ``ACPAgentTelemetry`` before you add a
    /// key: a key names an identifier, a name, a count or a size, and never
    /// the content of the client.
    ///
    /// OTel 6, OTel 8 and OTel 9 read these keys, so periphery sees no reader
    /// yet.
    // periphery:ignore
    enum AttributeKey {
        /// The ACP method of the request, for example `session/prompt`.
        static let acpMethod = "acp.method"

        /// The ACP session id that the work runs on.
        static let sessionId = "session.id"

        /// The ACP stop reason that ended a prompt.
        static let promptStopReason = "prompt.stop_reason"

        /// The name of the slash command, without the leading `/`.
        static let commandName = "command.name"

        /// The kind of the slash command: built-in, or from a layer.
        static let commandKind = "command.kind"

        /// The mode of the elicitation: `form` or `url`.
        static let elicitationMode = "elicitation.mode"

        /// How the elicitation ended: accept, decline or cancel.
        static let elicitationOutcome = "elicitation.outcome"

        /// The configured name of the MCP server.
        static let mcpServerName = "mcp.server.name"

        /// The transport of the MCP server: `stdio` or `http`.
        static let mcpServerTransport = "mcp.server.transport"

        /// The type name of the error that ended the work. Never the error
        /// message, because a message can hold content.
        static let errorType = "error.type"
    }

    /// The name of each metric that the agent records.
    ///
    /// Each name starts with the module prefix, in the snake case form that
    /// metric backends expect.
    enum MetricName {
        /// The text at the start of each name below.
        private static let prefix = "foundation_models_acp_agent."

        /// A counter: one for each prompt that ended.
        static let prompts = prefix + "prompts"

        /// A timer: the duration of each prompt.
        static let promptDuration = prefix + "prompt_duration"

        /// A gauge: the number of sessions that are open now.
        static let activeSessions = prefix + "active_sessions"

        /// A counter: one for each slash command that ran.
        static let commands = prefix + "commands"

        /// A counter: one for each MCP server connection that failed.
        static let mcpConnectFailures = prefix + "mcp_connect_failures"
    }

    /// The key of each dimension that a metric of the agent carries.
    ///
    /// The "No content" rule of ``ACPAgentTelemetry`` applies. Each dimension
    /// also has a small, known set of values, because each different value
    /// makes a different time series.
    ///
    /// OTel 9 reads these keys, so periphery sees no reader yet.
    // periphery:ignore
    enum MetricDimension {
        /// The ACP stop reason of a prompt.
        static let stopReason = "stop_reason"

        /// The kind of a slash command. The same key as the span attribute.
        static let commandKind = AttributeKey.commandKind

        /// How the work ended.
        static let outcome = "outcome"

        /// The transport of an MCP server.
        static let transport = "transport"
    }

    /// The key of each identifier that a log record of the agent carries as
    /// metadata.
    ///
    /// Each key is the same key as the span attribute for the same value, so
    /// a query can join a log record to its span. The "No content" rule of
    /// ``ACPAgentTelemetry`` applies to the metadata values and to the log
    /// message.
    ///
    /// OTel 3 and OTel 4 read these keys, so periphery sees no reader yet.
    // periphery:ignore
    enum LogMetadataKey {
        /// The ACP session id.
        static let sessionId = AttributeKey.sessionId

        /// The ACP method of the request.
        static let acpMethod = AttributeKey.acpMethod

        /// The name of the slash command.
        static let commandName = AttributeKey.commandName

        /// The configured name of the MCP server.
        static let mcpServerName = AttributeKey.mcpServerName

        /// The mode of the elicitation.
        static let elicitationMode = AttributeKey.elicitationMode
    }

    /// The tracer that a call opens its span through.
    ///
    /// `nil` is the resolve-late shape, and it is the default of the whole
    /// package: an executable that bootstraps a tracing backend *after* it
    /// makes the agent still traces, because the tracer is read only when the
    /// call starts.
    ///
    /// OTel 6 and OTel 8 call this function, so periphery sees no caller yet.
    ///
    /// - Parameter explicit: The tracer the agent was made with, or `nil` to
    ///   read the bootstrapped tracer now.
    /// - Returns: `explicit` when it is set, else `InstrumentationSystem.tracer`.
    // periphery:ignore
    static func tracer(explicit: (any Tracer)?) -> any Tracer {
        explicit ?? InstrumentationSystem.tracer
    }
}
