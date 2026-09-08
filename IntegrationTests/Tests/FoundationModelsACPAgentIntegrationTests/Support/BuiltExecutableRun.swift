// `BuiltExecutableRun` — one finished run of a built executable.
//
// `ClientServerTests` runs `acp-print` through it and `CLIProcessTests`
// runs `acp-agent`, so the pipe draining and the exit wait stand in one
// place, and the two suites cannot drift apart.

import Foundation
import FoundationModelsACPAgentTestSupport

/// One finished run of a built executable: its exit code and its captured
/// stdout and stderr text.
struct BuiltExecutableRun {
    /// The process exit code.
    let exitCode: Int32

    /// The captured stdout text.
    let standardOutput: String

    /// The captured stderr text.
    let standardError: String

    /// Runs the built executable `executableName` with `arguments` and
    /// captures its exit code, stdout, and stderr.
    ///
    /// The run gets `configHome` as `XDG_CONFIG_HOME` and every pair of
    /// `environment` on top of this process's environment. A child the
    /// executable spawns inherits that environment, so the injected
    /// configuration and the injected pairs reach it too.
    ///
    /// - Parameters:
    ///   - executableName: The product name of the executable to run.
    ///   - arguments: The command-line arguments for the executable.
    ///   - workspace: The working directory of the run.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    ///   - environment: The extra environment pairs. The default injects
    ///     none, so a caller that says nothing about the environment gets
    ///     this process's own beside `configHome`.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    static func run(
        executableNamed executableName: String,
        arguments: [String],
        workspace: URL,
        configHome: URL,
        environment: [String: String] = [:]
    ) async throws -> BuiltExecutableRun {
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

        try process.run()
        // Drain the two pipes on their own tasks. A full pipe buffer
        // would block the child, so the reads run before the wait.
        let standardOutputData = Task.detached {
            try standardOutputPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let standardErrorData = Task.detached {
            try standardErrorPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            if !process.isRunning {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
        return BuiltExecutableRun(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try await standardOutputData.value, as: UTF8.self),
            standardError: String(decoding: try await standardErrorData.value, as: UTF8.self))
    }
}
