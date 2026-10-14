// `SignalledExecutableRun` — one run of a built executable that a
// signal, or two, ended: `SIGINT` by default, or `SIGTERM`.
//
// `BuiltExecutableRun` starts a process and waits for it. An interrupt
// proof needs two things that plain run cannot give: it must know when
// the child has begun to answer, so the signal lands inside a live prompt
// and not before it; and it must send more than one signal, and say how
// many of them reached a child that was still there. Each wait is an
// event (the first stdout byte, the exit of the child), with no clock: a
// child that ignores the interrupt holds the test, and a sample of the
// test process shows where it waits.

import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport

/// One finished run of a built executable that this process signalled.
struct SignalledExecutableRun {
    /// The process exit code, or the signal number when a signal with no
    /// handler ended the child.
    let exitCode: Int32

    /// `true` when the child called `exit`, and `false` when a signal with no
    /// handler ended it.
    let didExit: Bool

    /// The time from the last signal to the end of the child. It is a
    /// measurement for the report; no wait reads it.
    let exitWait: Swift.Duration

    /// The captured stdout text.
    let standardOutput: String

    /// The captured stderr text.
    let standardError: String

    /// How many signals actually reached the child.
    ///
    /// It can be fewer than the run asked for: a child that ends on one
    /// signal is gone before the next one is due, and this runner never
    /// signals a pid it no longer owns.
    let signalsSent: Int

    /// The captured output of a running child. A wait for the first stdout
    /// byte is an event: each append checks it again.
    private final class Store: Sendable {
        /// The stdout bytes so far, with their waits.
        let output = WatchedValue(Data())

        /// The stderr bytes so far.
        let error = WatchedValue(Data())

        /// Appends stdout bytes.
        ///
        /// - Parameter chunk: The bytes read.
        func appendOutput(_ chunk: Data) {
            output.update { $0.append(chunk) }
        }

        /// Appends stderr bytes.
        ///
        /// - Parameter chunk: The bytes read.
        func appendError(_ chunk: Data) {
            error.update { $0.append(chunk) }
        }
    }

    /// Runs the built executable `executableName`, waits for its first
    /// stdout byte, sends `signalCount` signals back to back, and waits for
    /// it to end.
    ///
    /// The child gets `configHome` as `XDG_CONFIG_HOME` and every pair of
    /// `environment` on top of `inheritedEnvironment`.
    ///
    /// - Parameters:
    ///   - executableName: The product name of the executable to run.
    ///   - arguments: The command-line arguments for the executable.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    ///   - inheritedEnvironment: The environment the child starts from. The
    ///     default is this process's environment; a caller that must keep a
    ///     variable of this process out of the child gives a filtered copy.
    ///   - environment: The extra environment pairs.
    ///   - atFirstOutput: What to do once the child has written its first
    ///     stdout byte, and before the first signal goes out. It gets the
    ///     child's own process identifier, so a caller can read a fact that
    ///     holds only while the run is live — which processes this child
    ///     started, for one. The default does nothing, so a caller that
    ///     says nothing about the live run observes none of it.
    ///   - signalNumber: The signal to send. The default is `SIGINT`, the
    ///     signal of `Ctrl-C`; a `SIGTERM` case gives `SIGTERM`.
    ///   - signalCount: How many signals to send, back to back, so each one
    ///     reaches a child that ends on the first one.
    ///   - chunkGate: The named pipe of the chunk gate of the stub model
    ///     (`ACP_AGENT_STUB_CHUNK_GATE`), or `nil` (the default) for a child
    ///     with no gate. With a gate, the run lets only the first chunk go.
    ///     After `atFirstOutput`, a run with no signal lets each later chunk
    ///     go. A run with signals sends them while the prompt is held, so
    ///     each signal lands before the chunks end, and it lets the chunks
    ///     go only after the child ended.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error, or what `atFirstOutput` throws.
    static func run(
        executableNamed executableName: String,
        arguments: [String],
        workspace: URL,
        configHome: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environment: [String: String],
        atFirstOutput: @Sendable (pid_t) async throws -> Void = { _ in },
        signalNumber: Int32 = SIGINT,
        signalCount: Int,
        chunkGate: URL? = nil
    ) async throws -> SignalledExecutableRun {
        let child = try PipedChildProcess(
            executableNamed: executableName,
            arguments: arguments,
            workspace: workspace,
            inheritedEnvironment: inheritedEnvironment,
            environment: PipedChildProcess.environment(configHome: configHome, adding: environment))
        let process = child.process
        let standardOutputPipe = child.standardOutput
        let standardErrorPipe = child.standardError

        let store = Store()
        let exit = ProcessExitEvent(watching: process)
        try process.run()
        // Read both pipes as the child writes, so the first-output wait
        // gets each byte and a full pipe buffer never blocks the child.
        let draining = Task.detached {
            async let output: Void = drain(standardOutputPipe) { store.appendOutput($0) }
            async let error: Void = drain(standardErrorPipe) { store.appendError($0) }
            _ = await (output, error)
        }

        var gate: StubChunkGateWriter?
        if let chunkGate {
            gate = try await StubChunkGateWriter.open(at: chunkGate)
            try gate?.releaseOneChunk()
        }
        _ = try await store.output.wait(for: "the first stdout byte of the child") { !$0.isEmpty }
        // The child has answered and has not been signalled, so this is the
        // one moment a caller can read what a live run carries. The gate
        // holds the prompt open here.
        try await atFirstOutput(process.processIdentifier)
        if signalCount == 0 {
            try gate?.releaseAllChunks()
        }
        var signalsSent = 0
        for _ in 0..<signalCount {
            // A child that already ended has given its pid back, and the
            // system may have handed it to another process. So the run
            // signals only a child it still owns.
            guard process.isRunning else {
                break
            }
            kill(process.processIdentifier, signalNumber)
            signalsSent += 1
        }
        let clock = ContinuousClock()
        let lastSignal = clock.now
        try await exit.wait()
        let exitWait = clock.now - lastSignal
        if signalCount > 0 {
            try gate?.releaseAllChunks()
        }

        await draining.value
        return SignalledExecutableRun(
            exitCode: process.terminationStatus,
            didExit: process.terminationReason == .exit,
            exitWait: exitWait,
            standardOutput: String(decoding: store.output.value, as: UTF8.self),
            standardError: String(decoding: store.error.value, as: UTF8.self),
            signalsSent: signalsSent)
    }

    /// Reads `pipe` until it reaches its end, handing each chunk over. Each
    /// read blocks in the kernel until bytes or the end come.
    ///
    /// - Parameters:
    ///   - pipe: The pipe to read.
    ///   - receive: What each chunk goes to.
    private static func drain(_ pipe: Pipe, receive: @Sendable (Data) -> Void) async {
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                return
            }
            receive(chunk)
        }
    }
}
