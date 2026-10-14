import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - The telemetry bootstrap keeps stdout for ACP only
//
// `acp-agent` bootstraps a stderr log handler as the first step of `main()`
// (the approved OpenTelemetry design, items 1 and 6). In `acp` mode stdout
// carries the ACP frames, so no log record can go there. This suite spawns
// the built binary and holds its stdout to the ACP stdio framing rule (ndJSON
// only, no other byte), and holds the bootstrap to a clean exit: a second
// bootstrap of swift-log stops the process.
//
// Only a spawned process can prove this. The unit target links the
// `acp-agent` target, and no test in that process may bootstrap logging.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The stdout contract of the telemetry bootstrap of `acp-agent acp`.
///
/// Serialized so at most one spawned agent runs at a time.
@Suite(.serialized)
struct TelemetryStdoutTests {
    // MARK: - Constants

    /// The prompt of the one prompt. The stub model echoes it.
    private static let promptText = "keep stdout for the frames"

    /// The exit code of a normal end.
    private static let successExitCode: Int32 = 0

    // MARK: - The drive

    /// Spawns the built `acp-agent acp` over the stub model. Then it runs
    /// `initialize`, `session/new` and one prompt, closes stdin, and waits for
    /// the exit.
    ///
    /// - Parameter label: The directory label, so a leftover directory tells
    ///   where it came from.
    /// - Returns: The drive.
    /// - Throws: The spawn, request or wait error.
    private static func driveOnePrompt(label: String) async throws -> SpawnedAgentPromptDrive {
        try await SpawnedAgentPromptDrive.run(
            label: label, environment: [:], promptText: promptText
        ) { agent in
            try await agent.closeStandardInputAndWait()
        }
    }

    /// Checks the contract of one drive: a good `initialize`, a prompt that
    /// ends, only JSON-RPC frames on stdout, and a clean exit.
    ///
    /// - Parameter drive: The drive to check.
    /// - Throws: The frame check error.
    private static func assertCleanDrive(_ drive: SpawnedAgentPromptDrive) throws {
        #expect(drive.initialized.info.name == RoutedACPAgent.implementation.name)
        #expect(drive.initialized.protocolVersion == RoutedACPAgent.latestProtocolVersion)
        #expect(drive.stopReason != nil, "the prompt never reached an idle state update")
        #expect(drive.exit.didExit, "a signal ended the agent; stderr: \(drive.exit.standardError)")
        #expect(
            drive.exit.status == successExitCode, "stderr: \(drive.exit.standardError)")
        try StdoutFrameChecks.assertFramesArePureJSONRPC(in: drive.standardOutput)
    }

    // MARK: - The contract

    /// The agent bootstraps a stderr log handler, and stdout carries only
    /// JSON-RPC frames through `initialize`, `session/new` and one prompt.
    @Test func stdoutCarriesOnlyFrames() async throws {
        let drive = try await Self.driveOnePrompt(label: "TelemetryStdout")

        try Self.assertCleanDrive(drive)
    }
}
