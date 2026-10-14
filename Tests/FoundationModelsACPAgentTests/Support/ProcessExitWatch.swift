import Dispatch
import Foundation

/// The wait for the exit of a process of this machine.
///
/// The wait watches the process with a kernel event source (a process
/// source for `exit`), so it uses no clock and no poll.
enum ProcessExitWatch {
    /// Waits until the process `pid` exited.
    ///
    /// The source is armed first. A process that exited before the arm sends
    /// no event, so after the arm the wait reads one time, with `isGone`,
    /// whether the process is already gone. A process that is a zombie still
    /// answers `kill(pid, 0)`, so the caller gives that read.
    ///
    /// - Parameters:
    ///   - pid: The process to watch.
    ///   - isGone: Tells if the process is gone. It is read one time, after
    ///     the arm.
    static func waitForExit(of pid: pid_t, isGone: @escaping @Sendable () -> Bool) async {
        let queue = DispatchQueue(label: "ProcessExitWatch")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let exited = OneShot()
        source.setEventHandler {
            exited.fire(true)
        }
        defer { source.cancel() }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exited.arm(continuation)
            source.resume()
            queue.async {
                if isGone() {
                    exited.fire(true)
                }
            }
        }
    }
}
