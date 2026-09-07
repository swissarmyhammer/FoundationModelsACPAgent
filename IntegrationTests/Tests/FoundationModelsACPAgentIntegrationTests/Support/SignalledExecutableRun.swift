// `SignalledExecutableRun` — one run of a built executable that a
// `SIGINT`, or two, ended.
//
// `BuiltExecutableRun` starts a process and waits for it. An interrupt
// proof needs three things that plain run cannot give: it must know when
// the child has begun to answer, so the signal lands inside a live turn
// and not before it; it must send more than one signal, and say how many
// of them reached a child that was still there; and it must bound the
// wait, so a child that ignores the interrupt fails the test instead of
// hanging it.

import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport

/// What went wrong with a signalled run.
struct SignalledRunError: Error, CustomStringConvertible {
    /// The name of the wait that ran out.
    let wait: String

    /// How long the wait was given.
    let limit: Swift.Duration

    var description: String {
        "the child did not \(wait) inside \(limit)"
    }
}

/// One finished run of a built executable that this process interrupted.
struct SignalledExecutableRun {
    /// The number of milliseconds in ``pollInterval``.
    private static let pollIntervalMilliseconds = 20

    /// The pause between two looks at the child.
    private static let pollInterval: Swift.Duration = .milliseconds(pollIntervalMilliseconds)

    /// The process exit code.
    let exitCode: Int32

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

    /// The captured output of a running child.
    private actor Store {
        /// The stdout bytes so far.
        private(set) var output = Data()

        /// The stderr bytes so far.
        private(set) var error = Data()

        /// Appends stdout bytes.
        ///
        /// - Parameter chunk: The bytes read.
        func appendOutput(_ chunk: Data) {
            output.append(chunk)
        }

        /// Appends stderr bytes.
        ///
        /// - Parameter chunk: The bytes read.
        func appendError(_ chunk: Data) {
            error.append(chunk)
        }
    }

    /// Runs the built executable `executableName`, waits for its first
    /// stdout byte, sends `signalCount` interrupts, and waits for it to
    /// end.
    ///
    /// The child gets `configHome` as `XDG_CONFIG_HOME` and every pair of
    /// `environment` on top of this process's environment.
    ///
    /// - Parameters:
    ///   - executableName: The product name of the executable to run.
    ///   - arguments: The command-line arguments for the executable.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    ///   - environment: The extra environment pairs.
    ///   - signalCount: How many `SIGINT`s to send.
    ///   - gap: The pause between two signals. A caller that wants both
    ///     of them to reach a child which ends on the first one gives
    ///     `.zero`.
    ///   - firstOutputLimit: How long to wait for the first stdout byte.
    ///   - exitLimit: How long to wait for the exit after the last
    ///     signal.
    /// - Returns: The finished run.
    /// - Throws: ``SignalledRunError`` when a wait runs out, and the
    ///   locator or spawn error.
    static func run(
        executableNamed executableName: String,
        arguments: [String],
        workspace: URL,
        configHome: URL,
        environment: [String: String],
        signalCount: Int,
        gap: Swift.Duration,
        firstOutputLimit: Swift.Duration,
        exitLimit: Swift.Duration
    ) async throws -> SignalledExecutableRun {
        let process = Process()
        process.executableURL = try BuiltProductLocator.executableURL(named: executableName)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment[TierThreeFixture.configHomeVariable] = configHome.path
        for (key, value) in environment {
            childEnvironment[key] = value
        }
        process.environment = childEnvironment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let store = Store()
        try process.run()
        // Read both pipes as the child writes, so the first-output wait
        // has something to look at and a full pipe buffer never blocks
        // the child.
        let draining = Task.detached {
            async let output: Void = drain(standardOutputPipe) { await store.appendOutput($0) }
            async let error: Void = drain(standardErrorPipe) { await store.appendError($0) }
            _ = await (output, error)
        }

        try await waitForFirstOutput(of: store, within: firstOutputLimit, killing: process)
        var signalsSent = 0
        for index in 0..<signalCount {
            if index > 0 {
                try await Task.sleep(for: gap)
            }
            // A child that already ended has given its pid back, and the
            // system may have handed it to another process. So the run
            // signals only a child it still owns.
            guard process.isRunning else {
                break
            }
            process.interrupt()
            signalsSent += 1
        }
        try await waitForExit(of: process, within: exitLimit)

        await draining.value
        return SignalledExecutableRun(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: await store.output, as: UTF8.self),
            standardError: String(decoding: await store.error, as: UTF8.self),
            signalsSent: signalsSent)
    }

    /// Reads `pipe` until it reaches its end, handing each chunk over.
    ///
    /// - Parameters:
    ///   - pipe: The pipe to read.
    ///   - receive: What each chunk goes to.
    private static func drain(_ pipe: Pipe, receive: @Sendable (Data) async -> Void) async {
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                return
            }
            await receive(chunk)
        }
    }

    /// Waits until `store` holds a stdout byte.
    ///
    /// - Parameters:
    ///   - store: The captured output of the child.
    ///   - limit: How long to wait.
    ///   - process: The child to end when the wait runs out, so no test
    ///     leaves a process behind.
    /// - Throws: ``SignalledRunError`` when the wait runs out.
    private static func waitForFirstOutput(
        of store: Store, within limit: Swift.Duration, killing process: Process
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if await !store.output.isEmpty {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        process.terminate()
        throw SignalledRunError(wait: "write to stdout", limit: limit)
    }

    /// Waits until `process` has ended.
    ///
    /// - Parameters:
    ///   - process: The child to watch.
    ///   - limit: How long to wait.
    /// - Throws: ``SignalledRunError`` when the wait runs out.
    private static func waitForExit(
        of process: Process, within limit: Swift.Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if !process.isRunning {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        process.terminate()
        throw SignalledRunError(wait: "end", limit: limit)
    }
}
