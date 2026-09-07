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
/// ``cancelledExitCode``. The second signal ends the process at once,
/// because a model whose generate loop never checks for cancellation
/// runs to its end and a person must still be able to leave.
///
/// **The watch stands for the turn, and only for the turn.**
/// ``RunTurn`` arms it after the composition and disarms it when the
/// turn settles. Outside that window `SIGINT` keeps its default
/// disposition and ends the process, which is what a person expects
/// during a model download: the resolution cannot be interrupted today
/// — `Router.resolve(profile:reporting:)` honours no Task cancellation,
/// and the wire is not even open yet — so a watch that swallowed the
/// signal there would make the CLI look frozen. Card `^54ay5s0` carries
/// that work, and this window widens when it lands.
enum InterruptHandler {
    /// How a turn gets its watch: a closure, so `run()` gives the real
    /// `SIGINT` watch and a test gives a scripted one. No suite arms a
    /// process-wide signal.
    typealias Installer = @Sendable () -> InterruptWatch

    /// The exit code of a cancelled run (cli-plan.md §5.8).
    static let cancelledExitCode: Int32 = 4

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

    /// Ends the process at once, for the second `Ctrl-C`.
    ///
    /// `_exit(2)` and not `exit(3)`: "at once" means no `atexit` handler
    /// and no library teardown runs. Nothing is lost by that. The answer
    /// went out through `write(2)`, which carries no user-space buffer,
    /// so every byte the person saw is already on the descriptor.
    ///
    /// - Returns: Never; the process is gone.
    static func endAtOnce() -> Never {
        Darwin._exit(cancelledExitCode)
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
