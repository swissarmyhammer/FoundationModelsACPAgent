import Darwin
import Dispatch
import Foundation
import Synchronization

/// The `Ctrl-C` watch of one turn: what arrived, and how to end the
/// watch (cli-plan.md §5.9).
struct InterruptWatch: Sendable {
    /// The ordinal of each `SIGINT` that arrived while the watch stood:
    /// 1 for the first, 2 for the second, and up.
    ///
    /// The ordinal and not a plain signal, because §5.9 gives the first
    /// and the second signal two different jobs, and a reader that
    /// counted them itself could disagree with the handler.
    let arrivals: AsyncStream<Int>

    /// Ends the watch: the source stops, ``arrivals`` finishes, and
    /// `SIGINT` gets its killing default disposition back.
    let disarm: @Sendable () -> Void
}

/// The state the signal handler touches, and nothing else.
///
/// A signal handler must be async-signal-safe: it may allocate nothing,
/// take no lock, and call nothing that could do either. So the handler
/// reaches these two members and stops — one atomic add, and one resume
/// of the continuation a normal task is parked on. Every other step of
/// the interrupt — the `session/cancel`, the wait for the stop reason,
/// the exit — happens on that normal task.
private final class InterruptState: Sendable {
    /// How many `SIGINT`s arrived. The flag of §5.9, and the source of
    /// the ordinal each arrival carries.
    let count = Atomic<Int>(0)

    /// The continuation the waiting task is parked on.
    let arrivals: AsyncStream<Int>.Continuation

    /// Wires the state to the stream the waiting task reads.
    ///
    /// - Parameter arrivals: The continuation of that stream.
    init(arrivals: AsyncStream<Int>.Continuation) {
        self.arrivals = arrivals
    }
}

/// The interrupt of one `run` turn (cli-plan.md §5.9).
///
/// **`Ctrl-C` must not kill the process.** The first signal sends
/// `session/cancel`, waits for the `cancelled` stop reason, leaves the
/// text that already arrived on stdout, and exits
/// ``AgentExitCode/cancelled``. The second signal ends the process at once,
/// because a model whose generate loop never checks for cancellation
/// runs to its end and a person must still be able to leave.
///
/// **The watch stands for two windows, one after the other.**
/// ``InterruptibleComposition`` arms it for the composition — the
/// configuration load, the model download and the model load — and
/// disarms it once the composition is done. ``RunTurn`` then arms it
/// again for the turn and disarms it when the turn settles. The two
/// never overlap, so `SIGINT` has exactly one watcher at any moment.
///
/// The reaction differs, because the addressee does. During the turn
/// the wire is open and a session exists, so the first signal sends
/// `session/cancel`. During the composition neither exists, so the
/// first signal cancels the composition task instead:
/// `Router.resolve(profile:reporting:)` honours task cancellation
/// (card `^54ay5s0`), stops the transfer, and leaves the part files in
/// the Hugging Face cache. Outside both windows `SIGINT` keeps its
/// default disposition and ends the process.
enum InterruptHandler {
    /// How a turn gets its watch: a closure, so `run()` gives the real
    /// `SIGINT` watch and a test gives a scripted one. No suite arms a
    /// process-wide signal.
    typealias Installer = @Sendable () -> InterruptWatch

    /// The ordinal of the first arrival — the one that cancels.
    static let firstArrival = 1

    /// The watch of a turn no signal reaches: the stream is finished
    /// before it is read, so the reaction never runs.
    ///
    /// It is the default of every turn, so a caller that says nothing
    /// about interrupts arms nothing.
    static var unwatched: Installer {
        { InterruptWatch(arrivals: AsyncStream { $0.finish() }, disarm: {}) }
    }

    /// The real watch: a `DispatchSourceSignal` for `SIGINT`.
    static var onSIGINT: Installer {
        { install() }
    }

    /// Reacts to each arrival of `arrivals`: the first one runs `stop`,
    /// and every later one ends the process at once.
    ///
    /// Both windows of §5.9 read their arrivals through this loop, so the
    /// ordinal contract stands in one place and cannot drift between them.
    /// Only the stop differs: the turn sends `session/cancel`, and the
    /// composition cancels its task.
    ///
    /// - Parameters:
    ///   - arrivals: The ordinals of the watch.
    ///   - stop: What the first arrival does.
    static func react(
        to arrivals: AsyncStream<Int>, stoppingWith stop: () async -> Void
    ) async {
        for await ordinal in arrivals {
            guard ordinal == firstArrival else {
                endAtOnce()
            }
            await stop()
        }
    }

    /// Ends the process at once, for the second `Ctrl-C`.
    ///
    /// `_exit(2)` and not `exit(3)`: "at once" means no `atexit` handler
    /// and no library teardown runs. Nothing is lost by that. The answer
    /// went out through `write(2)`, which carries no user-space buffer,
    /// so every byte the person saw is already on the descriptor.
    ///
    /// - Returns: Never; the process is gone.
    static func endAtOnce() -> Never {
        Darwin._exit(AgentExitCode.cancelled.rawValue)
    }

    /// Arms the watch.
    ///
    /// `SIGINT` is ignored first, because its default disposition ends
    /// the process. A `DispatchSourceSignal` observes the signal, it
    /// does not consume it, so the ignore is what keeps the process
    /// alive while the source reports each arrival on a normal queue.
    ///
    /// - Returns: The armed watch.
    private static func install() -> InterruptWatch {
        signal(SIGINT, SIG_IGN)
        let (arrivals, continuation) = AsyncStream<Int>.makeStream()
        let state = InterruptState(arrivals: continuation)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            let ordinal = state.count.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
            state.arrivals.yield(ordinal)
        }
        source.resume()
        return InterruptWatch(
            arrivals: arrivals,
            disarm: {
                source.cancel()
                continuation.finish()
                signal(SIGINT, SIG_DFL)
            })
    }
}
