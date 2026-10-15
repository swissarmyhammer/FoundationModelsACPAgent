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
    /// The end of the wait is the result. Do not read the state of `pid`
    /// again after the wait: the kernel sends the exit event before it makes
    /// the process a zombie, and after the reap the system can give the pid
    /// to a new process.
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
    /// Tells if the process `pid` no longer runs: it is gone, it is in its
    /// exit (`P_WEXIT`), or it is a zombie (`SZOMB`) that waits for its
    /// parent to reap it. A process in its exit can already have sent its
    /// exit event, before the kernel makes it a zombie.
    ///
    /// Read this only before a wait, as the `isGone` read of
    /// ``waitForExit(of:isGone:)``.
    ///
    /// - Parameter pid: The process to read.
    /// - Returns: `true` when the process exited or is in its exit.
    static func hasExited(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0, errno == ESRCH {
            return true
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            // No answer: the exit event ends the wait.
            return false
        }
        guard size > 0 else {
            // The parent reaped the process between the two reads.
            return true
        }
        return Int32(info.kp_proc.p_stat) == SZOMB || info.kp_proc.p_flag & P_WEXIT != 0
    }
}
