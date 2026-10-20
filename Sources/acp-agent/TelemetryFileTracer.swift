import FoundationModelsExtras
import Tracing

/// The tracer of `acp --telemetry-file`: each span writes one line to the
/// file when it ends.
///
/// The tracer makes W3C ids itself: a trace id of 32 hexadecimal digits and
/// a span id of 16. A span takes the trace id of the span in its parent
/// context, and names that span as its parent, so the lines of one trace
/// join by `traceId` and nest by `parentSpanId`. The ids go into the
/// `InstrumentationContext` of the span under ``TelemetryFileSpanContextKey``,
/// and the family packages hand that context to each child span.
///
/// ``inject(_:into:using:)`` writes a W3C `traceparent` value. Thus
/// `SpanIdentity` of Extras reads the ids of a span, and the "enter" log
/// record of `TracedCall` carries the same `trace.id` and `span.id` as the
/// span line. ``extract(_:into:using:)`` reads a `traceparent` value back,
/// so a span under a remote parent joins the trace of that parent.
struct TelemetryFileTracer: Tracer {
    /// The writer of the telemetry file.
    let writer: TelemetryFileWriter

    /// Starts a span, under the span of `context` when it has one.
    ///
    /// - Parameters:
    ///   - operationName: The name of the span.
    ///   - context: The parent context.
    ///   - kind: The kind of the span.
    ///   - instant: The start time.
    ///   - function: The function that starts the span.
    ///   - fileID: The file that starts the span.
    ///   - line: The line that starts the span.
    /// - Returns: The span, which writes its line when it ends.
    func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> InstrumentationContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> TelemetryFileSpan {
        var spanContext = context()
        let parent = spanContext.telemetryFileSpanContext
        let ids = parent.map(TelemetryFileSpanContext.makeChild(of:)) ?? TelemetryFileSpanContext.makeRoot()
        spanContext.telemetryFileSpanContext = ids
        return TelemetryFileSpan(
            operationName: operationName, ids: ids, context: spanContext, parentSpanId: parent?.spanId,
            kind: kind, startNanoseconds: instant().nanosecondsSinceEpoch, writer: writer)
    }

    /// Does nothing: each line is in the file when its span ends.
    func forceFlush() {}

    /// Writes the W3C `traceparent` value of the span of `context`.
    ///
    /// - Parameters:
    ///   - context: The context of the span.
    ///   - carrier: The carrier that gets the value.
    ///   - injector: The writer of the carrier.
    func inject<Carrier, Inject: Injector>(
        _ context: InstrumentationContext, into carrier: inout Carrier, using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let ids = context.telemetryFileSpanContext,
            let identity = SpanIdentity(traceID: ids.traceId, spanID: ids.spanId)
        else { return }
        injector.inject(identity.traceparent, forKey: SpanIdentity.traceparentField, into: &carrier)
    }

    /// Reads a W3C `traceparent` value into `context`, as the remote parent
    /// of the next span.
    ///
    /// - Parameters:
    ///   - carrier: The carrier that holds the value.
    ///   - context: The context that gets the ids.
    ///   - extractor: The reader of the carrier.
    func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier, into context: inout InstrumentationContext, using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let traceparent = extractor.extract(key: SpanIdentity.traceparentField, from: carrier),
            let identity = SpanIdentity(traceparent: traceparent)
        else { return }
        context.telemetryFileSpanContext = TelemetryFileSpanContext(
            traceId: identity.traceID, spanId: identity.spanID)
    }
}

/// The W3C ids of one span of the telemetry file.
struct TelemetryFileSpanContext: Sendable, Hashable {
    /// The trace id: 32 lowercase hexadecimal digits.
    let traceId: String

    /// The span id: 16 lowercase hexadecimal digits.
    let spanId: String

    /// The number of hexadecimal digits of one random 64-bit word, which is
    /// the length of a span id.
    private static let digitsPerWord = SpanIdentity.spanIDLength

    /// The number of random words of a trace id.
    private static let wordsPerTraceId = SpanIdentity.traceIDLength / SpanIdentity.spanIDLength

    /// The radix of a hexadecimal digit.
    private static let hexadecimalRadix = 16

    /// Makes the ids of a span with no parent: a new trace.
    ///
    /// - Returns: A new trace id and a new span id.
    static func makeRoot() -> Self {
        Self(traceId: makeIdentifier(wordCount: wordsPerTraceId), spanId: makeIdentifier(wordCount: 1))
    }

    /// Makes the ids of a span under `parent`: the same trace, a new span.
    ///
    /// - Parameter parent: The ids of the parent span.
    /// - Returns: The trace id of the parent and a new span id.
    static func makeChild(of parent: Self) -> Self {
        Self(traceId: parent.traceId, spanId: makeIdentifier(wordCount: 1))
    }

    /// Makes a random id of `wordCount` 64-bit words in hexadecimal.
    ///
    /// No word is zero, so no id is the all-zero id that W3C makes invalid.
    ///
    /// - Parameter wordCount: The number of words.
    /// - Returns: `wordCount` × 16 lowercase hexadecimal digits.
    private static func makeIdentifier(wordCount: Int) -> String {
        (0..<wordCount).map { _ in hexadecimal(UInt64.random(in: 1...UInt64.max)) }.joined()
    }

    /// The 16 hexadecimal digits of `word`, with leading zeros.
    ///
    /// - Parameter word: The word.
    /// - Returns: The digits.
    private static func hexadecimal(_ word: UInt64) -> String {
        let digits = String(word, radix: hexadecimalRadix)
        return String(repeating: "0", count: digitsPerWord - digits.count) + digits
    }
}

/// The key of the ``TelemetryFileSpanContext`` of a span in its
/// `InstrumentationContext`.
enum TelemetryFileSpanContextKey: InstrumentationContextKey {
    /// The ids of the span.
    typealias Value = TelemetryFileSpanContext
}

extension InstrumentationContext {
    /// The ids of the telemetry-file span of this context, or `nil` when the
    /// context has no such span.
    var telemetryFileSpanContext: TelemetryFileSpanContext? {
        get { self[TelemetryFileSpanContextKey.self] }
        set { self[TelemetryFileSpanContextKey.self] = newValue }
    }
}
