import Foundation
import FoundationModelsACP
import Logging

/// The log handler of `acp --telemetry-file`: one line for each log record
/// at ``defaultLogLevel`` and up.
///
/// The line is
/// `{"type":"log","ts","level","label","message","source","file","line","metadata"}`,
/// and `"error"` when the record carries an error. The metadata is the
/// metadata of the handler, then of its metadata provider, then of the
/// record: a later source wins for the same key, as in `StreamLogHandler`.
///
/// The error of a record is its type name only. The "No content" rule of
/// `ACPAgentTelemetry` covers each log message and metadata value of the
/// agent, and `TelemetryContentSafetyTests` proves it; the description of an
/// error is not under that proof, so the file never writes it.
struct TelemetryFileLogHandler: LogHandler {
    /// The lowest level the file gets. The family packages write their
    /// diagnostic records at `debug`, which stderr drops at its `warning`
    /// level, and the file is where a run is read back after the fact.
    static let defaultLogLevel: Logger.Level = .debug

    /// The label of the logger.
    let label: String

    /// The writer of the telemetry file.
    let writer: TelemetryFileWriter

    /// The lowest level that this handler writes.
    var logLevel: Logger.Level = TelemetryFileLogHandler.defaultLogLevel

    /// The metadata of the logger.
    var metadata: Logger.Metadata = [:]

    /// The provider of the task-local metadata of the logger.
    var metadataProvider: Logger.MetadataProvider?

    /// One metadata value of the logger.
    ///
    /// - Parameter key: The metadata key.
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Writes `event` as one log line.
    ///
    /// - Parameter event: The log record.
    func log(event: LogEvent) {
        writer.write(TelemetryFileRecord.make(.log, fields: fields(of: event)))
    }

    /// The keys of the log line of `event`.
    ///
    /// - Parameter event: The log record.
    /// - Returns: Each key of the line but the type.
    private func fields(of event: LogEvent) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            TelemetryFileRecord.timestampKey: TelemetryFileRecord.timestamp(Date()),
            "level": .string(event.level.rawValue),
            "label": .string(label),
            "message": .string(event.message.description),
            "source": .string(event.source),
            "file": .string(event.file),
            "line": .number(Double(event.line)),
            "metadata": .object(mergedMetadata(event.metadata).mapValues(\.telemetryFileValue)),
        ]
        if let error = event.error {
            fields["error"] = TelemetryFileRecord.errorTypeName(of: error)
        }
        return fields
    }

    /// The metadata of the handler, of its provider and of the record, in
    /// that order of priority from low to high.
    ///
    /// - Parameter recordMetadata: The metadata of the record.
    /// - Returns: The merged metadata.
    private func mergedMetadata(_ recordMetadata: Logger.Metadata?) -> Logger.Metadata {
        metadata
            .merging(metadataProvider?.get() ?? [:]) { _, provided in provided }
            .merging(recordMetadata ?? [:]) { _, recorded in recorded }
    }
}

extension Logger.MetadataValue {
    /// The JSON form of the metadata value: a string, an object or an array.
    var telemetryFileValue: JSONValue {
        switch self {
        case .string(let text):
            .string(text)
        case .stringConvertible(let value):
            .string(value.description)
        case .dictionary(let members):
            .object(members.mapValues(\.telemetryFileValue))
        case .array(let values):
            .array(values.map(\.telemetryFileValue))
        }
    }
}
