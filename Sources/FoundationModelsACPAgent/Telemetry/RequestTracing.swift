import FoundationModelsACP
import FoundationModelsExtras
import Logging
import Tracing

/// The server span of each ACP request that the agent serves (the approved
/// OpenTelemetry design, items 1, 3, 4 and 8).
///
/// Each span has the kind `.server`, and it carries the ACP method and, when
/// the request names one, the ACP session id. A request that throws records
/// the error on its span, and the span carries the type name of the error,
/// never its message. The span name and each attribute come from
/// ``ACPAgentTelemetry``, and the "No content" rule of that type applies.
///
/// The span opens through ``ACPAgentTelemetry/tracer(explicit:)`` when the
/// request starts. The work of the request runs in the `ServiceContext` of the
/// span, so a span that Router opens for that work is a child of the request
/// span.
///
/// Hang detection (design item 8): a request that can wait for a long time
/// also writes one "enter" log record when it starts. A tracing backend
/// exports a span only when the span ends, but it exports the record at once.
enum RequestTracing {
    /// Runs `body` in a new server span of one ACP request. The span ends when
    /// `body` returns or throws.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - method: The ACP method of the request.
    ///   - sessionId: The ACP session id that the request names, or `nil`.
    ///   - body: The work of the request. It gets the open span, and it runs
    ///     on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    nonisolated(nonsending) static func withRequestSpan<Output>(
        _ spanName: String,
        method: String,
        sessionId: SessionId?,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async rethrows -> Output {
        try await ACPAgentTelemetry.tracer(explicit: nil).withSpan(spanName, ofKind: .server) { span in
            span.updateAttributes { describeRequest(&$0, method: method, sessionId: sessionId) }
            return try await recordingErrorType(on: span, body)
        }
    }

