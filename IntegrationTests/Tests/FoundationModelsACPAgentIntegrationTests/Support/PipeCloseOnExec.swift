// `Pipe.markCloseOnExec()` — keep the pipes of one spawned child out of
// every other child.
//
// The suites of this package run at the same time, and each one spawns
// children. `AgentProcess` of the client package spawns with `posix_spawn`,
// and its child gets a copy of each descriptor of this process that does not
// carry `FD_CLOEXEC`. A `Pipe` of Foundation does not carry the flag. So a
// long-lived agent that `AgentProcess` spawns can hold the write end of the
// stdout pipe of a short `acp-agent` run, and the read of that run then never
// reaches its end of file. Measured: sixteen reads of `BuiltExecutableRun`
// waited on pipes that two `AgentProcess` agents held, every thread of the
// cooperative pool was blocked, and the whole test process stopped.

import Darwin
import Foundation

extension Pipe {
    /// Sets `FD_CLOEXEC` on both ends of this pipe, so no child that this
    /// process spawns later gets a copy of them.
    ///
    /// Call it before the `Process` that uses the pipe starts. `Process` puts
    /// the child end on descriptor 0, 1 or 2 with `dup2`, which clears the
    /// flag there, so the child of this pipe still gets its stream.
    func markCloseOnExec() {
        for handle in [fileHandleForReading, fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
    }
}
