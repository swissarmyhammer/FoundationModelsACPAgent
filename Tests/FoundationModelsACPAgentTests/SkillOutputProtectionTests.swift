import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The compaction rule that keeps each loaded skill (task ^2zb9s07): the
/// rule selects only a `use skill` call of the `skills` tool, and a session
/// that the agent vends keeps the body of that call through a compaction
/// that folds the other old tool outputs.
@Suite struct SkillOutputProtectionTests {
    /// The body the stub `skills` tool gives for every load. It is long
    /// enough that elision would change it, and unique enough to count.
    static let skillBody = "SKILL BODY: explore the code with tools.code_context before you change it."

    /// The text the stub `notes` tool gives, an ordinary tool output.
    static let notesText = "NOTES: an ordinary tool output that compaction may elide."

    /// The budget of the forced fold, in the tokens of the stub counter (one
    /// token per character).
    ///
    /// The target must leave room for a summary beside the protected skill
    /// bodies, or Router gives a shortfall and folds nothing; and it must be
    /// under the size of the six turns, or there is nothing to fold.
    /// Measured on 2026-09-23: a limit of 2,048 left -520 tokens for the
    /// summary and 4,096 left -315, both shortfalls; 8,192 folds.
    static let foldBudget = TokenBudget(limit: 8192, trigger: 0.1, target: 0.1)

    /// The arguments of the stub `skills` tool: the fused `op` and the id.
    @Generable
    struct SkillsArguments {
        /// The operation, such as `use skill`.
        var op: String

        /// The skill id.
        var id: String
    }

    /// A stub of the standalone `skills` tool that gives ``skillBody``.
    struct StubSkillsTool: Tool {
        let name = SkillOutputProtection.skillsToolName
        let description = "Load a skill."

        func call(arguments: SkillsArguments) async throws -> String {
            skillBody
        }
    }

    /// The arguments of the stub `notes` tool.
    @Generable
    struct NotesArguments {
        /// A topic, which the tool ignores.
        var topic: String
    }

    /// A stub tool whose output is not protected.
    struct StubNotesTool: Tool {
        let name = "notes"
        let description = "Give notes."

        func call(arguments: NotesArguments) async throws -> String {
            notesText
        }
    }

    /// Makes a tool call with the given tool name and arguments JSON.
    private static func call(_ toolName: String, _ argumentsJSON: String) throws -> Transcript.ToolCall {
        Transcript.ToolCall(
            id: UUID().uuidString, toolName: toolName, arguments: try GeneratedContent(json: argumentsJSON))
    }

    /// The text of a tool output: a text segment as it is, and a
    /// structured segment as the string it holds.
    private static func text(of output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): try? structure.content.value(String.self)
            @unknown default: nil
            }
        }.joined()
    }

    // MARK: The rule

    @Test(arguments: ["use skill", "Use Skill", "call skill", "invoke skill", "get skill", "use_skill"])
    func aSkillLoadIsProtected(operation: String) throws {
        let call = try Self.call("skills", #"{"op": "\#(operation)", "id": "explore"}"#)

        #expect(SkillOutputProtection.isSkillLoad(call))
    }

    @Test(arguments: [
        #"{"op": "search skill", "query": "explore"}"#,
        #"{"op": "list skill"}"#,
        #"{"op": "read resource", "id": "explore", "path": "a.md"}"#,
        #"{"id": "explore"}"#,
        #"{"op": "use skill extra", "id": "explore"}"#,
    ])
    func anotherSkillsCallIsNotProtected(argumentsJSON: String) throws {
        let call = try Self.call("skills", argumentsJSON)

        #expect(!SkillOutputProtection.isSkillLoad(call))
    }

    @Test func aCallOfAnotherToolIsNotProtected() throws {
        let call = try Self.call("runCode", #"{"op": "use skill", "id": "explore"}"#)

        #expect(!SkillOutputProtection.isSkillLoad(call))
    }

    // MARK: The session the agent vends

    /// Six turns each load a skill and read notes. The compaction removes or
    /// elides the old notes outputs, and it keeps every skill body word for
    /// word.
    /// The session comes from `makeBudgetedSession`, the one door that
    /// `session/new` and the model-slot switch use, so the test proves the
    /// wiring of the agent and not only the rule.
    @Test func aCompactionKeepsEveryLoadedSkillAndFoldsTheOtherOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillOutputProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = makeScriptedModelLoader(script: [
            .toolCall(name: "skills", argumentsJSON: #"{"op": "use skill", "id": "explore"}"#),
            .toolCall(name: "notes", argumentsJSON: #"{"topic": "admin"}"#),
            .textDelta("done"),
            .endTurn,
        ])
        let profile = try await makeStubProfile(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true), loader: loader)
        let session = profile.standard.makeBudgetedSession(
            instructions: "Follow the skill.",
            workingDirectory: directory,
            recordingRoot: directory.appendingPathComponent("recordings", isDirectory: true),
            tools: [StubSkillsTool(), StubNotesTool()],
            compaction: CompactionConfiguration())
        let turnCount = 6
        for turn in 0..<turnCount {
            _ = try await session.respond(to: "turn \(turn)")
        }

        let result = try await session.compact(budget: Self.foldBudget)
        // The fold must really fold: a shortfall leaves every output as it
        // was, and the assertions below would then prove nothing.
        #expect(result.shortfall == nil, "shortfall: \(String(describing: result.shortfall))")
        #expect(result.protectedTokens > 0)

        var skillOutputs: [String] = []
        var notesOutputs: [String] = []
        for entry in await session.transcript {
            guard case .toolOutput(let output) = entry else { continue }
            let text = Self.text(of: output)
            if output.toolName == SkillOutputProtection.skillsToolName {
                skillOutputs.append(text)
            } else {
                notesOutputs.append(text)
            }
        }
        #expect(skillOutputs.count == turnCount)
        #expect(skillOutputs.allSatisfy { $0 == Self.skillBody })
        // The fold removed or elided the old notes outputs: fewer than one
        // per turn keep their text. Only the protected skill bodies all stay.
        #expect(notesOutputs.filter { $0 == Self.notesText }.count < turnCount)
    }
}
