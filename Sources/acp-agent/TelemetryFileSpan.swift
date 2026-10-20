import FoundationModelsACP
import Synchronization
import Tracing

/// One span of ``TelemetryFileTracer``. It keeps its name, attributes,
/// events, errors and status, and writes them as one line when it ends.
///
/// The line is
/// `{"type":"span","name","traceId","spanId","parentSpanId","kind","start","end","durationMs","status","attributes","events","errors","links"}`.
/// `parentSpanId` is `null` for a span with no parent. `status` is `unset`,
/// `ok` or `error`. Each event is `{"name","ts","attributes"}`, each error
/// is `{"type","ts","attributes"}`, and each link is `{"traceId","spanId"}`.
///
/// A span is a class because the `Span` protocol hands one span to many
/// callers, who each add to it. The lock is a `Mutex`, because each method
/// of the protocol is synchronous.
///
/// The "No content" rule of `ACPAgentTelemetry` holds for the line. The
/// name, the attributes and the events are what the agent and the family
/// packages set, and their content-safety tests prove that no one of them
/// holds content. The two texts that no such test covers stay out of the
/// line: a recorded error writes its type name and never its description,
/// and an error status writes `error` and never its message.
final class TelemetryFileSpan: Span {
    /// The context of the span, which holds its ids for each child span.
    let context: InstrumentationContext

    /// The ids of the span.
    private let ids: TelemetryFileSpanContext

    /// The span id of the parent span, or `nil` for a span with no parent.
    private let parentSpanId: String?

    /// The kind of the span.
    private let kind: SpanKind

    /// The start time, in nanoseconds since the UNIX epoch.
    private let startNanoseconds: UInt64

    /// The writer of the telemetry file.
    private let writer: TelemetryFileWriter

    /// The parts of the span that its callers change.
    private let state: Mutex<State>

    /// The number of nanoseconds in one millisecond.
    private static let nanosecondsPerMillisecond = 1_000_000.0

    /// Makes a span that has started.
    ///
    /// - Parameters:
    ///   - operationName: The name of the span.
    ///   - ids: The ids of the span.
    ///   - context: The context of the span, which holds `ids` under
    ///     ``TelemetryFileSpanContextKey`` for each child span.
    ///   - parentSpanId: The span id of the parent, or `nil`.
    ///   - kind: The kind of the span.
    ///   - startNanoseconds: The start time.
    ///   - writer: The writer of the telemetry file.
    init(
        operationName: String, ids: TelemetryFileSpanContext, context: InstrumentationContext,
        parentSpanId: String?, kind: SpanKind, startNanoseconds: UInt64, writer: TelemetryFileWriter
    ) {
        self.context = context
        self.ids = ids
        self.parentSpanId = parentSpanId
        self.kind = kind
        self.startNanoseconds = startNanoseconds
        self.writer = writer
        self.state = Mutex(State(operationName: operationName))
    }

    /// The name of the span.
    var operationName: String {
        get { state.withLock { $0.operationName } }
        set { state.withLock { $0.operationName = newValue } }
    }

    /// The attributes of the span.
    var attributes: SpanAttributes {
        get { state.withLock { $0.attributes } }
        set { state.withLock { $0.attributes = newValue } }
    }

    /// Whether the span has not ended yet.
    var isRecording: Bool {
        state.withLock { !$0.hasEnded }
    }

    /// Sets the status of the span. The line writes its code only.
    ///
    /// - Parameter status: The status.
    func setStatus(_ status: SpanStatus) {
        state.withLock { $0.status = status }
    }

    /// Adds an event to the span.
    ///
    /// - Parameter event: The event.
    func addEvent(_ event: SpanEvent) {
        state.withLock { $0.events.append(event) }
    }

    /// Records an error of the span: its type name, its time and its
    /// attributes. Never its description.
    ///
    /// - Parameters:
    ///   - error: The error.
    ///   - attributes: The attributes of the error.
    ///   - instant: The time of the error.
    func recordError<Instant: TracerInstant>(
        _ error: Error, attributes: SpanAttributes, at instant: @autoclosure () -> Instant
    ) {
        let recorded = RecordedError(
            typeName: TelemetryFileRecord.errorTypeName(of: error),
            nanosecondsSinceEpoch: instant().nanosecondsSinceEpoch, attributes: attributes)
        state.withLock { $0.errors.append(recorded) }
    }

    /// Adds a link to an other span. The ACP client links the span of each
    /// request to the span of its caller. The line keeps the ids of the
    /// linked span, and drops a link to a context that holds no
    /// telemetry-file span.
    ///
    /// - Parameter link: The link.
    func addLink(_ link: SpanLink) {
        guard let linked = link.context.telemetryFileSpanContext else { return }
        state.withLock { $0.links.append(linked) }
    }

    /// Ends the span and writes its line. A second end writes nothing.
    ///
    /// - Parameter instant: The end time.
    func end<Instant: TracerInstant>(at instant: @autoclosure () -> Instant) {
        let endNanoseconds = instant().nanosecondsSinceEpoch
        guard let ended = state.withLock({ $0.end() }) else { return }
        writer.write(TelemetryFileRecord.make(.span, fields: fields(of: ended, endNanoseconds: endNanoseconds)))
    }

