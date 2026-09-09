import Darwin
import Foundation
import FoundationModelsMultitool

/// What one probe of the tools component gave (cli-plan.md §5.12, the
/// Sandbox and Tools rows).
///
/// A probe never throws. `doctor` runs every check, so one refusal must
/// travel as a value that the component turns into a finding, and never as
/// an error that stops the run.
public enum ProbeOutcome: Equatable, Sendable {
    /// The probe answered, and what it probed works.
    case answered

    /// The probe answered, and what it probed does not work. The reason is
    /// the text a person reads.
    case failed(reason: String)

    /// The probe did not answer inside the timeout.
    case timedOut
}

/// How ``ToolsDoctor`` reaches the world (cli-plan.md §5.12).
///
/// The component takes a prober, so a unit test starts no confined command
/// and no MCP server: it scripts the answers and the findings come out the
/// same on any machine. ``SystemToolsProber`` is the one that does the
/// real work.
public protocol ToolsProber: Sendable {
    /// Runs one trivial confined command under `options`.
    ///
    /// - Parameter options: The write confinement to prove.
    /// - Returns: What the probe gave.
    func startSandbox(options: SeatbeltSandbox.Options) async -> ProbeOutcome

    /// Starts one configured MCP server, and stops it again.
    ///
    /// - Parameter entry: The server entry to reach. A stdio entry states a
    ///   command to start; an http entry states a URL to ask.
    /// - Returns: What the probe gave.
    func startMCPServer(_ entry: MCPServerConfiguration) async -> ProbeOutcome
}

/// The ``ToolsProber`` that does the real work: it starts the seatbelt
/// canary, and it connects each configured MCP server the same way
/// `session/new` does.
///
/// Only the `doctor` command builds this. Every unit test injects a stub,
/// because this type spawns processes and opens connections.
public struct SystemToolsProber: ToolsProber {
    /// Makes the prober. It holds no state.
    public init() {}

    /// Runs the seatbelt canary of `options`.
    ///
    /// `SeatbeltSandbox.preflight(workingDirectory:temporaryDirectory:)` is
    /// the trivial confined command: it starts the real wrapper, with the
    /// real profile, against `/usr/bin/true`. The working directory is
    /// `options.writableRoots.first`, which the options initializer already
    /// put through `realpath(3)` — the resolved-path precondition of
    /// `CommandSandbox` (plan.md §2.5).
    ///
    /// - Parameter options: The write confinement to prove.
    /// - Returns: What the canary gave.
    public func startSandbox(options: SeatbeltSandbox.Options) async -> ProbeOutcome {
        guard let workingDirectory = options.writableRoots.first else {
            return .failed(reason: SandboxCompositionError.emptyRootSet.description)
        }
        do {
            try await SeatbeltSandbox(options: options).preflight(
                workingDirectory: workingDirectory,
                temporaryDirectory: Self.resolvedTemporaryDirectory())
            return .answered
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// Connects `entry` and disconnects it again.
    ///
    /// The connect is ``MCPComposition/connectServers(section:clientServers:)``
    /// over a roster of this one entry, so the probe proves exactly what
    /// `session/new` does: a stdio entry spawns its command and reaches
    /// `.ready`, and an http entry answers at its URL.
    ///
    /// - Parameter entry: The server entry to reach.
    /// - Returns: What the connect gave.
    public func startMCPServer(_ entry: MCPServerConfiguration) async -> ProbeOutcome {
        do {
            let connected = try await MCPComposition.connectServers(
                section: .enabled(servers: [entry]), clientServers: [])
            await MCPComposition.shutDown(
                servers: connected.servers, processes: connected.processes)
            return .answered
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// The temporary directory of this process, as `realpath(3)` resolves
    /// it.
    ///
    /// The seatbelt profile matches the path the kernel resolved, and
    /// `URL.resolvingSymlinksInPath()` gives the other form on macOS, so
    /// the resolution goes through `realpath(3)` itself (plan.md §2.5).
    ///
    /// - Returns: The resolved path, or the unresolved one when the
    ///   directory cannot be resolved.
    private static func resolvedTemporaryDirectory() -> String {
        let path = NSTemporaryDirectory()
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The deadline every prober call runs under (cli-plan.md §5.12).
///
/// A probe reaches a subprocess or a network endpoint, and either one can
/// stop answering. `doctor` must still finish and still print its table, so
/// each call races the probe against a timer and reports
/// ``ProbeOutcome/timedOut`` when the timer wins.
///
/// **The probe runs in an unstructured task on purpose.** A structured
/// child would have to be awaited at the end of its scope, so a probe that
/// ignores cancellation would hold the whole run. The unstructured task is
/// cancelled and then left behind, which is what keeps the run from
/// hanging.
enum ProbeTimeout {
    /// Runs `probe` under a deadline.
    ///
    /// - Parameters:
    ///   - seconds: How long the probe may take.
    ///   - probe: The call to run.
    /// - Returns: What the probe gave, or ``ProbeOutcome/timedOut``.
    static func run(
        seconds: Double, probe: @escaping @Sendable () async -> ProbeOutcome
    ) async -> ProbeOutcome {
        let answer = FirstAnswer()
        let probeTask = Task { await answer.settle(probe()) }
        let timerTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await answer.settle(.timedOut)
        }
        let outcome = await answer.value()
        probeTask.cancel()
        timerTask.cancel()
        return outcome
    }
}

/// The first of two answers, and the one waiter that reads it.
///
/// The probe and the timer both settle this box. The first one wins and
/// every later one is dropped, so the waiter is resumed exactly one time.
private actor FirstAnswer {
    /// The answer that won, once one has.
    private var outcome: ProbeOutcome?

    /// The waiter that ``value()`` suspended, when it suspended.
    private var waiter: CheckedContinuation<ProbeOutcome, Never>?

    /// Records `answer` when nothing is recorded yet, and resumes the
    /// waiter.
    ///
    /// - Parameter answer: The answer to record.
    func settle(_ answer: ProbeOutcome) {
        guard outcome == nil else {
            return
        }
        outcome = answer
        waiter?.resume(returning: answer)
        waiter = nil
    }

    /// The answer that won, waiting for it when there is none yet.
    ///
    /// - Returns: The first answer.
    func value() async -> ProbeOutcome {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}
