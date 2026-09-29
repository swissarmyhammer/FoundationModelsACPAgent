import Foundation
import Logging
import OTel
import ServiceLifecycle
import Synchronization

/// The one place where `acp-agent` chooses its telemetry backend (the approved
/// OpenTelemetry design, items 1 and 6).
///
/// The library and the family packages use only the APIs: swift-log,
/// swift-distributed-tracing and swift-metrics. Each API is a no-op until an
/// application bootstraps it, and only an executable can do that. So the
/// executable, not a library default, decides where a log record goes.
///
/// - When `OTEL_EXPORTER_OTLP_ENDPOINT` is set and `OTEL_SDK_DISABLED` is not
///   `true` (in any case), ``bootstrap(environment:)`` exports. It makes the
///   OTLP logging backend with `OTel.makeLoggingBackend` and bootstraps
///   `LoggingSystem` with it, and then calls `OTel.bootstrap` for traces and
///   metrics only. The standard `OTEL_*` variables configure the exporters.
///   The services run in a `ServiceGroup` for the life of the process, and
///   ``shutdown()`` stops them, which flushes the last batch.
/// - Otherwise ``bootstrap(environment:)`` sends each log record to stderr,
///   and tracing and metrics stay no-op.
///
/// **`LoggingSystem.bootstrap` runs exactly one time on each path.** swift-log
/// stops the process on a second bootstrap. `OTel.bootstrap` bootstraps the
/// logs first and can then throw on metrics or traces, so it never gets the
/// logs: a failure of traces or metrics leaves the logging as it is. When
/// the logging backend cannot be made, the stderr handler is the one
/// bootstrap.
///
/// In each case no record goes to stdout: `acp-agent acp` writes the ACP
/// frames there. The swift-log default handler writes to stderr too
/// (`StreamLogHandler.standardError`), but this executable does not depend
/// on that default: it states its own handler, so a change of the default,
/// or a bootstrap in a library, cannot move the records. The diagnostic
/// logger of swift-otel writes to stderr too.
///
/// Only ``AcpAgentCommand/main()`` calls ``bootstrap(environment:)``. The unit
/// test target links this target, and a test process must never bootstrap
/// logging: swift-log permits one bootstrap for each process.
///
/// **The exit paths call ``shutdown()``, with two exceptions.** A batch
/// exporter keeps records in memory and sends them later, so an exit without
/// the shutdown loses the last batch. These paths call it:
///
/// - the normal return of ``AcpAgentCommand/main()``, for example `acp` mode
///   after the end of stdin, or `run` after the answer;
/// - the failure path of ``AcpAgentCommand/main()``, before `exit(3)`: each
///   error, and the first `Ctrl-C` of cli-plan.md §5.9, which exits 4;
/// - `SIGTERM` during a watched window, through ``TerminationHandler``, which
///   exits 143: the ACP serve window of `acp` mode, the composition window of
///   `acp` and `run` (the configuration load, the model download and the
///   model load), and the prompt window of `run`.
///
/// The first exception is the second `Ctrl-C`.
/// ``InterruptHandler/endAtOnce()`` calls `_exit(2)`, because the person
/// asked to end at once and a flush can wait on the network. So that path
/// does not flush, and its last batch is lost. The second exception is a
/// `SIGTERM` outside the watched windows: the read of the prompt text, the
/// short open of the wire before the prompt, and the `config`,
/// `instructions` and `doctor` subcommands, which hold no model, no
/// connection and no session. The signal keeps its default action there, so
/// those paths do not flush either.
///
/// ``shutdown()`` waits for the flush for ``shutdownDeadline`` at most, so a
/// collector that does not answer cannot hold the process.
enum TelemetryBootstrap {
    /// The number of seconds in ``shutdownDeadline``.
    private static let shutdownDeadlineSeconds = 2

    /// The longest time ``shutdown()`` waits for the flush of the last batch.
    static let shutdownDeadline: Duration = .seconds(shutdownDeadlineSeconds)

    /// The standard variable that sets on the OTLP exporters.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The standard variable that sets off the whole OpenTelemetry SDK.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// The value of ``sdkDisabledVariable`` that sets the SDK off, in lower
    /// case. The OpenTelemetry specification reads a Boolean variable
    /// without case sensitivity.
    private static let sdkDisabledValue = "true"

    /// The label of the stderr logger that reports a bootstrap failure and a
    /// failure of the running service.
    private static let diagnosticLoggerLabel = "acp-agent.telemetry"

    /// The running OpenTelemetry services, or `nil` when the agent does not
    /// export, when no backend started, or when ``shutdown()`` stopped them.
    private static let running = Mutex<RunningService?>(nil)

