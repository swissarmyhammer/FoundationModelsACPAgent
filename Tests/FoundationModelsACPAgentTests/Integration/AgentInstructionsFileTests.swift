import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The project instruction files reach the model (the `AGENT.md` alias).
///
/// A session reads one instruction file in each directory from the git root
/// down to its working directory: `AGENTS.md`, else `AGENT.md`, else
/// `CLAUDE.md` (`AgentsMd` of FoundationModelsExtras). This suite proves the
/// whole path over the ACP wire: `session/new` in a repository that has the
/// files, one prompt, and then the leading `.instructions` entry of the
/// Router session transcript, which is the text the model gets.
@Suite struct AgentInstructionsFileTests {
    // MARK: - Constants

    /// The alias file name of the agents.md specification.
    private static let agentFileName = "AGENT.md"

    /// The file name that wins over the alias.
    private static let agentsFileName = InstructionsAssembler.agentsFileName

    /// The marker text of the `AGENT.md` at the repository root.
    private static let rootAgentText = "ROOT-AGENT-MD-RULES"

    /// The marker text of the `AGENT.md` in the subfolder.
    private static let subfolderAgentText = "SUBFOLDER-AGENT-MD-RULES"

    /// The marker text of the `AGENTS.md` that wins over an `AGENT.md`.
    private static let agentsText = "AGENTS-MD-WINS"

    /// The marker text of an `AGENT.md` that an `AGENTS.md` hides.
    private static let hiddenAgentText = "HIDDEN-AGENT-MD"

    /// The name of the subfolder that the session opens in.
    private static let subfolderName = "package"

    /// The text of the prompt.
    private static let promptText = "Read the project rules"

    /// The reply of the scripted model.
    private static let reply = "done"

    // MARK: - Helpers

    /// Makes a repository root: a directory with a `.git` directory, so the
    /// instruction walk stops at it.
    ///
    /// - Parameter label: The directory label of the test.
    /// - Returns: The repository root.
    /// - Throws: Whatever the directory creation throws.
    private static func makeRepository(label: String) throws -> URL {
        let root = makeResolvedDirectory(label: label)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    /// Writes `text` to `name` in `directory`.
    ///
    /// - Parameters:
    ///   - text: The file text.
    ///   - name: The file name.
    ///   - directory: The directory.
    /// - Throws: Whatever the write throws.
    private static func write(_ text: String, to name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Opens one session in `workingDirectory`, sends one prompt, waits for
    /// its `idle`, and gives the text of the leading `.instructions` entry of
    /// the Router session transcript.
    ///
    /// - Parameters:
    ///   - workingDirectory: The working directory of the session.
    ///   - label: The directory label of the test.
    /// - Returns: The instructions text that the model got.
    /// - Throws: Whatever the wire or the waits throw, or when the
    ///   transcript has no leading `.instructions` entry.
    private static func instructionsText(in workingDirectory: URL, label: String) async throws -> String {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta(reply), .endPass], label: label, workingDirectory: workingDirectory)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let transcript = await session.transcript
        await fixture.close()
        guard case .instructions(let instructions)? = Array(transcript).first else {
            Issue.record("expected a leading .instructions entry")
            return ""
        }
        return instructions.segments.compactMap { segment in
            if case .text(let text) = segment {
                return text.content
            }
            return nil
        }.joined()
    }

    // MARK: - The tests

    /// An `AGENT.md` at the repository root, with no `AGENTS.md`, reaches
    /// the model with a header that names its absolute path.
    @Test func anAgentMdAtTheRootReachesTheModel() async throws {
        let root = try Self.makeRepository(label: "AgentInstructionsFileTests-root")
        try Self.write(Self.rootAgentText, to: Self.agentFileName, in: root)

        let text = try await Self.instructionsText(in: root, label: "AgentInstructionsFileTests-root")

        #expect(text.contains(Self.rootAgentText))
        #expect(text.contains(root.appendingPathComponent(Self.agentFileName).path))
    }

    /// An `AGENT.md` at the root and one in the subfolder of the session
    /// both reach the model, the root first, so the nearest file has the
    /// last word.
    @Test func theAgentMdFilesFromTheRootDownReachTheModelInOrder() async throws {
        let root = try Self.makeRepository(label: "AgentInstructionsFileTests-nested")
        let subfolder = root.appendingPathComponent(Self.subfolderName, isDirectory: true)
        try Self.write(Self.rootAgentText, to: Self.agentFileName, in: root)
        try Self.write(Self.subfolderAgentText, to: Self.agentFileName, in: subfolder)

        let text = try await Self.instructionsText(in: subfolder, label: "AgentInstructionsFileTests-nested")

        let rootRange = try #require(text.range(of: Self.rootAgentText))
        let subfolderRange = try #require(text.range(of: Self.subfolderAgentText))
        #expect(rootRange.lowerBound < subfolderRange.lowerBound)
    }

    /// In one directory, `AGENTS.md` wins: the `AGENT.md` beside it does not
    /// reach the model.
    @Test func anAgentsMdHidesTheAgentMdBesideIt() async throws {
        let root = try Self.makeRepository(label: "AgentInstructionsFileTests-precedence")
        try Self.write(Self.agentsText, to: Self.agentsFileName, in: root)
        try Self.write(Self.hiddenAgentText, to: Self.agentFileName, in: root)

        let text = try await Self.instructionsText(in: root, label: "AgentInstructionsFileTests-precedence")

        #expect(text.contains(Self.agentsText))
        #expect(!text.contains(Self.hiddenAgentText))
    }
}
