import FoundationModelsExtras
import Logging
import Tracing

/// The internal spans of the agent: the work inside one request that the
/// request span of ``RequestTracing`` does not show by itself (the approved
/// OpenTelemetry design, items 3, 4 and 8).
///
/// Each span has the kind `.internal`. It opens through
/// ``ACPAgentTelemetry/tracer(explicit:)`` in the current `ServiceContext`,
/// thus it is a child of the span of the request that does the work.
/// ``RequestTracing`` also opens its server spans through
/// ``withSpan(_:context:ofKind:_:)``, with a different kind and parent. A body
/// that throws gives the span the error status and the type of the error,
/// never its description. The span records no error with `recordError`,
/// because a tracing backend exports the description of a recorded error as
/// `exception.message`, and a description can hold content. The "No content"
/// rule of ``ACPAgentTelemetry`` applies to each span name, attribute and
/// metadata value.
enum AgentTracing {
    /// Runs `body` in a new span. The span ends when `body` returns or
    /// throws.
    ///
    /// The span opens with `startSpan`, not with `withSpan` of the tracer,
    /// because `withSpan` records each error of its body with `recordError`.
    /// When `body` throws, ``recordFailure(of:on:)`` gives the span the error
    /// status and the type name of the error.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - context: The parent context of the span. The default is the
    ///     current `ServiceContext`.
    ///   - kind: The kind of the span. The default is `.internal`.
    ///   - body: The work. It gets the open span, and it runs on the actor of
    ///     the caller, in the `ServiceContext` of the span.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   error type first.
    nonisolated(nonsending) static func withSpan<Output>(
        _ spanName: String,
        context: @autoclosure () -> ServiceContext = .current ?? .topLevel,
        ofKind kind: SpanKind = .internal,
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async rethrows -> Output {
        let span = ACPAgentTelemetry.tracer(explicit: nil).startSpan(spanName, context: context(), ofKind: kind)
        defer { span.end() }
        do {
            return try await ServiceContext.withValue(span.context) {
                try await body(span)
            }
        } catch {
            recordFailure(of: error, on: span)
            throw error
        }
    }

    /// Runs `body` in a new internal span, and writes one "enter" log record
    /// when the span opens (design item 8). Use it for work that can wait for
    /// a long time, so a hang shows as a record with no span that ends.
    ///
    /// `TracedCall.run` of FoundationModelsExtras opens the span and writes
    /// the record, so the record holds the trace id and the span id of the
    /// span when the tracer gives them. When `body` throws, `TracedCall.run`
    /// gives the span the error status and the `error.type` of the error, and
    /// records no error. Thus this method writes no `error.type` itself.
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
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   error type first.
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
            metadata: metadata,
            body
        )
    }

    /// Gives `span` the error status and the type name of `error`.
    ///
    /// The span gets no recorded error, no status message and no description
    /// of the error, because a description can hold content.
    ///
    /// - Parameters:
    ///   - error: The error of the work.
    ///   - span: The span of the work.
    static func recordFailure(of error: any Error, on span: any Span) {
        span.setStatus(SpanStatus(code: .error))
        span.attributes[ACPAgentTelemetry.AttributeKey.errorType] = ACPAgentTelemetry.errorTypeName(of: error)
    }
}
