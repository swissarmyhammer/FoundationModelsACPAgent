import Darwin
import Foundation

/// The kernel state of a process of this machine, as the exit waits of the
/// tests read it.
///
/// The unit tests (`ProcessExitWatch`) and the integration tests
/// (`ArmedProcessExit`) both ask whether a process already exited, before
/// they wait for its exit event. This one home keeps the zombie, exit and
/// sysctl reading in one place, so the two sides cannot drift apart.
public enum ProcessState {
  /// Tells if the process `pid` no longer runs: it is gone, it is in its
  /// exit (`P_WEXIT`), or it is a zombie (`SZOMB`) that waits for its
  /// parent to reap it. A process in its exit can already have sent its
  /// exit event, before the kernel makes it a zombie.
  ///
  /// Read this only one time, after the arm of an exit event source.
  /// Do not read it again after the wait: after the reap the system can give
  /// the pid to a new process.
  ///
  /// - Parameter pid: The process to read.
  /// - Returns: `true` when the process exited or is in its exit.
  public static func hasExited(_ pid: pid_t) -> Bool {
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
