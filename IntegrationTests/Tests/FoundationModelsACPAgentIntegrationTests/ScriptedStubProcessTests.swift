import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

// MARK: - Tier 3: the scripted stub model across a process boundary
//
// `ACP_AGENT_STUB_SCRIPT` names a JSON file, and the stub model of a spawned
// `acp-agent` plays it. The root session calls the `agents` tool, the child
// session answers, and the root session ends with its own text. Only a
// spawned binary proves that the variable reaches the stub path of the real
// process.

/// The scripted stub model of a spawned `acp-agent run`.
struct ScriptedStubProcessTests {
    // MARK: - Constants

    /// The environment variable that names the script file.
    private static let scriptVariable = "ACP_AGENT_STUB_SCRIPT"

    /// The id of the agent that the root session starts.
    private static let childAgent = "helper"

    /// The prompt of the client, and the marker of the root session.
    private static let rootPrompt = "ROOT-SESSION-MARKER"

    /// The prompt that the root session gives the child run.
    private static let childPrompt = "CHILD-SESSION-MARKER"

    /// The text that the root session ends with.
    private static let rootFinalText = "ROOT-FINAL-TEXT"

    /// The text that the child session ends with.
    private static let childFinalText = "CHILD-FINAL-TEXT"

    /// The exit code of a run that reached the end of its prompt.
    private static let endTurnExitCode: Int32 = 0

    /// The exit code of an error (cli-plan.md §5.8).
    private static let errorExitCode: Int32 = 1

    // MARK: - Fixtures

    /// The script: the root calls the `agents` tool to start the child, and
    /// the child answers.
    private static var script: String {
        """
        {"sessions":[
          {"match":{"promptContains":"\(childPrompt)"},
           "passes":[[{"text":"\(childFinalText)"}]]},
          {"match":{"promptContains":"\(rootPrompt)"},
           "passes":[[
             {"toolCall":{"name":"agents","arguments":
               {"op":"start agent","name":"\(childAgent)","prompt":"\(childPrompt)"}}},
             {"text":"\(rootFinalText)"}]]}
        ]}
        """
    }

    /// Writes the agent folder of the child in the project folder.
    private static func writeChildAgent(in workspace: URL) throws {
        let folder = workspace.appendingPathComponent(".agents/agents/\(childAgent)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = "---\nname: \(childAgent)\ndescription: The helper test agent.\n---\n\nDo the task.\n"
        try document.write(
            to: folder.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
    }

    /// Writes `text` as the script file of a run.
    private static func writeScript(_ text: String, label: String) throws -> URL {
        let file = makeResolvedDirectory(label: "\(label)-script").appendingPathComponent("script.json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Runs `acp-agent run --verbose <prompt>` over the script.
    private static func run(script text: String, label: String) async throws -> BuiltExecutableRun {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        try writeChildAgent(in: workspace)
        let file = try writeScript(text, label: label)
        return try await BuiltExecutableRun.run(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: ["run", "--verbose", rootPrompt],
            workspace: workspace,
            configHome: makeResolvedDirectory(label: "\(label)-config"),
            environment: try TierThreeFixture.makeOfflineDefaultsEnvironment()
                .merging([scriptVariable: file.path]) { _, script in script })
    }

    // MARK: - The contract

    /// The root session calls the `agents` tool, the child session answers,
    /// and the root session ends with its own text.
    @Test
    func theRootCallsTheAgentsToolAndEndsWithItsOwnText() async throws {
        let run = try await Self.run(script: Self.script, label: "ScriptedStubProcessTests-nested")

        #expect(run.exitCode == Self.endTurnExitCode, "stderr: \(run.standardError)")
        #expect(run.standardOutput.contains(Self.rootFinalText), "stdout: \(run.standardOutput)")
        #expect(
            run.standardError.split(separator: "\n").contains { $0.hasPrefix("tool ") && $0.contains("agents") },
            "no line of the agents tool call in: \(run.standardError)")
    }

    /// A script that is not JSON stops the run with an error that names the
    /// script file, and the run does not echo.
    @Test
    func aScriptThatIsNotJSONStopsTheRunWithAnError() async throws {
        let run = try await Self.run(script: "not json", label: "ScriptedStubProcessTests-bad")

        #expect(run.exitCode == Self.errorExitCode, "stderr: \(run.standardError)")
        #expect(run.standardError.contains("script"), "stderr: \(run.standardError)")
        #expect(!run.standardOutput.contains(Self.rootPrompt), "stdout: \(run.standardOutput)")
    }
}
