import Foundation
import FoundationModelsMultitool

@testable import FoundationModelsACPAgent

/// A ``ToolsProber`` that answers from a script (cli-plan.md §5.12).
///
/// No test starts a confined command and no test starts an MCP server, so
/// the doctor suite stays hermetic and fast. Each stored property is one
/// scripted answer.
struct StubToolsProber: ToolsProber {
    /// What the sandbox probe answers.
    var sandbox = ProbeOutcome.answered

    /// What one named MCP server answers. A server this table does not name
    /// gets ``server``.
    var namedServers: [String: ProbeOutcome] = [:]

    /// What an MCP server the table does not name answers.
    var server = ProbeOutcome.answered

    /// The names of the servers whose probe does not answer before the
    /// doctor's timeout, which is what makes that timeout fire.
    var silentServers: Set<String> = []

    /// Answers the sandbox probe from ``sandbox``.
    ///
    /// - Parameter options: The write confinement, which this stub reads
    ///   not at all.
    /// - Returns: The scripted answer.
    func startSandbox(options: SeatbeltSandbox.Options) async -> ProbeOutcome {
        sandbox
    }

    /// Answers one MCP server probe from ``namedServers``, ``server`` and
    /// ``silentServers``.
    ///
    /// - Parameter entry: The server entry to probe.
    /// - Returns: The scripted answer, or an answer that comes far too
    ///   late, when the entry's name is in ``silentServers``.
    func startMCPServer(_ entry: MCPServerConfiguration) async -> ProbeOutcome {
        if silentServers.contains(entry.name) {
            return await Self.answerTooLate()
        }
        return namedServers[entry.name] ?? server
    }

    /// Waits ``lateAnswerSeconds``, which is far past any timeout a test
    /// injects, and then answers.
    ///
    /// So a doctor whose timeout works reports ``ProbeOutcome/timedOut``
    /// long before this returns, and a doctor whose timeout does not work
    /// waits the whole time and fails the elapsed-time assertion.
    ///
    /// The wait ends early when the doctor cancels the probe. The answer
    /// that then comes back arrives after the timeout has already settled,
    /// so it is dropped — and no task is left suspended for ever.
    ///
    /// - Returns: The late answer.
    private static func answerTooLate() async -> ProbeOutcome {
        try? await Task.sleep(for: .seconds(lateAnswerSeconds))
        return .answered
    }

    /// How long a probe of a silent server waits, in seconds.
    private static let lateAnswerSeconds = 60.0
}
