import ArgumentParser
import Logging
import Metrics
import Tracing

/// The one place where `acp-agent` chooses its telemetry backend (the approved
/// OpenTelemetry design, items 1 and 6).
///
/// The library and the family packages use only the APIs: swift-log,
/// swift-distributed-tracing and swift-metrics. Each API is a no-op until an
/// application bootstraps it, and only an executable can do that. So the
/// executable, not a library default, decides where a log record goes.
///
/// With no telemetry file the agent exports no telemetry: ``bootstrap(telemetryFile:)``
/// sends each log record at ``standardErrorLogLevel`` and up to stderr, and
/// tracing and metrics stay no-op. With `acp --telemetry-file PATH` it also
/// sends each log record at `debug` and up, each span when it ends, and each
/// metric recording to that file as JSON lines (see ``TelemetryFileWriter``),
/// and stderr keeps its own level. The OTLP exporter (`swift-otel`) is not a
/// dependency until SwiftPM 6.4.1 — see `telemetryAPIProducts` in
/// `Package.swift`.
///
/// No record goes to stdout: `acp-agent acp` writes the ACP frames there. The
/// swift-log default handler writes to stderr too
/// (`StreamLogHandler.standardError`), but this executable does not depend on
/// that default: it states its own handler, so a change of the default, or a
/// bootstrap in a library, cannot move the records.
///
/// Only ``AcpAgentCommand/main()`` calls ``bootstrap(telemetryFile:)``. The
/// unit test target links this target, and a test process must never
/// bootstrap logging: swift-log permits one bootstrap for each process. The
/// tests call ``makeWriter(telemetryFile:)`` and
/// ``makeLogHandler(label:writer:)``, which bootstrap nothing.
enum TelemetryBootstrap {
    /// The lowest level the stderr handler writes.
    ///
    /// stderr of the CLI is for warnings and errors. The family libraries
    /// log each span start at `info`, and at the default level of
    /// `StreamLogHandler` those records filled stderr on every run.
    static let standardErrorLogLevel: Logger.Level = .warning

    /// Bootstraps logging, and with a telemetry file tracing and metrics too.
    /// Call it one time, before the process writes a log record.
    ///
    /// - Parameter telemetryFile: The path of the telemetry file, or `nil`
    ///   for stderr only.
    /// - Throws: `ValidationError` when the telemetry file cannot be opened.
    ///   Nothing is bootstrapped then, and the process exits with a usage
    ///   error.
    static func bootstrap(telemetryFile: String?) throws {
        let writer = try makeWriter(telemetryFile: telemetryFile)
        LoggingSystem.bootstrap { label in makeLogHandler(label: label, writer: writer) }
        guard let writer else { return }
        InstrumentationSystem.bootstrap(TelemetryFileTracer(writer: writer))
        MetricsSystem.bootstrap(TelemetryFileMetricsFactory(writer: writer))
    }

    /// Opens the telemetry file.
    ///
    /// - Parameter telemetryFile: The path of the telemetry file, or `nil`.
    /// - Returns: The writer of the file, or `nil` when there is no file.
    /// - Throws: `ValidationError` with the path and the system reason when
    ///   the file cannot be opened. A path that cannot work is a usage
    ///   error, in the same way as a bad option value.
    static func makeWriter(telemetryFile: String?) throws -> TelemetryFileWriter? {
        guard let telemetryFile else { return nil }
        do {
            return try TelemetryFileWriter(path: telemetryFile)
        } catch {
            throw ValidationError("\(error)")
        }
    }

    /// Makes the log handler of one logger.
    ///
    /// - Parameters:
    ///   - label: The label of the logger.
    ///   - writer: The writer of the telemetry file, or `nil`.
    /// - Returns: The stderr handler at ``standardErrorLogLevel``. With a
    ///   writer, a `MultiplexLogHandler` of that stderr handler and a
    ///   ``TelemetryFileLogHandler``: the multiplex sends each record to each
    ///   handler whose own level admits it, so the file gets `debug` and up
    ///   and stderr still gets `warning` and up.
    static func makeLogHandler(label: String, writer: TelemetryFileWriter?) -> any LogHandler {
        var standardError = StreamLogHandler.standardError(label: label)
        standardError.logLevel = standardErrorLogLevel
        guard let writer else { return standardError }
        return MultiplexLogHandler([standardError, TelemetryFileLogHandler(label: label, writer: writer)])
    }
}
