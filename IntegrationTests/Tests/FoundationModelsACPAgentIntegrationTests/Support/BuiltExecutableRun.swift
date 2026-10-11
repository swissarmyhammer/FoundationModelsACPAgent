// `BuiltExecutableRun` — one finished run of a built executable.
//
// `ClientServerTests` runs `acp-print` through it and `CLIProcessTests`
// runs `acp-agent`, so the pipe draining and the exit wait stand in one
// place, and the two suites cannot drift apart. `runAgent` is the one
// driver of `acp-agent` in a fresh workspace, which `CLIProcessTests`,
// `ClientInteropTests`, `OutOfProcessTests` and
// `SkillsMarketplaceProcessTests` share.

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
        let child = try PipedChildProcess(
            executableNamed: executableName,
            arguments: arguments,
            workspace: workspace,
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            environment: PipedChildProcess.environment(configHome: configHome, adding: environment))
        let process = child.process
        let standardOutputPipe = child.standardOutput
        let standardErrorPipe = child.standardError

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

    /// Runs the built `acp-agent` with `arguments` in a fresh workspace.
    ///
    /// This is the one subprocess driver of the suites that run the agent CLI
    /// with no setup other than arguments and environment pairs. Each suite
    /// gives its own arguments and pairs, so the drivers cannot drift apart.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments for `acp-agent`.
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from. The workspace is `<label>-repo`, and the fresh config
    ///     home is `<label>-config`.
    ///   - configHome: The injected `XDG_CONFIG_HOME` root. The default makes
    ///     a fresh, empty directory.
    ///   - environment: The extra environment pairs. The default injects
    ///     none.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    static func runAgent(
        arguments: [String],
        label: String,
        configHome: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> BuiltExecutableRun {
        try await run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: arguments,
            workspace: makeResolvedDirectory(label: "\(label)-repo"),
            configHome: configHome ?? makeResolvedDirectory(label: "\(label)-config"),
            environment: environment)
    }
}
