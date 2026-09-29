// `PipedChildProcess` — the one setup of a built executable that a test
// spawns: the `Process`, its environment, and its pipes.
//
// `BuiltExecutableRun`, `SignalledExecutableRun` and `SpawnedACPAgent` each
// spawn a built executable. They read the output in different ways, but the
// setup before the start is the same. This type holds that setup, so the
// close-on-exec marks and the environment rules stand in one place.

import Foundation
import FoundationModelsACPAgentTestSupport

/// A built executable with its environment and its pipes, set up and not yet
/// started.
struct PipedChildProcess {
    /// The child process. The caller starts it.
    let process: Process

    /// The stdout pipe of the child.
    let standardOutput: Pipe

    /// The stderr pipe of the child.
    let standardError: Pipe

    /// Sets up the built executable `executableName` and its pipes.
    ///
    /// The child starts from `inheritedEnvironment`, and each pair of
    /// `environment` replaces the value of its key. Each pipe gets
    /// `FD_CLOEXEC` (see `Pipe.markCloseOnExec()`), so no other child of this
    /// process holds a copy of it.
    ///
    /// - Parameters:
    ///   - executableName: The product name of the executable to run.
    ///   - arguments: The command-line arguments for the executable.
    ///   - workspace: The working directory of the child.
    ///   - inheritedEnvironment: The environment the child starts from.
    ///   - environment: The pairs to set on top of `inheritedEnvironment`.
    ///   - standardInput: The stdin pipe of the child. The default is `nil`,
    ///     and the child then reads the stdin of this process.
    /// - Throws: The locator error.
    init(
        executableNamed executableName: String,
        arguments: [String],
        workspace: URL,
        inheritedEnvironment: [String: String],
        environment: [String: String],
        standardInput: Pipe? = nil
    ) throws {
        let process = Process()
        process.executableURL = try BuiltProductLocator.executableURL(named: executableName)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        process.environment = inheritedEnvironment.merging(environment) { _, set in set }

        let standardOutput = Pipe()
        let standardError = Pipe()
        for pipe in [standardInput, standardOutput, standardError].compactMap({ $0 }) {
            pipe.markCloseOnExec()
        }
        if let standardInput {
            process.standardInput = standardInput
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// The environment pairs of a child that reads its configuration from
    /// `configHome`.
    ///
    /// - Parameters:
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    ///   - pairs: The extra pairs. A pair with the key of `XDG_CONFIG_HOME`
    ///     replaces `configHome`.
    /// - Returns: `configHome` as `XDG_CONFIG_HOME`, with `pairs` on top.
    static func environment(configHome: URL, adding pairs: [String: String]) -> [String: String] {
        [TierThreeFixture.configHomeVariable: configHome.path].merging(pairs) { _, pair in pair }
    }
}
