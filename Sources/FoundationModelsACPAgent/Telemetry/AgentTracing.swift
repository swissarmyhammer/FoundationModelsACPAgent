import FoundationModelsExtras
import Logging
import Tracing

/// The internal spans of the agent: the work inside one request that the
/// request span of ``RequestTracing`` does not show by itself (the approved
/// OpenTelemetry design, items 3, 4 and 8).
///
/// Each span has the kind `.internal`. It opens through
/// ``ACPAgentTelemetry/tracer(explicit:)`` in the current `ServiceContext`,
/// thus it is a child of the span of the request that does the work. A body
/// that throws records the error on the span, and the span carries the type
/// name of the error, never its message. The "No content" rule of
/// ``ACPAgentTelemetry`` applies to each span name, attribute and metadata
/// value.
enum AgentTracing {
    /// Runs `body` in a new internal span. The span ends when `body` returns
    /// or throws.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - body: The work. It gets the open span, and it runs on the actor of
    ///     the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    nonisolated(nonsending) static func withSpan<Output>(
        _ spanName: String,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async rethrows -> Output {
        try await ACPAgentTelemetry.tracer(explicit: nil).withSpan(spanName, ofKind: .internal) { span in
            try await recordingErrorType(on: span, body)
        }
    }

    /// Runs `body` in a new internal span, and writes one "enter" log record
    /// when the span opens (design item 8). Use it for work that can wait for
    /// a long time, so a hang shows as a record with no span that ends.
    ///
    /// `TracedCall.run` of FoundationModelsExtras opens the span and writes
    /// the record, so the record holds the trace id and the span id of the
    /// span when the tracer gives them.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - logger: The logger of the "enter" record.
    ///   - attributes: Sets the attributes of the span before the record is
    ///     written.
    ///   - metadata: The metadata of the "enter" record.
    ///   - body: The work. It gets the open span, and it runs on the actor of
    ///     the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    nonisolated(nonsending) static func withEnteredSpan<Output>(
        _ spanName: String,
        logger: Logger,
        attributes: (inout SpanAttributes) -> Void,
        metadata: Logger.Metadata,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        try await TracedCall.run(
            spanName,
            tracer: ACPAgentTelemetry.tracer(explicit: nil),
            logger: logger,
            attributes: attributes,
            metadata: metadata
        ) { span in
            try await recordingErrorType(on: span, body)
        }
    }

    /// Runs `body`, and puts the type name of the error on `span` when `body`
    /// throws.
    ///
    /// - Parameters:
    ///   - span: The span of the work.
    ///   - body: The work.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    nonisolated(nonsending) static func recordingErrorType<Output>(
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
    ///   - error: The error of the work.
    ///   - span: The span of the work.
    static func recordErrorType(of error: any Error, on span: any Span) {
        span.attributes[ACPAgentTelemetry.AttributeKey.errorType] = ACPAgentTelemetry.errorTypeName(of: error)
    }
}