    /// Runs `body` in a new server span of one ACP request, and writes one
    /// "enter" log record when the span opens. The span ends when `body`
    /// returns or throws.
    ///
    /// `TracedCall.run` of FoundationModelsExtras opens the span and writes
    /// the record, so the record holds the trace id and the span id of the
    /// span when the tracer gives them.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - method: The ACP method of the request.
    ///   - sessionId: The ACP session id that the request names, or `nil`.
    ///   - logger: The logger of the "enter" record.
    ///   - body: The work of the request. It gets the open span, and it runs
    ///     on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    nonisolated(nonsending) static func withEnteredRequestSpan<Output>(
        _ spanName: String,
        method: String,
        sessionId: SessionId?,
        logger: Logger,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        try await TracedCall.run(
            spanName,
            ofKind: .server,
            tracer: ACPAgentTelemetry.tracer(explicit: nil),
            logger: logger,
            attributes: { describeRequest(&$0, method: method, sessionId: sessionId) },
            metadata: requestMetadata(method: method, sessionId: sessionId)
        ) { span in
            try await recordingErrorType(on: span, body)
        }
    }

    /// Opens the server span of one ACP request whose work goes on after its
    /// handler returns, and writes one "enter" log record.
    ///
    /// A `session/prompt` returns `{}` at once, and its model work runs after
    /// that response. Thus its span must stay open after the handler returns,
    /// and a closure helper such as `TracedCall.run` cannot hold it. The caller
    /// ends the span: with ``endRequestSpan(_:throwing:)`` when the request
    /// fails, or with `end()` when its work is done. The record has the form
    /// that `TracedCall` writes.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - method: The ACP method of the request.
    ///   - sessionId: The ACP session id that the request names.
    ///   - logger: The logger of the "enter" record.
    /// - Returns: The open span. Its parent is the current `ServiceContext`.
    static func startRequestSpan(
        _ spanName: String, method: String, sessionId: SessionId, logger: Logger
    ) -> any Span {
        let tracer = ACPAgentTelemetry.tracer(explicit: nil)
        let span = tracer.startSpan(spanName, ofKind: .server)
        span.updateAttributes { describeRequest(&$0, method: method, sessionId: sessionId) }
        var metadata = requestMetadata(method: method, sessionId: sessionId)
        if let identity = SpanIdentity(context: span.context, tracer: tracer) {
            metadata[ACPAgentTelemetry.LogMetadataKey.traceId] = "\(identity.traceID)"
            metadata[ACPAgentTelemetry.LogMetadataKey.spanId] = "\(identity.spanID)"
        }
        logger.log(
            level: TracedCall.enterLevel, "\(ACPAgentTelemetry.enterMessage(forSpanNamed: spanName))",
            metadata: metadata)
        return span
    }

    /// Records `error` on the span of a request that failed, and ends the
    /// span.
    ///
    /// The span records the error and the error status, as `withSpan` does,
    /// and it carries the type name of the error.
    ///
    /// - Parameters:
    ///   - span: The span that ``startRequestSpan(_:method:sessionId:logger:)``
    ///     opened.
    ///   - error: The error of the request.
    static func endRequestSpan(_ span: any Span, throwing error: any Error) {
        span.recordError(error)
        span.setStatus(SpanStatus(code: .error))
        recordErrorType(of: error, on: span)
        span.end()
    }

    /// Ends the span of a prompt that ran, with the stop reason that ended
    /// it.
    ///
    /// - Parameters:
    ///   - span: The span that ``startRequestSpan(_:method:sessionId:logger:)``
    ///     opened for the prompt.
    ///   - stopReason: The stop reason of the prompt, or `nil` when the prompt
    ///     sent no stop reason.
    static func endPromptSpan(_ span: any Span, stopReason: StopReason?) {
        if let stopReason {
            span.attributes[ACPAgentTelemetry.AttributeKey.promptStopReason] = stopReason.wireValue
        }
        span.end()
    }

    /// Runs `body`, and puts the type name of the error on `span` when `body`
    /// throws.
    ///
    /// - Parameters:
    ///   - span: The span of the request.
    ///   - body: The work of the request.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    private nonisolated(nonsending) static func recordingErrorType<Output>(
        on span: any Span,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async rethrows -> Output {
        do {
            return try await body(span)
        } catch {
            recordErrorType(of: error, on: span)
            throw error
        }
    }

    /// Puts the type name of `error` on `span`, never the error message.
    ///
    /// - Parameters:
    ///   - error: The error of the request.
    ///   - span: The span of the request.
    private static func recordErrorType(of error: any Error, on span: any Span) {
        span.attributes[ACPAgentTelemetry.AttributeKey.errorType] = ACPAgentTelemetry.errorTypeName(of: error)
    }

    /// Writes the attributes that name one request: its ACP method, and its
    /// session id when it names one.
    ///
    /// - Parameters:
    ///   - attributes: The attributes of the span of the request.
    ///   - method: The ACP method of the request.
    ///   - sessionId: The ACP session id that the request names, or `nil`.
    private static func describeRequest(
        _ attributes: inout SpanAttributes, method: String, sessionId: SessionId?
    ) {
        attributes[ACPAgentTelemetry.AttributeKey.acpMethod] = method
        if let sessionId {
            attributes[ACPAgentTelemetry.AttributeKey.sessionId] = sessionId.rawValue
        }
    }

    /// The metadata of the "enter" record of one request: its ACP method, and
    /// its session id when it names one.
    ///
    /// - Parameters:
    ///   - method: The ACP method of the request.
    ///   - sessionId: The ACP session id that the request names, or `nil`.
    /// - Returns: The ``ACPAgentTelemetry/LogMetadataKey/acpMethod`` value, and
    ///   the ``ACPAgentTelemetry/LogMetadataKey/sessionId`` value when there is
    ///   a session id.
    private static func requestMetadata(method: String, sessionId: SessionId?) -> Logger.Metadata {
        var metadata = sessionId.map(ACPAgentTelemetry.sessionMetadata) ?? [:]
        metadata[ACPAgentTelemetry.LogMetadataKey.acpMethod] = "\(method)"
        return metadata
    }
}

extension AgentSideConnection {
    /// Registers `work` to run after the response of the current request,
    /// as `afterRespondingToCurrentRequest(_:)` does, and runs it in the
    /// `ServiceContext` of the caller.
    ///
    /// The connection runs the deferred work after the handler returned, so
    /// the task-local `ServiceContext` of the handler does not reach it. This
    /// method keeps that context, thus a span that the work opens, such as a
    /// Router submission span, is a child of the request span.
    ///
    /// - Parameter work: The deferred work.
    func afterRespondingInCurrentServiceContext(_ work: @escaping @Sendable () async -> Void) {
        let serviceContext = ServiceContext.current
        afterRespondingToCurrentRequest {
            await ServiceContext.withValue(serviceContext) {
                await work()
            }
        }
    }
}
