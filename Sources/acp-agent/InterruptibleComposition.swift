/// The end of a composition the first `Ctrl-C` stopped (cli-plan.md §5.9).
///
/// It is not a failure. Nothing went wrong with the configuration, the
/// profile or the models — a person asked the download to stop, and it
/// stopped. The caller turns it into the `cancelled` stop reason, which
/// exit code 4 belongs to (§5.8).
struct CompositionInterrupted: Error {}

/// The `Ctrl-C` watch of the composition window: the configuration load, the
/// model download and the model load that stand between the command line and
/// the open wire (cli-plan.md §5.9).
///
/// **Why the composition needs its own window.** The turn's watch is armed
/// with a session open, so its reaction is a `session/cancel` over the wire.
/// Here the wire is not open and no session exists, so there is no addressee
/// and nothing to notify. What there is instead is one task doing the work,
/// and the reaction is to cancel it: `Router.resolve(profile:reporting:)`
/// honours task cancellation, stops the transfer, and leaves the part files it
/// already wrote in the Hugging Face cache, so the next run continues that
/// download rather than starting it again.
///
/// **The two windows never overlap.** This one is disarmed before the turn
/// arms its own, so `SIGINT` has exactly one watcher at any moment and the
/// disposition the second watch restores is the one the first watch left.
///
/// **`SIGTERM` stops the composition too.** A process manager that ends the
/// process during a model download gets the same cancel as the first
/// `Ctrl-C`. The window then throws ``TerminationHandler/signalEnd``, so the
/// failure path of ``AcpAgentCommand/main()`` flushes the telemetry and exits
/// 143.
enum InterruptibleComposition {
    /// Runs `compose` with the composition watches armed, and disarms the
    /// watches on the way out.
    ///
    /// The first `Ctrl-C` cancels the composition task. A later one ends the
    /// process at once through ``InterruptHandler/endAtOnce()``, for the same
    /// reason the turn's watch does: work that never checks for cancellation
    /// runs to its end, and a person must still be able to leave. The first
    /// `SIGTERM` cancels the composition task too.
    ///
    /// - Parameters:
    ///   - install: How this window gets its `Ctrl-C` watch. `run()` gives the
    ///     real `SIGINT` watch; a test gives a scripted one, so no suite arms
    ///     a process-wide signal.
    ///   - terminate: How this window gets its `SIGTERM` watch, on the same
    ///     terms. The default watches nothing.
    ///   - compose: The composition work to run under the watches.
    /// - Returns: Whatever `compose` produced.
    /// - Throws: ``TerminationHandler/signalEnd`` when a `SIGTERM` arrived,
    ///   ``CompositionInterrupted`` when the first `Ctrl-C` cancelled the
    ///   composition, or whatever `compose` throws.
    static func run<Composition: Sendable>(
        interruptedBy install: InterruptHandler.Installer,
        terminatedBy terminate: TerminationHandler.Installer = TerminationHandler.unwatched,
        _ compose: @escaping @Sendable () async throws -> Composition
    ) async throws -> Composition {
        let composition = Task { try await compose() }
        return try await TerminationHandler.run(
            watchedBy: terminate, stoppingWith: { composition.cancel() }
        ) {
            try await awaitComposition(composition, interruptedBy: install)
        }
    }

    /// Waits for `composition` with the `Ctrl-C` watch armed, and disarms the
    /// watch on the way out.
    ///
    /// - Parameters:
    ///   - composition: The task that runs the composition work.
    ///   - install: How this window gets its `Ctrl-C` watch.
    /// - Returns: Whatever the composition produced.
    /// - Throws: ``CompositionInterrupted`` when the composition task was
    ///   cancelled, or whatever the composition throws.
    private static func awaitComposition<Composition: Sendable>(
        _ composition: Task<Composition, any Error>,
        interruptedBy install: InterruptHandler.Installer
    ) async throws -> Composition {
        let watch = install()
        defer { watch.disarm() }
        let watching = Task {
            await InterruptHandler.react(to: watch.arrivals) { composition.cancel() }
        }
        defer { watching.cancel() }
        do {
            return try await composition.value
        } catch {
            // The composition wraps its own errors — a resolution failure
            // carries a message rather than the error it came from — so the
            // task's own cancellation flag, and not the error's type, is what
            // says a person stopped this run.
            guard composition.isCancelled else {
                throw error
            }
            throw CompositionInterrupted()
        }
    }
}
