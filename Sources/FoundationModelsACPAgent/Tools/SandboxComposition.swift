import Foundation
import FoundationModelsMultitool

/// A refusal to compose the shell sandbox.
///
/// Each case means the same thing to a caller: the shell capability must
/// not mount. There is no fallback to a shell with less confinement.
public enum SandboxCompositionError: Error, Equatable, CustomStringConvertible {
    /// The session root set computed to empty, so there is no directory
    /// to grant writes under.
    ///
    /// This is this package's own error, thrown before
    /// `SeatbeltSandbox.Options` is constructed. The upstream initializer
    /// replaces an empty `writableRoots` with the process working
    /// directory — the widest grant the type can give — so an empty root
    /// set must fail loudly here and never pass through.
    case emptyRootSet

    /// A human-readable description of this error.
    public var description: String {
        switch self {
        case .emptyRootSet:
            return "the session root set is empty; the shell sandbox has no directory to grant"
        }
    }
}

/// The sandbox composition: the one place this package
/// builds the `SeatbeltSandbox` the shell capability runs under, from the
/// session root set and the decoded `sandbox:` config section.
///
/// **The sandbox is the only gate.** There is no permission layer: this
/// agent does not advertise a permission capability and never sends
/// `session/request_permission`. A denylist over
/// command text can be avoided by respelling the command; the seatbelt
/// sandbox is a kernel boundary and does not care how a command is
/// spelled.
///
/// **The preflight is the proof.** `SeatbeltSandbox.preflight` is `async
/// throws` and runs a canary before any command starts. The shell
/// capability surfaces a failed preflight as a tool-call failure with the
/// reason, and there is no path from a failed preflight to an unconfined
/// spawn — this composition never mounts the shell without a sandbox.
///
/// **Stated limit:** ``statedLimit`` — the sandbox bounds
/// writing and deleting only. Reads are free and the network is open, so
/// exfiltration is not bounded. The README states the same limit, and a
/// test keeps the two in step.
public enum SandboxComposition {
    /// The limit of the sandbox, in one sentence. The README carries this
    /// text verbatim, and a test asserts it cannot drift.
    public static let statedLimit =
        "The sandbox bounds writing and deleting only. Reads are free and the network is "
        + "open, so exfiltration is not bounded."

    /// Builds the `SeatbeltSandbox` over the session root set and the
    /// decoded `sandbox:` section.
    ///
    /// The options build through
    /// `SandboxConfiguration.sandboxOptions(workingDirectory:additionalRoots:)`,
    /// which goes only through
    /// `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)`, so every
    /// path is `realpath(3)`-resolved. Never pass the output of
    /// `URL.resolvingSymlinksInPath()`: on macOS it strips `/private`,
    /// and Seatbelt cannot match that path form.
    ///
    /// - Parameters:
    ///   - rootSet: The session root set, in order: the working directory
    ///     first, then the additional roots.
    ///   - configuration: The decoded `sandbox:` section, whose
    ///     `extraWritePaths` ride along.
    /// - Returns: The sandbox the shell capability runs under.
    /// - Throws: ``SandboxCompositionError/emptyRootSet`` when `rootSet`
    ///   is empty — before any `Options` value exists.
    public static func makeShellSandbox(
        rootSet: [URL], configuration: SandboxConfiguration
    ) throws -> SeatbeltSandbox {
        guard let workingDirectory = rootSet.first else {
            throw SandboxCompositionError.emptyRootSet
        }
        return SeatbeltSandbox(
            options: configuration.sandboxOptions(
                workingDirectory: workingDirectory,
                additionalRoots: Array(rootSet.dropFirst())))
    }

    /// Composes the shell capability into `builder`, confined by the
    /// `SeatbeltSandbox` over `rootSet` and `configuration`.
    ///
    /// The first root — the session working directory — also becomes
    /// the default working directory: a `tools.shell.execute` call
    /// that omits `workingDirectory` runs there, never in the agent
    /// process directory, which stands outside the root set and would
    /// make the sandbox refuse the run.
    ///
    /// - Parameters:
    ///   - builder: The registry builder the capability mounts into.
    ///   - store: The shell store the capability keeps the history and the
    ///     captured output of the commands in, which the other sessions of
    ///     its store directory share.
    ///   - sessionID: The ACP session id of the session, read when each
    ///     command starts, which each command records as its owner.
    ///   - configuration: The decoded `sandbox:` section.
    ///   - rootSet: The session root set, working directory first.
    ///   - outputChunkStream: The host-owned live output stream the
    ///     capability tees raw bytes into, or `nil` to
    ///     tee nothing.
    /// - Throws: ``SandboxCompositionError/emptyRootSet`` for an empty
    ///   root set.
    static func composeShell(
        into builder: MultiTool.Builder,
        store: ShellStore,
        sessionID: @escaping @Sendable () -> String?,
        configuration: SandboxConfiguration,
        rootSet: [URL],
        outputChunkStream: ShellOutputChunkStream? = nil
    ) throws {
        composeShell(
            into: builder,
            store: store,
            sessionID: sessionID,
            sandbox: try makeShellSandbox(rootSet: rootSet, configuration: configuration),
            outputChunkStream: outputChunkStream,
            defaultWorkingDirectory: rootSet.first)
    }

    /// The one seam every shell mount goes through: `sandbox` is handed to
    /// `MultiTool.Builder.withShell(sandbox:)`, so no shell mounts without
    /// a sandbox and a test can inject a sandbox whose preflight throws.
    ///
    /// - Parameters:
    ///   - builder: The registry builder the capability mounts into.
    ///   - store: The shell store the capability keeps the history and the
    ///     captured output of the commands in.
    ///   - sessionID: The session id each command records as its owner,
    ///     read when the command starts. The default records none.
    ///   - sandbox: The confinement every command spawns under.
    ///   - outputChunkStream: The host-owned live output stream the
    ///     capability tees raw bytes into, or `nil` to
    ///     tee nothing.
    ///   - defaultWorkingDirectory: The directory a run that omits
    ///     `workingDirectory` runs in — the session working directory —
    ///     or `nil` to keep the capability's own process-directory
    ///     default.
    static func composeShell(
        into builder: MultiTool.Builder,
        store: ShellStore,
        sessionID: @escaping @Sendable () -> String? = { nil },
        sandbox: any CommandSandbox,
        outputChunkStream: ShellOutputChunkStream? = nil,
        defaultWorkingDirectory: URL? = nil
    ) {
        builder.withShell(
            store: store,
            sessionID: sessionID,
            sandbox: sandbox,
            outputChunkStream: outputChunkStream,
            defaultWorkingDirectory: defaultWorkingDirectory)
    }
}