    /// The keys of the span line.
    ///
    /// - Parameters:
    ///   - ended: The state of the span when it ended.
    ///   - endNanoseconds: The end time.
    /// - Returns: Each key of the line but the type.
    private func fields(of ended: State, endNanoseconds: UInt64) -> [String: JSONValue] {
        let durationNanoseconds = max(Double(endNanoseconds) - Double(startNanoseconds), 0)
        return [
            "name": .string(ended.operationName),
            "traceId": .string(ids.traceId),
            "spanId": .string(ids.spanId),
            "parentSpanId": parentSpanId.map(JSONValue.string) ?? .null,
            "kind": .string(String(describing: kind)),
            "start": TelemetryFileRecord.timestamp(nanosecondsSinceEpoch: startNanoseconds),
            "end": TelemetryFileRecord.timestamp(nanosecondsSinceEpoch: endNanoseconds),
            "durationMs": .number(durationNanoseconds / Self.nanosecondsPerMillisecond),
            "status": .string(Self.statusName(of: ended.status)),
            "attributes": ended.attributes.telemetryFileValue,
            "events": .array(ended.events.map(Self.eventValue(of:))),
            "errors": .array(ended.errors.map(\.telemetryFileValue)),
            "links": .array(ended.links.map(Self.linkValue(of:))),
        ]
    }

    /// The JSON form of one link: the ids of the linked span.
    ///
    /// - Parameter linked: The ids of the linked span.
    /// - Returns: The link object.
    private static func linkValue(of linked: TelemetryFileSpanContext) -> JSONValue {
        .object(["traceId": .string(linked.traceId), "spanId": .string(linked.spanId)])
    }

    /// The status code of the line.
    ///
    /// - Parameter status: The status of the span, or `nil` when no caller
    ///   set one.
    /// - Returns: `unset`, `ok` or `error`.
    private static func statusName(of status: SpanStatus?) -> String {
        switch status?.code {
        case nil: "unset"
        case .ok: "ok"
        case .error: "error"
        }
    }

    /// The JSON form of one event: its name, time and attributes.
    ///
    /// - Parameter event: The event.
    /// - Returns: The event object.
    private static func eventValue(of event: SpanEvent) -> JSONValue {
        .object([
            "name": .string(event.name),
            TelemetryFileRecord.timestampKey: TelemetryFileRecord.timestamp(
                nanosecondsSinceEpoch: event.nanosecondsSinceEpoch),
            "attributes": event.attributes.telemetryFileValue,
        ])
    }

    /// One error that the span recorded, without its description.
    private struct RecordedError {
        /// The type name of the error.
        let typeName: JSONValue

        /// The time of the error, in nanoseconds since the UNIX epoch.
        let nanosecondsSinceEpoch: UInt64

        /// The attributes of the error.
        let attributes: SpanAttributes

        /// The JSON form of the error: its type, time and attributes.
        var telemetryFileValue: JSONValue {
            .object([
                TelemetryFileRecord.typeKey: typeName,
                TelemetryFileRecord.timestampKey: TelemetryFileRecord.timestamp(
                    nanosecondsSinceEpoch: nanosecondsSinceEpoch),
                "attributes": attributes.telemetryFileValue,
            ])
        }
    }

    /// The parts of the span that its callers change, under the lock.
    private struct State {
        /// The name of the span.
        var operationName: String

        /// The attributes of the span.
        var attributes: SpanAttributes = [:]

        /// The events of the span, in the order they were added.
        var events: [SpanEvent] = []

        /// The errors of the span, in the order they were recorded.
        var errors: [RecordedError] = []

        /// The ids of each linked span, in the order they were added.
        var links: [TelemetryFileSpanContext] = []

        /// The status of the span, or `nil` when no caller set one.
        var status: SpanStatus?

        /// Whether the span has ended.
        var hasEnded = false

        /// Marks the span as ended.
        ///
        /// - Returns: The state at the end, or `nil` when the span had
        ///   already ended, so that only the first end writes a line.
        mutating func end() -> State? {
            guard !hasEnded else { return nil }
            hasEnded = true
            return self
        }
    }
}

extension SpanAttributes {
    /// The JSON object of the attributes.
    var telemetryFileValue: JSONValue {
        var members: [String: JSONValue] = [:]
        func collect(_ key: String, _ attribute: SpanAttribute) {
            members[key] = attribute.telemetryFileValue
        }
        forEach(collect)
        return .object(members)
    }
}

extension SpanAttribute {
    /// The JSON form of the attribute: a number, a Boolean, a string, or an
    /// array of one of them.
    var telemetryFileValue: JSONValue {
        switch self {
        case .int32(let value): .number(Double(value))
        case .int64(let value): .number(Double(value))
        case .int32Array(let values): .array(values.map { .number(Double($0)) })
        case .int64Array(let values): .array(values.map { .number(Double($0)) })
        case .double(let value): .number(value)
        case .doubleArray(let values): .array(values.map(JSONValue.number))
        case .bool(let value): .bool(value)
        case .boolArray(let values): .array(values.map(JSONValue.bool))
        case .string(let value): .string(value)
        case .stringArray(let values): .array(values.map(JSONValue.string))
        case .stringConvertible(let value): .string(value.description)
        case .stringConvertibleArray(let values): .array(values.map { .string($0.description) })
        default: .string(String(describing: self))
        }
    }
}
