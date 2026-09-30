import InMemoryTracing
import TelemetryTestSupport

/// The spans and the log records of one traced run, and the id of its
/// session.
///
/// A telemetry suite reads the context of its capture into this value at the
/// end of the run, and makes its assertions after the capture ended.
struct TracedRun {
    /// The text before the span name in the message of an "enter" record.
    private static let enterMessagePrefix = "enter "

    /// The id of the session of the run.
    let sessionId: String

    /// The spans that ended in the run.
    let spans: [FinishedInMemorySpan]

    /// The message of each log record of the run.
    let logMessages: [String]

    /// Reads the spans and the log records that `context` holds now.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session of the run.
    ///   - context: The context of the capture of the run.
    init(sessionId: String, context: TelemetryCapture.Context) {
        self.sessionId = sessionId
        spans = context.spans
        logMessages = context.logRecords.map { "\($0.message)" }
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
        logMessages.count { $0 == Self.enterMessagePrefix + name }
    }
}
