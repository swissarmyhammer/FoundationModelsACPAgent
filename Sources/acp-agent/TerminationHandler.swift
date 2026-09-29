import ArgumentParser
import Darwin
import Dispatch

/// The `SIGTERM` watch of the ACP serve window: what arrived, and how to end
/// the watch.
struct TerminationWatch: Sendable {
    /// One element for each `SIGTERM` that arrived while the watch stood.
    let arrivals: AsyncStream<Void>

    /// Ends the watch: the source stops, ``arrivals`` finishes, and
    /// `SIGTERM` gets its default disposition back.
    let disarm: @Sendable () -> Void
}

/// The `SIGTERM` end of `acp-agent acp`.
///
/// A process manager ends a server with `SIGTERM`. The default action of
/// the signal ends the process at once, and the OTLP batch exporters then
/// lose their last batch. So the ACP serve window watches the signal. On
/// `SIGTERM` it closes the ACP connection and throws ``signalEnd``. The
/// failure path of ``AcpAgentCommand/main()`` then shuts the telemetry down
/// (``TelemetryBootstrap/shutdown()``, which flushes the last batch) and
/// exits ``signalEndExitCode``.
///
/// **The watch stands for the ACP serve window only.** That window has the
/// ACP connection to close. Outside it — the composition of `acp` mode, and
/// each other subcommand — `SIGTERM` keeps its default action.
///
/// The watch has the same shape as ``InterruptHandler/onSIGINT``: a
/// `DispatchSourceSignal` reports each arrival on a normal queue, and the
/// reaction runs on a normal task.
enum TerminationHandler {
    /// How the serve window gets its watch: a closure, so `run()` gives the
    /// real `SIGTERM` watch and a test gives a scripted one. No suite arms a
    /// process-wide signal.
    typealias Installer = @Sendable () -> TerminationWatch

    /// The base that a shell adds to the number of the signal that ended a
    /// process.
    private static let shellSignalExitBase: Int32 = 128

    /// The exit code of an end by `SIGTERM`: 143, the code a shell reports
    /// for a process that `SIGTERM` ended.
    ///
    /// It is not a row of the cli-plan.md §5.8 table, which lists the
    /// outcomes of a prompt and of a report. It is the convention of the
    /// shell for an end by a signal, so a script reads the same code as for
    /// a process with no handler.
    static let signalEndExitCode: Int32 = shellSignalExitBase + SIGTERM

    /// The error the serve window throws so the process ends with
    /// ``signalEndExitCode``.
    ///
    /// ArgumentParser renders a thrown `ExitCode` with an empty message, so
    /// nothing is written to either stream.
    static var signalEnd: ExitCode {
        ExitCode(signalEndExitCode)
    }

    /// The real watch: a `DispatchSourceSignal` for `SIGTERM`.
    static var onSIGTERM: Installer {
        { install() }
    }

    /// How the ACP serve window ended.
    private enum ServeEnd: Sendable {
        /// The inbound stream ended: the client closed stdin.
        case inboundEnded

        /// A `SIGTERM` arrived.
        case terminated
    }

    /// Serves until the inbound stream ends or a `SIGTERM` arrives, then
    /// closes the ACP connection.
    ///
    /// The watch is armed for the whole wait and disarmed on the way out.
    ///
    /// - Parameters:
    ///   - inboundEnd: Returns when the inbound stream ends. It must return
    ///     when its task is cancelled.
    ///   - close: Closes the ACP connection.
    ///   - install: How this window gets its `SIGTERM` watch.
    /// - Throws: ``signalEnd`` after the close, when a `SIGTERM` ended the
    ///   window.
    static func serve(
        untilInboundEnd inboundEnd: @escaping @Sendable () async -> Void,
        closing close: () async -> Void,
        watchedBy install: Installer
    ) async throws {
        let watch = install()
        defer { watch.disarm() }
        let end = await firstEnd(inboundEnd: inboundEnd, arrivals: watch.arrivals)
        await close()
        guard end == .inboundEnded else {
            throw signalEnd
        }
    }

    /// Waits for the first of two ends: the end of the inbound stream, or the
    /// first `SIGTERM`.
    ///
    /// Both waits end when their task is cancelled, so a task group can race
    /// them: the first end cancels the other wait.
    ///
    /// - Parameters:
    ///   - inboundEnd: Returns when the inbound stream ends.
    ///   - arrivals: The `SIGTERM` arrivals of the watch.
    /// - Returns: The end that came first. A watch that finishes with no
    ///   arrival leaves the decision to the inbound stream.
    private static func firstEnd(
        inboundEnd: @escaping @Sendable () async -> Void,
        arrivals: AsyncStream<Void>
    ) async -> ServeEnd {
        await withTaskGroup(of: ServeEnd?.self) { group in
            group.addTask {
                await inboundEnd()
                return .inboundEnded
            }
            group.addTask {
                for await _ in arrivals {
                    return .terminated
                }
                return nil
            }
            for await case let end? in group {
                group.cancelAll()
                return end
            }
            return .inboundEnded
        }
    }

    /// Arms the watch.
    ///
    /// `SIGTERM` is ignored first, because its default disposition ends the
    /// process. A `DispatchSourceSignal` observes the signal, it does not
    /// consume it, so the ignore is what keeps the process alive while the
    /// source reports each arrival on a normal queue.
    ///
    /// - Returns: The armed watch.
    private static func install() -> TerminationWatch {
        signal(SIGTERM, SIG_IGN)
        let (arrivals, continuation) = AsyncStream<Void>.makeStream()
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            continuation.yield()
        }
        source.resume()
        return TerminationWatch(
            arrivals: arrivals,
            disarm: {
                source.cancel()
                continuation.finish()
                signal(SIGTERM, SIG_DFL)
            })
    }
}
