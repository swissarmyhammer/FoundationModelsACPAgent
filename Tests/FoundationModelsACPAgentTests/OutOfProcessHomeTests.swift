import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// `run --out-of-process --home <dir>` (task ^98a44n7): the child that
/// answers the prompt gets the environment of the run, so it reads the same
/// home as `ACP_AGENT_HOME`. The child here is a script that writes the
/// variable to a file and exits, so the handshake fails and no agent starts.
struct OutOfProcessHomeTests {
    // MARK: - Constants

    /// The prompt of the run. The script never reads it.
    private static let promptText = "hello"

    /// The name of the file the script writes the variable into.
    private static let recordFileName = "home.txt"

    /// The name of the home folder that the run names.
    private static let homeFolderName = "home"

    /// The name of the script.
    private static let scriptFileName = "record-home.sh"

    /// The permissions of the script: the owner reads, writes and runs it.
    private static let scriptPermissions = NSNumber(value: 0o700)

    // MARK: - Tests

    /// The child reads `ACP_AGENT_HOME` from the environment that the run
    /// gives, and not only from the environment of this process.
    @Test func theChildGetsTheHomeOfTheRun() async throws {
        let folder = makeResolvedDirectory(label: "OutOfProcessHomeTests")
        let record = folder.appendingPathComponent(Self.recordFileName)
        let script = try Self.writeScript(recordingInto: record, in: folder)
        let home = folder.appendingPathComponent(Self.homeFolderName, isDirectory: true).path
        let environment = ProcessInfo.processInfo.environment
            .merging([AgentComposition.homeVariable: home]) { _, new in new }
        let capture = try AnswerCapture(label: "OutOfProcessHomeTests-answer")

        _ = try? await OutOfProcessPrompt.answer(
            command: script.path, environment: environment,
            in: .new(workingDirectory: folder), prompt: Self.promptText, into: capture.writer)

        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.trimmingCharacters(in: .whitespacesAndNewlines) == home)
    }

    // MARK: - Helpers

    /// Writes a script that writes `ACP_AGENT_HOME` into `record` and exits.
    ///
    /// - Parameters:
    ///   - record: The file the script writes.
    ///   - folder: The folder of the script.
    /// - Returns: The script.
    /// - Throws: The write error, or the permission error.
    private static func writeScript(recordingInto record: URL, in folder: URL) throws -> URL {
        let script = folder.appendingPathComponent(scriptFileName)
        let text = "#!/bin/sh\nprintf '%s' \"$\(AgentComposition.homeVariable)\" > '\(record.path)'\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: scriptPermissions], ofItemAtPath: script.path)
        return script
    }
}
