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
    /// answers `kill(pid, 0)`, so the caller gives that read, for example
    /// ``hasExited(_:)``.
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

extension ProcessExitWatch {
    /// The `pbi_status` of a zombie: a process that exited and that its
    /// parent did not reap yet (`SZOMB` of `sys/proc.h`).
    private static let zombieStatus: UInt32 = 5

    /// Tells if the process `pid` no longer runs: it is gone, or it is a
    /// zombie that exited and waits for its parent to reap it. `pgrep` can
    /// still list a zombie, so a check that a process ended reads this.
    ///
    /// - Parameter pid: The process to read.
    /// - Returns: `true` when the process exited.
    static func hasExited(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0, errno == ESRCH {
            return true
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // The parent reaped the process between the two reads.
            return errno == ESRCH
        }
        return info.pbi_status == zombieStatus
    }
}
