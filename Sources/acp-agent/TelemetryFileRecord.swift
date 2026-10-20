import Foundation
import FoundationModelsACP

/// The parts that each line of the telemetry file shares: the `type` key that
/// says which of the three records the line is, the time format, and the
/// type name that stands in place of an error.
///
/// A key of a record is part of the file format. A reader of the file (a
/// bench harness, a query) uses it, so change a key only as a deliberate
/// break.
enum TelemetryFileRecord {
    /// The value of the `type` key: which record the line is.
    enum Kind: String {
        /// One log record of swift-log.
        case log

        /// One span of swift-distributed-tracing, when it ends.
        case span

        /// One recording of a swift-metrics metric.
        case metric
    }

    /// The key that names the kind of the record.
    static let typeKey = "type"

    /// The key of the time of a log record and of a metric recording.
    static let timestampKey = "ts"

    /// The time format: ISO 8601 in UTC, with milliseconds.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The number of nanoseconds in one second.
    private static let nanosecondsPerSecond = 1_000_000_000.0

    /// Makes one record of `kind` from its own `fields`.
    ///
    /// - Parameters:
    ///   - kind: The kind of the record.
    ///   - fields: The keys of the record, without ``typeKey``.
    /// - Returns: The fields with ``typeKey`` added. The type wins over a
    ///   field of the same key.
    static func make(_ kind: Kind, fields: [String: JSONValue]) -> [String: JSONValue] {
        fields.merging([typeKey: .string(kind.rawValue)]) { _, type in type }
    }

    /// The text of `date` in the time format of the file.
    ///
    /// - Parameter date: The time.
    /// - Returns: For example `2026-10-20T17:04:05.123Z`.
    static func timestamp(_ date: Date) -> JSONValue {
        .string(timestampStyle.format(date))
    }

    /// The text of a tracing instant in the time format of the file.
    ///
    /// - Parameter nanoseconds: The nanoseconds since the UNIX epoch.
    /// - Returns: The time text.
    static func timestamp(nanosecondsSinceEpoch nanoseconds: UInt64) -> JSONValue {
        timestamp(Date(timeIntervalSince1970: Double(nanoseconds) / nanosecondsPerSecond))
    }

    /// The type name that the file writes in place of an error.
    ///
    /// Never the description of the error: a description can hold content
    /// (a prompt, a tool output, a URL with a secret), and the "No content"
    /// rule of `ACPAgentTelemetry` applies to this file as it does to each
    /// other telemetry backend. `ACPAgentTelemetry.errorTypeName(of:)` gives
    /// the same text for the `error.type` attribute.
    ///
    /// - Parameter error: The error.
    /// - Returns: The full type name, with its module.
    static func errorTypeName(of error: any Error) -> JSONValue {
        .string(String(reflecting: type(of: error)))
    }
}
