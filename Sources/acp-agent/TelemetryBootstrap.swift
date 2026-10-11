import Logging

/// The one place where `acp-agent` chooses its telemetry backend (the approved
/// OpenTelemetry design, items 1 and 6).
///
/// The library and the family packages use only the APIs: swift-log,
/// swift-distributed-tracing and swift-metrics. Each API is a no-op until an
/// application bootstraps it, and only an executable can do that. So the
/// executable, not a library default, decides where a log record goes.
///
/// At this time the agent exports no telemetry. ``bootstrap()`` sends each log
/// record to stderr, and tracing and metrics stay no-op. The OTLP exporter
/// (`swift-otel`) is not a dependency until SwiftPM 6.4.1 — see
/// `telemetryAPIProducts` in `Package.swift`.
///
/// No record goes to stdout: `acp-agent acp` writes the ACP frames there. The
/// swift-log default handler writes to stderr too
/// (`StreamLogHandler.standardError`), but this executable does not depend on
/// that default: it states its own handler, so a change of the default, or a
/// bootstrap in a library, cannot move the records.
///
/// Only ``AcpAgentCommand/main()`` calls ``bootstrap()``. The unit test target
/// links this target, and a test process must never bootstrap logging:
/// swift-log permits one bootstrap for each process.
enum TelemetryBootstrap {
    /// The lowest level the stderr handler writes.
    ///
    /// stderr of the CLI is for warnings and errors. The family libraries
    /// log each span start at `info`, and at the default level of
    /// `StreamLogHandler` those records filled stderr on every run.
    static let standardErrorLogLevel: Logger.Level = .warning

    /// Bootstraps logging for this process with the stderr handler at
    /// ``standardErrorLogLevel``. Call it one time, before the process writes
    /// a log record.
    static func bootstrap() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = standardErrorLogLevel
            return handler
        }
    }
}
