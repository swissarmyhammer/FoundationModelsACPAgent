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
enum InterruptibleComposition {
    /// Runs `compose` with the composition watch armed, and disarms the watch
    /// on the way out.
    ///
    /// The first arrival cancels the composition task. A later arrival ends
    /// the process at once through ``InterruptHandler/endAtOnce()``, for the
    /// same reason the turn's watch does: work that never checks for
    /// cancellation runs to its end, and a person must still be able to leave.
    ///
    /// - Parameters:
    ///   - install: How this window gets its `Ctrl-C` watch. `run()` gives the
    ///     real `SIGINT` watch; a test gives a scripted one, so no suite arms
    ///     a process-wide signal.
    ///   - compose: The composition work to run under the watch.
    /// - Returns: Whatever `compose` produced.
    /// - Throws: ``CompositionInterrupted`` when the first arrival cancelled
    ///   the composition, or whatever `compose` throws.
    static func run<Composition: Sendable>(
        interruptedBy install: InterruptHandler.Installer,
        _ compose: @escaping @Sendable () async throws -> Composition
    ) async throws -> Composition {
        let watch = install()
        defer { watch.disarm() }
        let composition = Task { try await compose() }
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
