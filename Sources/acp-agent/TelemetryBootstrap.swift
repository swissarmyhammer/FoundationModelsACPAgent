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
/// - When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, ``bootstrap(environment:)``
///   calls `OTel.bootstrap` for traces, logs and metrics. The standard
///   `OTEL_*` variables configure the exporters. The returned service runs
///   in a `ServiceGroup` for the life of the process, and ``shutdown()``
///   stops it, which flushes the last batch.
/// - When it is not set, ``bootstrap(environment:)`` sends each log record to
///   stderr, and tracing and metrics stay no-op.
///
/// In both cases no record goes to stdout: `acp-agent acp` writes the ACP
/// frames there. The diagnostic logger of swift-otel writes to stderr too.
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
/// - `SIGTERM` during the ACP serve window of `acp` mode, through
///   ``TerminationHandler``, which exits 143.
///
/// The first exception is the second `Ctrl-C`.
/// ``InterruptHandler/endAtOnce()`` calls `_exit(2)`, because the person
/// asked to end at once and a flush can wait on the network. So that path
/// does not flush, and its last batch is lost. The second exception is a
/// `SIGTERM` outside the ACP serve window: the signal keeps its default
/// action there, so that path does not flush either.
///
/// ``shutdown()`` waits for the flush for ``shutdownDeadline`` at most, so a
/// collector that does not answer cannot hold the process.
enum TelemetryBootstrap {
    /// The number of seconds in ``shutdownDeadline``.
    private static let shutdownDeadlineSeconds = 2

    /// The longest time ``shutdown()`` waits for the flush of the last batch.
    static let shutdownDeadline: Duration = .seconds(shutdownDeadlineSeconds)

    /// The standard variable that turns on the OTLP exporters.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The label of the stderr logger that reports a bootstrap failure and a
    /// failure of the running service.
    private static let diagnosticLoggerLabel = "acp-agent.telemetry"

    /// The running OpenTelemetry service, or `nil` when no OTLP endpoint is
    /// set or when ``shutdown()`` stopped it.
    private static let running = Mutex<RunningService?>(nil)

    /// The OpenTelemetry service group and the task that runs it.
    private struct RunningService: Sendable {
        /// The group that holds the OpenTelemetry service. A graceful shutdown
        /// of the group flushes the exporters.
        let group: ServiceGroup

        /// The task that runs `group`. It ends when the group ends.
        let task: Task<Void, Never>
    }

    /// Bootstraps logging, tracing and metrics for this process. Call it one
    /// time, before the process writes a log record.
    ///
    /// When `OTel.bootstrap` throws, the reason goes to stderr, and the
    /// swift-log default handler stays in place. That handler also writes to
    /// stderr, so stdout stays for ACP frames.
    ///
    /// - Parameter environment: The process environment. It selects the
    ///   backend and configures the exporters.
    static func bootstrap(environment: [String: String]) {
        guard let endpoint = environment[otlpEndpointVariable], !endpoint.isEmpty else {
            LoggingSystem.bootstrap(StreamLogHandler.standardError)
            return
        }
        do {
            try startOpenTelemetry(environment: environment)
        } catch {
            makeDiagnosticLogger().error(
                "The OpenTelemetry bootstrap failed. Logs go to stderr, and traces and metrics are off.",
                metadata: ["error": "\(error)"])
        }
    }

    /// Stops the running OpenTelemetry service and waits until it ends, for
    /// ``shutdownDeadline`` at most. The graceful shutdown flushes the last
    /// batch of spans, log records and metrics. When no service runs, it
    /// does nothing.
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

    /// Bootstraps swift-otel from `environment` and starts its service.
    ///
    /// - Parameter environment: The process environment with the `OTEL_*`
    ///   variables.
    /// - Throws: The configuration or bootstrap error of `OTel.bootstrap`.
    private static func startOpenTelemetry(environment: [String: String]) throws {
        let service = try OTel.bootstrap(environment: environment)
        let diagnosticLogger = makeDiagnosticLogger()
        let group = ServiceGroup(services: [service], logger: diagnosticLogger)
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
