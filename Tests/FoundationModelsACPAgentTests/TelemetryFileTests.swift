import ArgumentParser
import CoreMetrics
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Logging
import Testing
import Tracing

@testable import acp_agent

/// The telemetry file of `acp-agent acp --telemetry-file PATH`: one JSON
/// object for each line, for each log record, each span that ends and each
/// metric recording.
///
/// A test process must never bootstrap the logging, tracing or metrics
/// system, because each system permits one bootstrap for each process. So
/// each case makes the log handler, the tracer or the metrics factory of the
/// file directly, over a writer of a temporary file, and reads the lines back.
struct TelemetryFileTests {
    // MARK: - Constants

    /// The label of the logger and of the temporary directories.
    private static let label = "TelemetryFileTests"

    /// The message of the log record case.
    private static let logMessage = "a debug record"

    /// The metadata key of the log record case.
    private static let metadataKey = "session.id"

    /// The metadata value of the log record case.
    private static let metadataValue = "session-1"

    /// The name of the parent span.
    private static let parentSpanName = "TelemetryFileTests.parent"

    /// The name of the child span.
    private static let childSpanName = "TelemetryFileTests.child"

    /// The attribute key of the child span.
    private static let attributeKey = "command.kind"

    /// The attribute value of the child span.
    private static let attributeValue = "template"

    /// The integer attribute key of the child span.
    private static let countAttributeKey = "files.changed"

    /// The integer attribute value of the child span.
    private static let countAttributeValue = 3

    /// The name of the event of the child span.
    private static let eventName = "settled"

    /// The label of the counter case.
    private static let counterLabel = "foundation_models_acp_agent.commands"

    /// The dimension key of the counter case.
    private static let dimensionKey = "outcome"

    /// The dimension value of the counter case.
    private static let dimensionValue = "ok"

    /// The amount the counter case adds.
    private static let counterAmount: Int64 = 2

    /// The nanoseconds the timer case records.
    private static let timerNanoseconds: Int64 = 1_500_000

    /// The text that a recorded error holds in its description, and that no
    /// line may hold: the "No content" rule of the agent telemetry.
    private static let errorContent = "tfs-error-content-7c1e44"

    /// The number of tasks of the concurrency case.
    private static let writerTaskCount = 8

    /// The number of records each task of the concurrency case writes.
    private static let recordsPerTask = 50

    /// The size of the message of the concurrency case. It is larger than
    /// `PIPE_BUF`, so a write that is not one whole line shows as a broken
    /// line.
    private static let largeMessageLength = 16_384

    /// The path of the option parsing case.
    private static let optionPath = "/tmp/acp-agent-telemetry.jsonl"

    /// The record of the line format cases: its keys are out of order, and a
    /// value holds a slash.
    private static let unsortedRecord: [String: JSONValue] = ["path": .string("a/b"), "count": .number(2)]

    /// The exact line of ``unsortedRecord``: sorted keys, the slash not
    /// escaped, and the line end.
    private static let unsortedRecordLine = "{\"count\":2,\"path\":\"a/b\"}\n"

    /// A record with each number that JSON cannot hold, also inside an array
    /// and an object.
    private static let nonFiniteRecord: [String: JSONValue] = [
        "rate": .number(.infinity),
        "values": .array([.number(-.infinity), .number(.nan)]),
        "nested": .object(["rate": .number(.infinity)]),
    ]

    /// The exact line of ``nonFiniteRecord``: each such number as its text.
    private static let nonFiniteRecordLine =
        "{\"nested\":{\"rate\":\"Infinity\"},\"rate\":\"Infinity\",\"values\":[\"-Infinity\",\"NaN\"]}\n"

    /// The bytes a crash left at the end of the file: a line with no line end.
    private static let tornLine = "{\"type\":\"lo"

    /// The line that stands in the file before the writer opens it.
    private static let earlierLine = "{\"type\":\"earlier\"}\n"

    // MARK: - Fixtures

    /// Makes a writer over a new file in a new temporary directory.
    ///
    /// - Parameter name: The name of the case, for the directory label.
    /// - Returns: The writer and the URL of its file.
    /// - Throws: The open error of the writer.
    private static func makeWriter(_ name: String) throws -> (TelemetryFileWriter, URL) {
        let file = makeResolvedDirectory(label: "\(label)-\(name)").appendingPathComponent("telemetry.jsonl")
        return (try TelemetryFileWriter(path: file.path), file)
    }

