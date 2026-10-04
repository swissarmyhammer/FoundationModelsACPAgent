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

    /// The gate that holds the answer of each server in ``silentServers``.
    /// The test opens it after the doctor returned.
    let lateAnswers = LateAnswerGate()

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
    /// - Returns: The scripted answer, or, when the entry's name is in
    ///   ``silentServers``, an answer that comes only after the test opens
    ///   ``lateAnswers``. A doctor whose timeout works reports
    ///   ``ProbeOutcome/timedOut`` before that, and drops the late answer.
    func startMCPServer(_ entry: MCPServerConfiguration) async -> ProbeOutcome {
        if silentServers.contains(entry.name) {
            await lateAnswers.wait()
            return .answered
        }
        return namedServers[entry.name] ?? server
    }
}