    /// A log handler factory, in the form that `LoggingSystem.bootstrap`
    /// takes.
    typealias LogHandlerFactory = @Sendable (String) -> any LogHandler

    /// The lowest level the stderr handler writes.
    ///
    /// stderr of the CLI is for warnings and errors. The family libraries
    /// log each span start at `info`, and at the default level of
    /// `StreamLogHandler` those records filled stderr on every run. When the
    /// agent exports, the `info` records go to the OTLP backend instead.
    static let standardErrorLogLevel: Logger.Level = .warning

    /// The factory of the stderr log handler: the handler when the agent does
    /// not export, and the fallback when the OTLP logging backend cannot be
    /// made.
    private static let standardErrorFactory: LogHandlerFactory = { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = standardErrorLogLevel
        return handler
    }

    /// The OpenTelemetry service group and the task that runs it.
    private struct RunningService: Sendable {
        /// The group that holds the OpenTelemetry services. A graceful
        /// shutdown of the group flushes the exporters.
        let group: ServiceGroup

        /// The task that runs `group`. It ends when the group ends.
        let task: Task<Void, Never>
    }

    /// Bootstraps logging, tracing and metrics for this process. Call it one
    /// time, before the process writes a log record.
    ///
    /// Each path calls `LoggingSystem.bootstrap` exactly one time. When the
    /// agent exports, a failure of the logging backend installs the stderr
    /// handler, and a failure of the traces and metrics bootstrap leaves the
    /// logging as it is. Each failure writes its reason to stderr.
    ///
    /// - Parameter environment: The process environment. It selects the
    ///   backend and configures the exporters. The logging backend of
    ///   swift-otel 1.5.1 reads the process environment itself, because
    ///   `OTel.makeLoggingBackend` takes no environment. The only caller
    ///   gives the process environment, so the two agree.
    static func bootstrap(environment: [String: String]) {
        guard exportsTelemetry(environment: environment) else {
            LoggingSystem.bootstrap(standardErrorFactory)
            return
        }
        let loggingService = installLogging(
            from: makeLoggingBackend,
            otherwise: standardErrorFactory,
            installing: { factory in LoggingSystem.bootstrap(factory) })
        let tracingAndMetricsService = startTracingAndMetrics(
            environment: tracingAndMetricsEnvironment(from: environment))
        run([loggingService, tracingAndMetricsService].compactMap { $0 })
    }

    /// Tells whether `environment` asks for the OTLP exporters: an
    /// `OTEL_EXPORTER_OTLP_ENDPOINT` that is not empty, and no
    /// `OTEL_SDK_DISABLED` of `true` in any case.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: `true` when the agent exports, and `false` when it logs to
    ///   stderr and keeps tracing and metrics no-op.
    static func exportsTelemetry(environment: [String: String]) -> Bool {
        guard let endpoint = environment[otlpEndpointVariable], !endpoint.isEmpty else {
            return false
        }
        return environment[sdkDisabledVariable]?.lowercased() != sdkDisabledValue
    }

