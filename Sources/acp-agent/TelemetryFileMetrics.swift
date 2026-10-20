import Foundation
import FoundationModelsACP
import Metrics

/// The metrics factory of `acp --telemetry-file`: each call of a metric
/// writes one line to the file.
///
/// The line is
/// `{"type":"metric","ts","kind","label","dimensions","operation","value"}`.
/// `kind` is `counter`, `floatingPointCounter`, `recorder`, `timer` or
/// `meter`. `operation` names the call (`increment`, `decrement`, `reset`,
/// `set` or `record`), and `value` is its argument: the amount of an
/// increment or a decrement, `0` for a reset, the value of a set or a
/// record, and the nanoseconds of a timer.
///
/// A line is one call and never a running total. The agent and the family
/// packages make a new metric for each recording (see `AgentMetrics`), so a
/// handler sees one call and no total that it could keep. A reader sums the
/// `increment` lines of a counter.
///
/// The factory keeps no handler, so a destroy has nothing to release.
struct TelemetryFileMetricsFactory: MetricsFactory {
    /// The writer of the telemetry file.
    let writer: TelemetryFileWriter

    /// Makes a counter.
    ///
    /// - Parameters:
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    /// - Returns: A counter that writes each call.
    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        TelemetryFileCounter(metric: makeMetric(.counter, label: label, dimensions: dimensions))
    }

    /// Makes a floating-point counter.
    ///
    /// - Parameters:
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    /// - Returns: A floating-point counter that writes each call.
    func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler {
        TelemetryFileFloatingPointCounter(
            metric: makeMetric(.floatingPointCounter, label: label, dimensions: dimensions))
    }

    /// Makes a recorder. A gauge is a recorder that does not aggregate; the
    /// file writes each value either way.
    ///
    /// - Parameters:
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    ///   - aggregate: Whether the backend aggregates the values. The file does
    ///     not.
    /// - Returns: A recorder that writes each value.
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        TelemetryFileRecorder(metric: makeMetric(.recorder, label: label, dimensions: dimensions))
    }

    /// Makes a timer.
    ///
    /// - Parameters:
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    /// - Returns: A timer that writes each duration in nanoseconds.
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        TelemetryFileTimer(metric: makeMetric(.timer, label: label, dimensions: dimensions))
    }

    /// Makes a meter.
    ///
    /// - Parameters:
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    /// - Returns: A meter that writes each call.
    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        TelemetryFileMeter(metric: makeMetric(.meter, label: label, dimensions: dimensions))
    }

    /// Does nothing: the factory keeps no counter.
    ///
    /// - Parameter handler: The counter.
    func destroyCounter(_ handler: CounterHandler) {}

    /// Does nothing: the factory keeps no recorder.
    ///
    /// - Parameter handler: The recorder.
    func destroyRecorder(_ handler: RecorderHandler) {}

    /// Does nothing: the factory keeps no timer.
    ///
    /// - Parameter handler: The timer.
    func destroyTimer(_ handler: TimerHandler) {}

    /// Makes the metric that a handler writes through.
    ///
    /// - Parameters:
    ///   - kind: The kind of the metric.
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric.
    /// - Returns: The metric.
    private func makeMetric(
        _ kind: TelemetryFileMetric.Kind, label: String, dimensions: [(String, String)]
    ) -> TelemetryFileMetric {
        TelemetryFileMetric(kind: kind, label: label, dimensions: dimensions, writer: writer)
    }
}

/// One metric of the telemetry file: what each line of its handler names.
struct TelemetryFileMetric: Sendable {
    /// The value of the `kind` key: the swift-metrics handler type.
    enum Kind: String {
        /// A `CounterHandler`.
        case counter

        /// A `FloatingPointCounterHandler`.
        case floatingPointCounter

        /// A `RecorderHandler`, which a gauge is too.
        case recorder

        /// A `TimerHandler`.
        case timer

        /// A `MeterHandler`.
        case meter
    }

    /// The value of the `operation` key: the handler call.
    enum Operation: String {
        /// An increment of a counter or a meter by the value.
        case increment

        /// A decrement of a meter by the value.
        case decrement

        /// A reset of a counter to zero.
        case reset

        /// A set of a meter to the value.
        case set

        /// One value of a recorder or a timer.
        case record
    }

    /// The kind of the metric.
    let kind: Kind

    /// The name of the metric.
    let label: String

    /// The dimensions of the metric, in the order the caller gave them.
    let dimensions: [(String, String)]

