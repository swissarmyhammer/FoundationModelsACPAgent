import FoundationModelsACP
import Logging
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
    /// The module name. Each span name and each logger label starts with it
    /// and a dot.
    private static let moduleName = "FoundationModelsACPAgent"

    /// The operation name of each span the agent opens.
    ///
    /// Each name starts with the module prefix, so a reader can find the spans
    /// of the agent in a trace that also holds the spans of Router and of the
    /// client.
    enum SpanName {
        /// The text at the start of each name below.
        private static let prefix = moduleName + "."

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
    /// The log metadata keys read some of these keys.
    enum AttributeKey {
        /// The ACP method of the request, for example `session/prompt`.
        static let acpMethod = "acp.method"

        /// The ACP session id that the work runs on.
        static let sessionId = "session.id"

        /// The ACP stop reason that ended a prompt.
        static let promptStopReason = "prompt.stop_reason"

        /// The name of the slash command, without the leading `/`.
        static let commandName = "command.name"

        /// The kind of the slash command: a ``CommandKind`` raw value.
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
    /// A key for a value that no span carries uses the key that Router or
    /// Extras uses for the same value, where one exists.
    enum LogMetadataKey {
        /// The ACP session id.
        static let sessionId = AttributeKey.sessionId

        /// The ACP method of the request.
        static let acpMethod = AttributeKey.acpMethod

        /// The ACP stop reason of a prompt.
        static let stopReason = AttributeKey.promptStopReason

        /// The type name of an error. Never the error message, because a
        /// message can hold content.
        static let errorType = AttributeKey.errorType

        /// The enum case of an error, without its payload, because a payload
        /// can hold content.
        static let errorCase = "error.case"

        /// The model reference that a session generates with. Router uses
        /// the same key.
        static let modelRef = "model.ref"

        /// The id of a tool call on the wire. A run of a tool has the same
        /// id: its completion token is the tool call id (plan.md §11.8).
        static let toolCallId = "tool_call.id"

        /// The name of a tool. Extras uses the same key.
        static let toolName = "tool.name"

        /// The id of a recorded transcript entry.
        static let entryId = "transcript.entry_id"

        /// The case of a Router session event, without its payload, because
        /// a payload can hold content.
        static let eventKind = "event.kind"

        /// The text of a Router report: a stall or a repetition stop. It
        /// holds times, counts and settings only.
        static let routerReport = "router.report"

        /// The prompt tokens of a prompt. Router uses the same key.
        static let tokensIn = "tokens.in"

        /// The completion tokens of a prompt. Router uses the same key.
        static let tokensOut = "tokens.out"

        /// The fraction of the context that the last usage report filled, or
        /// `unknown` when no report gave it.
        static let contextFill = "context.fill"

        /// The working context of a session, in tokens.
        static let contextTokens = "context.tokens"

        /// The working context, in tokens, that a restored session was
        /// recorded at.
        static let recordedContextTokens = "context.recorded_tokens"

        /// The working context, in tokens, that the restoring profile
        /// resolved.
        static let resolvedContextTokens = "context.resolved_tokens"

        /// The fraction of the context at which the compaction starts.
        static let compactionTriggerFraction = "compaction.trigger_fraction"

        /// The fraction of the context that the compaction goes down to.
        static let compactionTargetFraction = "compaction.target_fraction"

        /// What a `session/cancel` found to cancel: `requested` or
        /// `nothingToCancel`.
        static let cancelResult = "cancel.result"

        /// The name of the ACP client, from its `initialize` request.
        static let clientName = "client.name"

        /// The version of the ACP client, from its `initialize` request.
        static let clientVersion = "client.version"

        /// The protocol version that the client sent.
        static let requestedProtocolVersion = "acp.protocol_version.requested"

        /// The protocol version that the agent answered with.
        static let answeredProtocolVersion = "acp.protocol_version.answered"

        /// The name of a slash command, without the leading `/`.
        static let commandName = AttributeKey.commandName

        /// The configured name of an MCP server. A refusal of `mcp: false`
        /// that covers more than one server gives an array of names.
        static let mcpServerName = AttributeKey.mcpServerName

        /// Why the composition refused a client-supplied MCP server: the
        /// name of the refusal case.
        static let mcpRefusalReason = "mcp.server.refusal_reason"

        /// The id of an elicitation.
        static let elicitationId = "elicitation.id"

        /// The mode of an elicitation: `form` or `url`.
        static let elicitationMode = AttributeKey.elicitationMode

        /// Why the relay declined an elicitation: the name of the decline
        /// reason.
        static let elicitationDeclineReason = "elicitation.decline_reason"

        /// The name of a `config.yaml` section, as a dotted key path. Never
        /// a value of the section, because a value can be a secret.
        static let configSection = "config.section"

        /// The path of a file that the agent reads or writes. Never the
        /// content of the file.
        static let filePath = "file.path"

        /// The W3C trace id of the span that an "enter" record starts.
        /// `TracedCall` of Extras uses the same key.
        static let traceId = "trace.id"

        /// The W3C span id of the span that an "enter" record starts.
        /// `TracedCall` of Extras uses the same key.
        static let spanId = "span.id"
    }

    /// The text that ``caseName(of:)`` gives for a value that shows no case
    /// label.
    private static let unknownCaseName = "unknown"

    /// The name of the enum case of `value`, without its payload.
    ///
    /// A log record uses it in place of the description of an event or an
    /// error, because a payload can hold content: a Router `answered` event
    /// holds the answer text, for example.
    ///
    /// - Parameter value: An enum value.
    /// - Returns: The case label, or `unknown` for a case with no payload and
    ///   for a value that is not an enum. A case with no payload shows no
    ///   label, and its description can be a text of the type.
    static func caseName(of value: Any) -> String {
        Mirror(reflecting: value).children.first?.label ?? unknownCaseName
    }

    /// The metadata of a record about one session: its session id.
    ///
    /// - Parameter sessionId: The ACP session id.
    /// - Returns: The ``LogMetadataKey/sessionId`` value.
    static func sessionMetadata(_ sessionId: SessionId) -> Logger.Metadata {
        [LogMetadataKey.sessionId: "\(sessionId.rawValue)"]
    }

    /// The metadata of a record about the model work of one session: the
    /// session id and the model reference.
    ///
    /// - Parameters:
    ///   - sessionId: The ACP session id.
    ///   - modelRef: The model reference that the session generates with.
    /// - Returns: The ``LogMetadataKey/sessionId`` and
    ///   ``LogMetadataKey/modelRef`` values.
    static func modelMetadata(sessionId: SessionId, modelRef: String) -> Logger.Metadata {
        var metadata = sessionMetadata(sessionId)
        metadata[LogMetadataKey.modelRef] = "\(modelRef)"
        return metadata
    }

    /// The metadata of an error in one session: the session id and the type
    /// name of the error, never its message.
    ///
    /// - Parameters:
    ///   - error: The error.
    ///   - sessionId: The ACP session id.
    /// - Returns: The ``LogMetadataKey/sessionId`` and
    ///   ``LogMetadataKey/errorType`` values.
    static func errorMetadata(_ error: any Error, sessionId: SessionId) -> Logger.Metadata {
        var metadata = sessionMetadata(sessionId)
        metadata[LogMetadataKey.errorType] = "\(errorTypeName(of: error))"
        return metadata
    }

    /// The type name of `error`, for the ``AttributeKey/errorType`` attribute
    /// and the ``LogMetadataKey/errorType`` metadata value.
    ///
    /// - Parameter error: The error.
    /// - Returns: The full type name, with its module, for example
    ///   `FoundationModelsACP.RequestError`. Never the error message, because a
    ///   message can hold content.
    static func errorTypeName(of error: any Error) -> String {
        String(reflecting: type(of: error))
    }

    /// The text before the span name in the message of an "enter" record.
    /// It is the text that `TracedCall` of FoundationModelsExtras writes.
    private static let enterMessagePrefix = "enter "

    /// The message of the "enter" record of the span with the name
    /// `spanName`: the record that a call writes when it starts, so that a
    /// call that hangs shows as a record with no span that ends.
    ///
    /// - Parameter spanName: The name of the span of the call.
    /// - Returns: `enter <spanName>`, the message that `TracedCall` writes.
    static func enterMessage(forSpanNamed spanName: String) -> String {
        enterMessagePrefix + spanName
    }

    /// The metadata of a record about one file: its path, never its content.
    ///
    /// - Parameter path: The path of the file.
    /// - Returns: The ``LogMetadataKey/filePath`` value.
    static func fileMetadata(path: String) -> Logger.Metadata {
        [LogMetadataKey.filePath: "\(path)"]
    }

    /// The category of each logger that the agent makes. The label of the
    /// logger is the module name, a dot and the raw value.
    enum LoggerCategory: String {
        /// The session surface: the order rule and the session budget.
        case session = "Session"

        /// The prompt execution: the prompt state, the update sends, the
        /// event projection, the terminal stream and the ignored events.
        case promptExecution = "PromptExecution"

        /// The handshake: the version negotiation and the client identity.
        case initialization = "Initialization"

        /// The resume surface: the cwd pre-check, the restore reports and the
        /// root-set update.
        case sessionResume = "SessionResume"

        /// The session lifecycle: the disk removals of a delete.
        case sessionLifecycle = "SessionLifecycle"

        /// The elicitation relay: the round trips, the declines and the
        /// dropped late answers.
        case elicitationRelay = "ElicitationRelay"

        /// The command registry: the merge wins and the reserved-name drops.
        case commands = "Commands"

        /// The MCP composition: the refusals of client-supplied servers.
        case mcpComposition = "MCPComposition"

        /// The transcripts module: the damaged lines of the session index
        /// and of the project registry.
        case transcripts = "Transcripts"

        /// The configuration loader: the unknown sections of `config.yaml`.
        case configuration = "Configuration"

        /// The instructions assembler: the files that do not read as text.
        case instructions = "Instructions"
    }

    /// Makes a new logger for `category`.
    ///
    /// Call it at the log call, and do not keep the result in a global or a
    /// `static let`. A logger keeps the handler that the logging system gave
    /// it when it was made. Thus a logger made before the logging bootstrap of
    /// the executable, or before a `TelemetryCapture` of a test, does not
    /// write to the backend of that bootstrap or capture.
    ///
    /// - Parameter category: The part of the agent that writes the records.
    /// - Returns: A logger with the label `FoundationModelsACPAgent.<Category>`.
    static func logger(_ category: LoggerCategory) -> Logger {
        Logger(label: moduleName + "." + category.rawValue)
    }

    /// The tracer that a call opens its span through.
    ///
    /// `nil` is the resolve-late shape, and it is the default of the whole
    /// package: an executable that bootstraps a tracing backend *after* it
    /// makes the agent still traces, because the tracer is read only when the
    /// call starts.
    ///
    /// - Parameter explicit: The tracer the agent was made with, or `nil` to
    ///   read the bootstrapped tracer now.
    /// - Returns: `explicit` when it is set, else `InstrumentationSystem.tracer`.
    static func tracer(explicit: (any Tracer)?) -> any Tracer {
        explicit ?? InstrumentationSystem.tracer
    }
}