    /// The environment for the traces and metrics bootstrap: `environment`
    /// with no `OTEL_SDK_DISABLED`.
    ///
    /// ``exportsTelemetry(environment:)`` already read that variable. The
    /// traces and metrics bootstrap must not read it again: swift-otel sets
    /// the logs switch from it in both directions, so a value of `false`
    /// sets on the logs that the configuration set off, and
    /// `OTel.bootstrap` then bootstraps `LoggingSystem` a second time.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: `environment` without `OTEL_SDK_DISABLED`.
    static func tracingAndMetricsEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { $0.key != sdkDisabledVariable }
    }

    /// Installs one log handler factory: the factory of the backend that
    /// `makeBackend` makes, or `fallback` when it throws. `install` runs
    /// exactly one time.
    ///
    /// - Parameters:
    ///   - makeBackend: Makes the backend: its factory and its service.
    ///   - fallback: The factory to install when `makeBackend` throws.
    ///   - install: Installs a factory, for example `LoggingSystem.bootstrap`.
    /// - Returns: The service of the backend, or `nil` when `makeBackend`
    ///   threw. The reason then goes to stderr.
    static func installLogging<Factory, BackendService>(
        from makeBackend: () throws -> (factory: Factory, service: BackendService),
        otherwise fallback: Factory,
        installing install: (Factory) -> Void
    ) -> BackendService? {
        let backend: (factory: Factory, service: BackendService)
        do {
            backend = try makeBackend()
        } catch {
            install(fallback)
            makeDiagnosticLogger().error(
                "The OpenTelemetry logging backend failed. Logs go to stderr.",
                metadata: ["error": "\(error)"])
            return nil
        }
        install(backend.factory)
        return backend.service
    }

    /// Stops the running OpenTelemetry services and waits until they end,
    /// for ``shutdownDeadline`` at most. The graceful shutdown flushes the
    /// last batch of spans, log records and metrics. When no service runs,
    /// it does nothing.
    ///
    /// When the deadline comes first, the service task is cancelled and
    /// this function returns, so the process can exit. The batch that did
    /// not go out is lost, and the process does not wait for a collector
    /// that does not answer.
    static func shutdown() async {
        guard let service = running.withLock({ current in current.take() }) else {
            return
        }
        await service.group.triggerGracefulShutdown()
        let ended = await waitForEnd(of: service.task, within: shutdownDeadline)
        guard !ended else {
            return
        }
        service.task.cancel()
        makeDiagnosticLogger().error(
            "The OpenTelemetry flush did not end before the deadline. The last batch is lost.",
            metadata: ["deadline": "\(shutdownDeadline)"])
    }

    /// Waits until `task` ends or until `deadline` passes, whichever comes
    /// first.
    ///
    /// The wait of a `Task` value does not stop when the waiting task is
    /// cancelled, so a task group cannot race it: the group waits for each
    /// child before it returns. So two unstructured tasks, one for the end
    /// and one for the deadline, report into one stream, and the first
    /// report decides. When the deadline wins, the task that waits for the
    /// end stays suspended until `task` ends.
    ///
    /// - Parameters:
    ///   - task: The task to wait for.
    ///   - deadline: The longest time to wait.
    /// - Returns: `true` when `task` ended before the deadline, and `false`
    ///   when the deadline came first.
    static func waitForEnd(of task: Task<Void, Never>, within deadline: Duration) async -> Bool {
        let (reports, report) = AsyncStream<Bool>.makeStream()
        let ending = Task {
            await task.value
            report.yield(true)
        }
        let timing = Task {
            try? await Task.sleep(for: deadline)
            report.yield(false)
        }
        var iterator = reports.makeAsyncIterator()
        let ended = await iterator.next() ?? false
        report.finish()
        timing.cancel()
        ending.cancel()
        return ended
    }

    /// Makes the OTLP logging backend of swift-otel. It does not bootstrap
    /// `LoggingSystem`.
    ///
    /// - Returns: The log handler factory and the service that exports the
    ///   records.
    /// - Throws: The configuration error of `OTel.makeLoggingBackend`.
    private static func makeLoggingBackend() throws -> (factory: LogHandlerFactory, service: any Service) {
        let backend = try OTel.makeLoggingBackend()
        return (backend.factory, backend.service)
    }

    /// Bootstraps tracing and metrics with swift-otel, and not logging.
    ///
    /// The configuration sets the logs off, so `OTel.bootstrap` never calls
    /// `LoggingSystem.bootstrap`. When it throws, the reason goes to stderr.
    /// Metrics can already be bootstrapped then, because swift-otel does
    /// metrics before traces, but no service exports them.
    ///
    /// - Parameter environment: The `OTEL_*` variables, with no
    ///   `OTEL_SDK_DISABLED` (see ``tracingAndMetricsEnvironment(from:)``).
    /// - Returns: The service that exports spans and metrics, or `nil` when
    ///   the bootstrap failed.
    private static func startTracingAndMetrics(environment: [String: String]) -> (any Service)? {
        var configuration = OTel.Configuration.default
        configuration.logs.enabled = false
        do {
            return try OTel.bootstrap(configuration: configuration, environment: environment)
        } catch {
            makeDiagnosticLogger().error(
                "The OpenTelemetry traces and metrics bootstrap failed. Traces and metrics are not exported, and the logs stay as they are.",
                metadata: ["error": "\(error)"])
            return nil
        }
    }

    /// Runs `services` in one service group on a task of its own, and keeps
    /// the group for ``shutdown()``. When `services` is empty, it does
    /// nothing.
    ///
    /// - Parameter services: The OpenTelemetry services that started.
    private static func run(_ services: [any Service]) {
        guard !services.isEmpty else {
            return
        }
        let diagnosticLogger = makeDiagnosticLogger()
        let group = ServiceGroup(services: services, logger: diagnosticLogger)
        let task = Task {
            do {
                try await group.run()
            } catch {
                diagnosticLogger.error(
                    "The OpenTelemetry service stopped with an error.",
                    metadata: ["error": "\(error)"])
            }
        }
        running.withLock { current in
            current = RunningService(group: group, task: task)
        }
    }

    /// Makes a logger that writes to stderr through its own handler, and not
    /// through `LoggingSystem`. So it works before and after the bootstrap,
    /// and it never goes to the OTLP exporter it reports on.
    ///
    /// - Returns: The stderr logger.
    private static func makeDiagnosticLogger() -> Logger {
        Logger(label: diagnosticLoggerLabel, factory: StreamLogHandler.standardError(label:))
    }
}
