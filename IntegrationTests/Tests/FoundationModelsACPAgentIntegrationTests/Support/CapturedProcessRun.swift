// `CapturedProcessRun` — one run of a child process, read to its end.
//
// `BuiltExecutableRun` runs a built executable, `ProcessCensus` runs
// `pgrep(1)` and `TemporaryKeychain` runs `security(1)`. Each one starts the
// child, reads its output to the end, waits for the exit and reads the status.
// This type holds those steps, so the close-on-exec marks, the read that
// stands before the wait, and the exit wait stand in one place.
//
// `SignalledExecutableRun` and `SpawnedACPAgent` read the output as it comes,
// and signal the child or write to it while it runs, so they do not run
// through this type.

import Foundation

/// One finished run of a child process: its exit status and the bytes it
/// wrote to each pipe the run read.
struct CapturedProcessRun {
    /// Where a system tool's stderr goes.
    enum ErrorOutput {
        /// Into the stdout pipe, so ``CapturedProcessRun/standardOutput``
        /// holds both streams in the order the tool wrote them.
        case mergedIntoOutput

        /// Into a pipe of its own, so ``CapturedProcessRun/standardError``
        /// holds it apart from the stdout.
        case captured

        /// To the stderr of this test process, which the test log shows.
        case inherited
    }

    /// Why a system tool's run failed: it exited with a status its caller
    /// does not read as a sound result.
    struct Failure: Error, CustomStringConvertible {
        /// The tool, and its subcommand when it has one, such as
        /// `security create-keychain`. The other arguments are left out,
        /// because one of them can be a password.
        let command: String

        /// The exit status of the tool.
        let status: Int32

        /// What the tool wrote to say why it failed.
        let output: String

        /// The command, the status and the output.
        var description: String {
            "\(command) exited with status \(status): \(output)"
        }
    }

    /// The exit status of the child, or the signal number when a signal with
    /// no handler ended it.
    let exitCode: Int32

    /// The bytes of the stdout pipe.
    let standardOutput: Data

    /// The bytes of the stderr pipe, and none when the run read no stderr
    /// pipe of its own.
    let standardError: Data

    /// Runs the system tool at `path` with `arguments`, with no shell between.
    ///
    /// - Parameters:
    ///   - path: The absolute path of the tool.
    ///   - arguments: The command-line arguments of the tool.
    ///   - errorOutput: Where the tool's stderr goes.
    /// - Returns: The finished run.
    /// - Throws: The spawn or read error, or ``ConditionWaitCancelled`` when
    ///   the test is cancelled before the tool exits.
    static func run(
        toolAt path: String, arguments: [String], errorOutput: ErrorOutput
    ) async throws -> CapturedProcessRun {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: path)
        tool.arguments = arguments
        let output = Pipe()
        tool.standardOutput = output
        let error = connect(errorOutput, of: tool, besideOutput: output)
        return try await run(tool, standardOutput: output, standardError: error)
    }

    /// Sends the stderr of `tool` where `errorOutput` says.
    ///
    /// - Parameters:
    ///   - errorOutput: Where the tool's stderr goes.
    ///   - tool: The tool, not yet started.
    ///   - output: The stdout pipe of the tool.
    /// - Returns: The tool's own stderr pipe when its stderr is captured
    ///   apart, and `nil` when it goes into `output` or is inherited.
    private static func connect(
        _ errorOutput: ErrorOutput, of tool: Process, besideOutput output: Pipe
    ) -> Pipe? {
        switch errorOutput {
        case .mergedIntoOutput:
            tool.standardError = output
            return nil
        case .captured:
            let error = Pipe()
            tool.standardError = error
            return error
        case .inherited:
            return nil
        }
    }

    /// Starts `process`, reads its pipes to their ends, and waits until it
    /// exits.
    ///
    /// Each pipe gets `FD_CLOEXEC` before the start (see
    /// `Pipe.markCloseOnExec()`), so no other child of this process holds a
    /// copy of it. The reads stand before the wait: a full pipe buffer would
    /// block the child.
    ///
    /// - Parameters:
    ///   - process: The child, set up and not yet started, with
    ///     `standardOutput` (and `standardError`, when given) as its pipes.
    ///   - standardOutput: The stdout pipe of the child.
    ///   - standardError: The stderr pipe of the child, or `nil` when the
    ///     child has no stderr pipe of its own.
    /// - Returns: The finished run.
    /// - Throws: The spawn or read error, or ``ConditionWaitCancelled`` when
    ///   the test is cancelled before the child exits.
    static func run(
        _ process: Process, standardOutput: Pipe, standardError: Pipe?
    ) async throws -> CapturedProcessRun {
        for pipe in [standardOutput, standardError].compactMap({ $0 }) {
            pipe.markCloseOnExec()
        }
        let exit = ProcessExitEvent(watching: process)
        try process.run()
        async let output = readToEnd(standardOutput)
        async let error = readToEnd(standardError)
        try await exit.wait()
        return CapturedProcessRun(
            exitCode: process.terminationStatus,
            standardOutput: try await output,
            standardError: try await error)
    }

    /// Reads `pipe` until it reaches its end.
    ///
    /// - Parameter pipe: The pipe to read, or `nil` for none.
    /// - Returns: The bytes read, and none for no pipe.
    /// - Throws: The read error.
    private static func readToEnd(_ pipe: Pipe?) throws -> Data {
        try pipe?.fileHandleForReading.readToEnd() ?? Data()
    }
}