    /// The writer of the telemetry file.
    let writer: TelemetryFileWriter

    /// Writes one line for one call.
    ///
    /// - Parameters:
    ///   - value: The argument of the call.
    ///   - operation: The call.
    func write(_ value: Double, operation: Operation) {
        writer.write(
            TelemetryFileRecord.make(
                .metric,
                fields: [
                    TelemetryFileRecord.timestampKey: TelemetryFileRecord.timestamp(Date()),
                    "kind": .string(kind.rawValue),
                    "label": .string(label),
                    "dimensions": dimensionsValue,
                    "operation": .string(operation.rawValue),
                    "value": .number(value),
                ]))
    }

    /// The dimensions as one JSON object. A key that the caller gave twice
    /// keeps its last value.
    private var dimensionsValue: JSONValue {
        .object(Dictionary(dimensions, uniquingKeysWith: { _, last in last }).mapValues(JSONValue.string))
    }
}

/// The counter of the telemetry file.
final class TelemetryFileCounter: CounterHandler {
    /// The metric that each call writes.
    private let metric: TelemetryFileMetric

    /// Makes the counter of `metric`.
    ///
    /// - Parameter metric: The metric.
    init(metric: TelemetryFileMetric) {
        self.metric = metric
    }

    /// Writes an `increment` line.
    ///
    /// - Parameter amount: The amount.
    func increment(by amount: Int64) {
        metric.write(Double(amount), operation: .increment)
    }

    /// Writes a `reset` line with the value `0`.
    func reset() {
        metric.write(0, operation: .reset)
    }
}

/// The floating-point counter of the telemetry file.
final class TelemetryFileFloatingPointCounter: FloatingPointCounterHandler {
    /// The metric that each call writes.
    private let metric: TelemetryFileMetric

    /// Makes the counter of `metric`.
    ///
    /// - Parameter metric: The metric.
    init(metric: TelemetryFileMetric) {
        self.metric = metric
    }

    /// Writes an `increment` line.
    ///
    /// - Parameter amount: The amount.
    func increment(by amount: Double) {
        metric.write(amount, operation: .increment)
    }

    /// Writes a `reset` line with the value `0`.
    func reset() {
        metric.write(0, operation: .reset)
    }
}

/// The recorder of the telemetry file, and so its gauge too.
final class TelemetryFileRecorder: RecorderHandler {
    /// The metric that each call writes.
    private let metric: TelemetryFileMetric

    /// Makes the recorder of `metric`.
    ///
    /// - Parameter metric: The metric.
    init(metric: TelemetryFileMetric) {
        self.metric = metric
    }

    /// Writes a `record` line.
    ///
    /// - Parameter value: The value.
    func record(_ value: Int64) {
        metric.write(Double(value), operation: .record)
    }

    /// Writes a `record` line.
    ///
    /// - Parameter value: The value.
    func record(_ value: Double) {
        metric.write(value, operation: .record)
    }
}

/// The timer of the telemetry file.
final class TelemetryFileTimer: TimerHandler {
    /// The metric that each call writes.
    private let metric: TelemetryFileMetric

    /// Makes the timer of `metric`.
    ///
    /// - Parameter metric: The metric.
    init(metric: TelemetryFileMetric) {
        self.metric = metric
    }

    /// Writes a `record` line with the duration in nanoseconds.
    ///
    /// - Parameter duration: The duration in nanoseconds.
    func recordNanoseconds(_ duration: Int64) {
        metric.write(Double(duration), operation: .record)
    }
}

/// The meter of the telemetry file.
final class TelemetryFileMeter: MeterHandler {
    /// The metric that each call writes.
    private let metric: TelemetryFileMetric

    /// Makes the meter of `metric`.
    ///
    /// - Parameter metric: The metric.
    init(metric: TelemetryFileMetric) {
        self.metric = metric
    }

    /// Writes a `set` line.
    ///
    /// - Parameter value: The value.
    func set(_ value: Int64) {
        metric.write(Double(value), operation: .set)
    }

    /// Writes a `set` line.
    ///
    /// - Parameter value: The value.
    func set(_ value: Double) {
        metric.write(value, operation: .set)
    }

    /// Writes an `increment` line.
    ///
    /// - Parameter amount: The amount.
    func increment(by amount: Double) {
        metric.write(amount, operation: .increment)
    }

    /// Writes a `decrement` line.
    ///
    /// - Parameter amount: The amount.
    func decrement(by amount: Double) {
        metric.write(amount, operation: .decrement)
    }
}
