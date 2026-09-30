import FoundationModelsExtras
import InMemoryTracing
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The spans and the log records of one traced run, and the id of its
/// session.
///
/// A telemetry suite reads the context of its capture into this value at the
/// end of the run, and makes its assertions after the capture ended.
struct TracedRun {
    /// The message and the metadata of one log record of the run.
    struct LogRecord {
        /// The message of the record.
        let message: String

        /// The metadata of the record.
        let metadata: Logger.Metadata
    }

    /// The id of the session of the run.
    let sessionId: String

    /// The spans that ended in the run.
    let spans: [FinishedInMemorySpan]

    /// The log records of the run, in the order of the calls.
    let logRecords: [LogRecord]

    /// Reads the spans and the log records that `context` holds now.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session of the run.
    ///   - context: The context of the capture of the run.
    init(sessionId: String, context: TelemetryCapture.Context) {
        self.sessionId = sessionId
        spans = context.spans
        logRecords = context.logRecords.map { LogRecord(message: "\($0.message)", metadata: $0.metadata) }
    }

    /// The spans with the name `name`.
    ///
    /// - Parameter name: The span name.
    /// - Returns: The spans with that name, in the order of their end.
    func spans(named name: String) -> [FinishedInMemorySpan] {
        spans.filter { $0.operationName == name }
    }

    /// The number of "enter" records of the span with the name `name`.
    ///
    /// - Parameter name: The span name.
    /// - Returns: The number of records with the message `enter <name>`.
    func enterRecordCount(forSpanNamed name: String) -> Int {
        enterRecords(forSpanNamed: name).count
    }

    /// Expects one "enter" record for the span name of `span`, with the
    /// trace id and the span id of `span` in its `trace.id` and `span.id`
    /// metadata.
    ///
    /// The identities drop a record that has no ids or bad ids. Thus the
    /// check also expects exactly one record, so that such a record fails
    /// the check.
    ///
    /// - Parameters:
    ///   - span: The span that the record must point to.
    ///   - sourceLocation: The source location that each issue names.
    /// - Throws: When the ids of `span` do not have the W3C form.
    func expectOneEnterRecord(
        withTheIdsOf span: FinishedInMemorySpan, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let spanIdentity = try #require(
            SpanIdentity(traceID: span.traceID, spanID: span.spanID), sourceLocation: sourceLocation)
        let records = enterRecords(forSpanNamed: span.operationName)
        #expect(records.count == 1, "\(span.operationName)", sourceLocation: sourceLocation)
        let recordIdentities = records.compactMap(Self.identity(of:))
        #expect(recordIdentities == [spanIdentity], "\(span.operationName)", sourceLocation: sourceLocation)
    }

    /// The "enter" records of the span with the name `name`.
    ///
    /// - Parameter name: The span name.
    /// - Returns: The records with the message `enter <name>`, in the order of
    ///   the calls.
    private func enterRecords(forSpanNamed name: String) -> [LogRecord] {
        let message = ACPAgentTelemetry.enterMessage(forSpanNamed: name)
        return logRecords.filter { $0.message == message }
    }

    /// The trace id and the span id in the metadata of `record`.
    ///
    /// - Parameter record: A log record.
    /// - Returns: The identity that the `trace.id` and `span.id` values give,
    ///   or `nil` when a value is not there or does not have the W3C form.
    private static func identity(of record: LogRecord) -> SpanIdentity? {
        guard let traceID = record.metadata[ACPAgentTelemetry.LogMetadataKey.traceId],
            let spanID = record.metadata[ACPAgentTelemetry.LogMetadataKey.spanId]
        else {
            return nil
        }
        return SpanIdentity(traceID: "\(traceID)", spanID: "\(spanID)")
    }
}
