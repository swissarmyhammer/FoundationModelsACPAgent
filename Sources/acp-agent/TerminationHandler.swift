import ArgumentParser
import Darwin
import Dispatch

/// The `SIGTERM` watch of one window: what arrived, and how to end the
/// watch.
struct TerminationWatch: Sendable {
    /// One element for each `SIGTERM` that arrived while the watch stood.
    let arrivals: AsyncStream<Void>

    /// Ends the watch: the source stops, ``arrivals`` finishes, and
    /// `SIGTERM` gets its default disposition back.
    let disarm: @Sendable () -> Void
}

/// The `SIGTERM` end of `acp-agent`.
///
/// A process manager ends a process with `SIGTERM`. The default action of
/// the signal ends the process at once, and the OTLP batch exporters then
/// lose their last batch. So each long window of `acp` and `run` watches the
/// signal. On `SIGTERM` the window stops its work and throws ``signalEnd``.
/// The failure path of ``AcpAgentCommand/main()`` then shuts the telemetry
/// down (``TelemetryBootstrap/shutdown()``, which flushes the last batch) and
/// exits ``signalEndExitCode``.
///
/// **Each window has its own stop**, because each window has different work
/// to stop:
///
/// - The ACP serve window of `acp` closes the ACP connection
///   (``serve(untilInboundEnd:closing:watchedBy:)``).
/// - The composition window of `acp` and of `run` — the configuration load,
///   the model download and the model load — cancels the composition task,
///   as the first `Ctrl-C` does (``InterruptibleComposition``).
/// - The prompt window of `run` sends `session/cancel`, as the first `Ctrl-C`
///   does (``RunPrompt``). The out-of-process handshake reaps the child.
///
/// The windows never overlap, so `SIGTERM` has one watcher at most at each
/// moment. Outside them `SIGTERM` keeps its default action: the read of the
/// prompt text, the short open of the wire, and the `config`,
/// `instructions` and `doctor` subcommands, which hold no model, no
/// connection and no session.
///
/// A later `SIGTERM` in a window that already stops does nothing more. The
/// watch still stands, so the signal does not end the process before the
/// flush.
///
/// The watch has the same shape as ``InterruptHandler/onSIGINT``: a
/// `DispatchSourceSignal` reports each arrival on a normal queue, and the
/// reaction runs on a normal task.
enum TerminationHandler {
    /// How a window gets its watch: a closure, so `run()` gives the
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

    /// The error a window throws so the process ends with
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

    /// The watch of a window no signal reaches: the stream is finished
    /// before it is read, so the stop never runs.
    ///
    /// It is the default of each window, so a caller that says nothing about
    /// `SIGTERM` arms nothing.
    static var unwatched: Installer {
        { TerminationWatch(arrivals: AsyncStream { $0.finish() }, disarm: {}) }
    }

    /// Runs `work` with the `SIGTERM` watch armed, and disarms the watch on
    /// the way out.
    ///
    /// The first arrival runs `stop`, which must make `work` end soon. When
    /// `work` ends after an arrival, the window throws ``signalEnd`` in place
    /// of the value or the error of `work`: the process ends because of the
    /// signal, and not because of the stop that the signal caused.
    ///
    /// - Parameters:
    ///   - install: How this window gets its `SIGTERM` watch.
    ///   - stop: What the first arrival does to the work.
    ///   - work: The work of the window.
    /// - Returns: The value of `work`, when no `SIGTERM` arrived.
    /// - Throws: ``signalEnd`` when a `SIGTERM` arrived, and otherwise
    ///   whatever `work` throws.
    static func run<Outcome>(
        watchedBy install: Installer,
        stoppingWith stop: @escaping @Sendable () async -> Void,
        _ work: () async throws -> Outcome
    ) async throws -> Outcome {
        let terminated = ArrivalFlag()
        let watch = install()
        let watching = Task {
            for await _ in watch.arrivals {
                terminated.raise()
                await stop()
                return
            }
        }
        defer {
            watch.disarm()
            watching.cancel()
        }
        let outcome: Result<Outcome, any Error>
        do {
            outcome = .success(try await work())
        } catch {
            outcome = .failure(error)
        }
        guard !terminated.isRaised else {
            throw signalEnd
        }
        return try outcome.get()
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