    /// Reads each line of `file` as one JSON object.
    ///
    /// - Parameter file: The telemetry file.
    /// - Returns: The objects, in the order of the lines.
    /// - Throws: The read error, or the decode error of a line that is not
    ///   one whole JSON object.
    private static func readRecords(_ file: URL) throws -> [[String: JSONValue]] {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
        }
    }

    /// The text of a string member.
    ///
    /// - Parameters:
    ///   - key: The member name.
    ///   - record: The JSON object.
    /// - Returns: The text, or `nil` when the member is absent or is not a
    ///   string.
    private static func string(_ key: String, in record: [String: JSONValue]) -> String? {
        guard case .string(let text)? = record[key] else { return nil }
        return text
    }

    /// The members of an object member.
    ///
    /// - Parameters:
    ///   - key: The member name.
    ///   - record: The JSON object.
    /// - Returns: The members, or `nil` when the member is absent or is not an
    ///   object.
    private static func object(_ key: String, in record: [String: JSONValue]) -> [String: JSONValue]? {
        guard case .object(let members)? = record[key] else { return nil }
        return members
    }

    /// The number of a number member.
    ///
    /// - Parameters:
    ///   - key: The member name.
    ///   - record: The JSON object.
    /// - Returns: The number, or `nil` when the member is absent or is not a
    ///   number.
    private static func number(_ key: String, in record: [String: JSONValue]) -> Double? {
        guard case .number(let value)? = record[key] else { return nil }
        return value
    }

    /// The objects of an array member.
    ///
    /// - Parameters:
    ///   - key: The member name.
    ///   - record: The JSON object.
    /// - Returns: The members of each object of the array, or `nil` when the
    ///   member is absent, is not an array, or holds a value that is not an
    ///   object.
    private static func objects(_ key: String, in record: [String: JSONValue]) -> [[String: JSONValue]]? {
        guard case .array(let values)? = record[key] else { return nil }
        let members = values.compactMap { value -> [String: JSONValue]? in
            guard case .object(let members) = value else { return nil }
            return members
        }
        return members.count == values.count ? members : nil
    }

    /// Whether `text` is an ISO 8601 time with milliseconds.
    ///
    /// - Parameter text: The text of a time member.
    /// - Returns: `true` when the text parses with fractional seconds.
    private static func isTimestampWithMilliseconds(_ text: String?) -> Bool {
        guard let text else { return false }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) != nil
    }

    // MARK: - Log records

    /// A debug record writes one log line with the level, the label, the
    /// message, the source location and the metadata.
    @Test
    func aDebugLogRecordWritesOneLogLine() throws {
        let (writer, file) = try Self.makeWriter("log")
        let logger = Logger(label: Self.label) { label in TelemetryFileLogHandler(label: label, writer: writer) }

        logger.debug("\(Self.logMessage)", metadata: [Self.metadataKey: "\(Self.metadataValue)"])

        let records = try Self.readRecords(file)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(Self.string("type", in: record) == "log")
        #expect(Self.string("level", in: record) == "debug")
        #expect(Self.string("label", in: record) == Self.label)
        #expect(Self.string("message", in: record) == Self.logMessage)
        #expect(Self.string("source", in: record) != nil)
        #expect(Self.string("file", in: record)?.hasSuffix("TelemetryFileTests.swift") == true)
        #expect(record["line"] != nil)
        #expect(Self.object("metadata", in: record) == [Self.metadataKey: .string(Self.metadataValue)])
        #expect(Self.isTimestampWithMilliseconds(Self.string("ts", in: record)))
    }

    /// A trace record is below the default level of the handler, and writes
    /// nothing.
    @Test
    func aTraceLogRecordWritesNothing() throws {
        let (writer, file) = try Self.makeWriter("trace")
        let logger = Logger(label: Self.label) { label in TelemetryFileLogHandler(label: label, writer: writer) }

        logger.trace("\(Self.logMessage)")
        logger.debug("\(Self.logMessage)")

        #expect(try Self.readRecords(file).count == 1)
    }

    /// The error of a log record writes its type name, never its
    /// description.
    @Test
    func theErrorOfALogRecordWritesItsTypeAndNotItsDescription() throws {
        let (writer, file) = try Self.makeWriter("log-error")
        let handler = TelemetryFileLogHandler(label: Self.label, writer: writer)

        handler.log(
            event: LogEvent(
                level: .error, message: "\(Self.logMessage)", error: ContentError(content: Self.errorContent),
                metadata: nil, source: Self.label, file: #fileID, function: #function, line: #line))

        let text = try String(contentsOf: file, encoding: .utf8)
        let record = try #require(try Self.readRecords(file).first)
        #expect(Self.string("error", in: record) == String(reflecting: ContentError.self))
        #expect(!text.contains(Self.errorContent))
    }

    // MARK: - Spans

    /// A child span takes the trace id of its parent, and names the span id
    /// of its parent. Each span writes one line when it ends.
    @Test
    func aChildSpanLinksToItsParent() throws {
        let (writer, file) = try Self.makeWriter("span")
        let tracer = TelemetryFileTracer(writer: writer)

        let parent = tracer.startSpan(Self.parentSpanName, context: .topLevel, ofKind: .server)
        let child = tracer.startSpan(Self.childSpanName, context: parent.context, ofKind: .internal)
        child.end()
        parent.end()

        let records = try Self.readRecords(file)
        #expect(records.count == 2)
        let childRecord = try #require(records.first { Self.string("name", in: $0) == Self.childSpanName })
        let parentRecord = try #require(records.first { Self.string("name", in: $0) == Self.parentSpanName })
        #expect(Self.string("type", in: parentRecord) == "span")
        #expect(Self.string("kind", in: parentRecord) == "server")
        #expect(parentRecord["parentSpanId"] == .null)
        #expect(Self.string("traceId", in: parentRecord)?.count == 32)
        #expect(Self.string("spanId", in: parentRecord)?.count == 16)
        #expect(Self.string("traceId", in: childRecord) == Self.string("traceId", in: parentRecord))
        #expect(Self.string("parentSpanId", in: childRecord) == Self.string("spanId", in: parentRecord))
        #expect(Self.string("spanId", in: childRecord) != Self.string("spanId", in: parentRecord))
    }

    /// A span line carries the times, the duration, the status, the
    /// attributes and the events of the span.
    @Test
    func aSpanLineCarriesItsAttributesEventsAndTimes() throws {
        let (writer, file) = try Self.makeWriter("span-detail")
        let tracer = TelemetryFileTracer(writer: writer)

        let span = tracer.startSpan(Self.childSpanName, context: .topLevel)
        span.attributes[Self.attributeKey] = Self.attributeValue
        span.attributes[Self.countAttributeKey] = Self.countAttributeValue
        span.addEvent(SpanEvent(name: Self.eventName, attributes: [Self.attributeKey: "\(Self.attributeValue)"]))
        span.setStatus(SpanStatus(code: .ok))
        span.end()

        let record = try #require(try Self.readRecords(file).first)
        #expect(
            Self.object("attributes", in: record) == [
                Self.attributeKey: .string(Self.attributeValue),
                Self.countAttributeKey: .number(Double(Self.countAttributeValue)),
            ])
        let event = try #require(Self.objects("events", in: record)?.first)
        #expect(Self.string("name", in: event) == Self.eventName)
        #expect(Self.object("attributes", in: event) == [Self.attributeKey: .string(Self.attributeValue)])
        #expect(Self.isTimestampWithMilliseconds(Self.string("ts", in: event)))
        #expect(Self.string("status", in: record) == "ok")
        #expect(Self.isTimestampWithMilliseconds(Self.string("start", in: record)))
        #expect(Self.isTimestampWithMilliseconds(Self.string("end", in: record)))
        let duration = try #require(Self.number("durationMs", in: record))
        #expect(duration >= 0)
    }

    /// A span writes one line only, when `end` is called more than one time.
    @Test
    func aSpanThatEndsTwiceWritesOneLine() throws {
        let (writer, file) = try Self.makeWriter("span-twice")
        let span = TelemetryFileTracer(writer: writer).startSpan(Self.childSpanName, context: .topLevel)

        span.end()
        span.end()

        #expect(try Self.readRecords(file).count == 1)
        #expect(!span.isRecording)
    }

    /// A recorded error writes its type name, never its description, and the
    /// status message of an error status is not written either.
    @Test
    func aRecordedErrorWritesItsTypeAndNotItsDescription() throws {
        let (writer, file) = try Self.makeWriter("span-error")
        let span = TelemetryFileTracer(writer: writer).startSpan(Self.childSpanName, context: .topLevel)

        span.recordError(ContentError(content: Self.errorContent))
        span.setStatus(SpanStatus(code: .error, message: Self.errorContent))
        span.end()

        let text = try String(contentsOf: file, encoding: .utf8)
        let record = try #require(try Self.readRecords(file).first)
        let error = try #require(Self.objects("errors", in: record)?.first)
        #expect(Self.string("type", in: error) == String(reflecting: ContentError.self))
        #expect(Self.string("status", in: record) == "error")
        #expect(!text.contains(Self.errorContent))
    }

    /// A link writes the ids of the linked span.
    @Test
    func aLinkWritesTheIdsOfTheLinkedSpan() throws {
        let (writer, file) = try Self.makeWriter("span-link")
        let tracer = TelemetryFileTracer(writer: writer)
        let linked = tracer.startSpan(Self.parentSpanName, context: .topLevel)
        let span = tracer.startSpan(Self.childSpanName, context: .topLevel)

        span.addLink(SpanLink(context: linked.context, attributes: [:]))
        span.end()
        linked.end()

        let records = try Self.readRecords(file)
        let spanRecord = try #require(records.first { Self.string("name", in: $0) == Self.childSpanName })
        let linkedRecord = try #require(records.first { Self.string("name", in: $0) == Self.parentSpanName })
        let link = try #require(Self.objects("links", in: spanRecord)?.first)
        #expect(Self.string("traceId", in: link) == Self.string("traceId", in: linkedRecord))
        #expect(Self.string("spanId", in: link) == Self.string("spanId", in: linkedRecord))
    }

    /// The tracer injects a W3C `traceparent` value, and a span under the
    /// extracted context joins the trace of that value.
    @Test
    func anExtractedTraceparentParentsTheNextSpan() throws {
        let (writer, file) = try Self.makeWriter("span-extract")
        let tracer = TelemetryFileTracer(writer: writer)
        let remote = tracer.startSpan(Self.parentSpanName, context: .topLevel)
        var carrier: [String: String] = [:]
        tracer.inject(remote.context, into: &carrier, using: DictionaryCarrier())

        var extracted = InstrumentationContext.topLevel
        tracer.extract(carrier, into: &extracted, using: DictionaryCarrier())
        tracer.startSpan(Self.childSpanName, context: extracted).end()
        remote.end()

        let records = try Self.readRecords(file)
        let childRecord = try #require(records.first { Self.string("name", in: $0) == Self.childSpanName })
        let remoteRecord = try #require(records.first { Self.string("name", in: $0) == Self.parentSpanName })
        #expect(carrier["traceparent"]?.hasPrefix("00-") == true)
        #expect(Self.string("traceId", in: childRecord) == Self.string("traceId", in: remoteRecord))
        #expect(Self.string("parentSpanId", in: childRecord) == Self.string("spanId", in: remoteRecord))
    }

    // MARK: - Metrics

    /// A counter increment writes one metric line with the kind, the label,
    /// the dimensions and the amount.
    @Test
    func aCounterIncrementWritesOneMetricLine() throws {
        let (writer, file) = try Self.makeWriter("counter")
        let factory = TelemetryFileMetricsFactory(writer: writer)

        factory.makeCounter(label: Self.counterLabel, dimensions: [(Self.dimensionKey, Self.dimensionValue)])
            .increment(by: Self.counterAmount)

        let record = try #require(try Self.readRecords(file).first)
        #expect(Self.string("type", in: record) == "metric")
        #expect(Self.string("kind", in: record) == "counter")
        #expect(Self.string("label", in: record) == Self.counterLabel)
        #expect(Self.object("dimensions", in: record) == [Self.dimensionKey: .string(Self.dimensionValue)])
        #expect(Self.string("operation", in: record) == "increment")
        #expect(record["value"] == .number(Double(Self.counterAmount)))
        #expect(Self.isTimestampWithMilliseconds(Self.string("ts", in: record)))
    }

    /// A meter names each call, so a set and a decrement of the same amount
    /// stay apart.
    @Test
    func aMeterNamesEachCall() throws {
        let (writer, file) = try Self.makeWriter("meter")
        let meter = TelemetryFileMetricsFactory(writer: writer).makeMeter(label: Self.counterLabel, dimensions: [])

        meter.set(Double(Self.counterAmount))
        meter.decrement(by: Double(Self.counterAmount))

        let records = try Self.readRecords(file)
        #expect(records.map { Self.string("operation", in: $0) } == ["set", "decrement"])
        #expect(records.map { Self.number("value", in: $0) } == [Double(Self.counterAmount), Double(Self.counterAmount)])
    }

    /// Each kind of metric writes its own kind name.
    @Test
    func eachMetricKindWritesItsKindName() throws {
        let (writer, file) = try Self.makeWriter("kinds")
        let factory = TelemetryFileMetricsFactory(writer: writer)

        factory.makeFloatingPointCounter(label: Self.counterLabel, dimensions: []).increment(by: 1.5)
        factory.makeRecorder(label: Self.counterLabel, dimensions: [], aggregate: false).record(Int64(1))
        factory.makeTimer(label: Self.counterLabel, dimensions: []).recordNanoseconds(Self.timerNanoseconds)
        factory.makeMeter(label: Self.counterLabel, dimensions: []).set(Int64(1))

        let records = try Self.readRecords(file)
        #expect(
            records.map { Self.string("kind", in: $0) } == [
                "floatingPointCounter", "recorder", "timer", "meter",
            ])
        let timerRecord = try #require(records.first { Self.string("kind", in: $0) == "timer" })
        #expect(Self.number("value", in: timerRecord) == Double(Self.timerNanoseconds))
    }

    // MARK: - Concurrency

    /// Records written from many tasks at once are whole lines: each line is
    /// one JSON object, and no record is lost.
    @Test
    func concurrentWritesGiveWholeLinesOnly() async throws {
        let (writer, file) = try Self.makeWriter("concurrent")
        let largeMessage = String(repeating: "x", count: Self.largeMessageLength)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.writerTaskCount {
                group.addTask {
                    let logger = Logger(label: Self.label) { label in
                        TelemetryFileLogHandler(label: label, writer: writer)
                    }
                    for _ in 0..<Self.recordsPerTask {
                        logger.debug("\(largeMessage)")
                    }
                }
            }
        }

        let records = try Self.readRecords(file)
        #expect(records.count == Self.writerTaskCount * Self.recordsPerTask)
        #expect(records.allSatisfy { Self.string("message", in: $0) == largeMessage })
    }

    // MARK: - The line format and the file

    /// A record is one line of JSON with sorted keys and slashes not escaped,
    /// the format the bench readers parse.
    @Test
    func aRecordIsOneLineWithSortedKeys() throws {
        let (writer, file) = try Self.makeWriter("sorted")

        writer.write(Self.unsortedRecord)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.unsortedRecordLine)
    }

    /// A number that JSON cannot hold, at any depth, writes as its text, so
    /// the record still writes.
    @Test
    func aNonFiniteNumberWritesAsItsText() throws {
        let (writer, file) = try Self.makeWriter("non-finite")

        writer.write(Self.nonFiniteRecord)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.nonFiniteRecordLine)
    }

    /// The writer appends: the lines already in the file stay, in front of
    /// the new record.
    @Test
    func aRecordAppendsAfterTheLinesAlreadyInTheFile() throws {
        let file = makeResolvedDirectory(label: "\(Self.label)-append").appendingPathComponent("telemetry.jsonl")
        try Data(Self.earlierLine.utf8).write(to: file)
        let writer = try TelemetryFileWriter(path: file.path)

        writer.write(Self.unsortedRecord)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.earlierLine + Self.unsortedRecordLine)
    }

    /// When a crash left a torn line at the end of the file, the next record
    /// still starts on a line of its own.
    @Test
    func aRecordAfterATornLineStartsOnALineOfItsOwn() throws {
        let (writer, file) = try Self.makeWriter("torn")
        try Data(Self.tornLine.utf8).write(to: file)

        writer.write(Self.unsortedRecord)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.tornLine + "\n" + Self.unsortedRecordLine)
    }

    /// Each record opens the file at its path, so a record after the file was
    /// removed makes the file again rather than going to the removed file.
    @Test
    func aRecordAfterTheFileWasRemovedMakesTheFileAgain() throws {
        let (writer, file) = try Self.makeWriter("removed")
        writer.write(Self.unsortedRecord)
        try FileManager.default.removeItem(at: file)

        writer.write(Self.unsortedRecord)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.unsortedRecordLine)
    }

    // MARK: - The option

    /// `acp --telemetry-file PATH` parses to the path.
    @Test
    func theTelemetryFileOptionParsesToItsPath() throws {
        let command = try #require(
            try AcpAgentCommand.parseAsRoot(["acp", "--telemetry-file", Self.optionPath]) as? AcpAgentCommand.Acp)

        #expect(command.telemetryFile == Self.optionPath)
    }

    /// `acp` with no flag has no telemetry file.
    @Test
    func noTelemetryFileOptionParsesToNil() throws {
        let command = try #require(try AcpAgentCommand.parseAsRoot(["acp"]) as? AcpAgentCommand.Acp)

        #expect(command.telemetryFile == nil)
    }

    /// The help of `acp` names the option, so the flag is documented.
    @Test
    func theHelpOfAcpNamesTheTelemetryFileOption() {
        #expect(AcpAgentCommand.Acp.helpMessage().contains("--telemetry-file"))
    }

    // MARK: - The bootstrap composition

    /// With no telemetry file, the bootstrap makes no writer.
    @Test
    func noTelemetryFileMakesNoWriter() throws {
        #expect(try TelemetryBootstrap.makeWriter(telemetryFile: nil) == nil)
    }

    /// A telemetry file that cannot be opened is a usage error, with the path
    /// in its message.
    @Test
    func aTelemetryFileThatCannotOpenIsAUsageError() throws {
        let path = makeResolvedDirectory(label: "\(Self.label)-missing")
            .appendingPathComponent("absent-directory", isDirectory: true)
            .appendingPathComponent("telemetry.jsonl").path

        let error = #expect(throws: ValidationError.self) {
            try TelemetryBootstrap.makeWriter(telemetryFile: path)
        }

        #expect(error?.message.contains(path) == true)
    }

    /// A telemetry path that names a folder is a usage error, with the path
    /// in its message.
    @Test
    func aTelemetryPathThatIsAFolderIsAUsageError() throws {
        let path = makeResolvedDirectory(label: "\(Self.label)-folder").path

        let error = #expect(throws: ValidationError.self) {
            try TelemetryBootstrap.makeWriter(telemetryFile: path)
        }

        #expect(error?.message.contains(path) == true)
    }

    /// With no writer, the bootstrap handler is the stderr handler at the
    /// warning level, as before the flag.
    @Test
    func theHandlerWithNoWriterIsTheStandardErrorHandler() {
        let handler = TelemetryBootstrap.makeLogHandler(label: Self.label, writer: nil)

        #expect(handler is StreamLogHandler)
        #expect(handler.logLevel == TelemetryBootstrap.standardErrorLogLevel)
    }

    /// With a writer, the bootstrap handler sends a debug record to the file,
    /// and keeps the stderr handler at the warning level beside it.
    @Test
    func theHandlerWithAWriterSendsDebugRecordsToTheFile() throws {
        let (writer, file) = try Self.makeWriter("multiplex")
        let handler = TelemetryBootstrap.makeLogHandler(label: Self.label, writer: writer)
        let logger = Logger(label: Self.label) { _ in handler }

        logger.debug("\(Self.logMessage)")

        #expect(handler is MultiplexLogHandler)
        #expect(handler.logLevel == TelemetryFileLogHandler.defaultLogLevel)
        #expect(try Self.readRecords(file).map { Self.string("message", in: $0) } == [Self.logMessage])
    }
}

/// An error whose description holds content.
private struct ContentError: Error, CustomStringConvertible {
    /// The content.
    let content: String

    /// The description, which holds the content.
    var description: String { content }
}

/// Injects into, and extracts from, a dictionary carrier.
private struct DictionaryCarrier: Injector, Extractor {
    /// Writes `value` under `key`.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - key: The key.
    ///   - carrier: The dictionary.
    func inject(_ value: String, forKey key: String, into carrier: inout [String: String]) {
        carrier[key] = value
    }

    /// Reads the value under `key`.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - carrier: The dictionary.
    /// - Returns: The value, or `nil`.
    func extract(key: String, from carrier: [String: String]) -> String? {
        carrier[key]
    }
}
