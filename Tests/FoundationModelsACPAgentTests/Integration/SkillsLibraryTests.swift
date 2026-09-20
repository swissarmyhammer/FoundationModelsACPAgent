import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The skills path of this agent, over the skills library of this repository
/// (task ^fkkdfw7).
///
/// **Why this suite exists.** Three SWE-bench runs asked one question: does a
/// skill reach the model? Each answer took hours, a marketplace fetch over the
/// network, and a reading of the transcripts by hand. This suite answers the
/// mechanical half in seconds, with no network and no marketplace: the tool
/// carries the catalog, a `use skill` call gives the text of the skill file,
/// and a hidden skill reaches no surface.
///
/// The library is `Tests/Fixtures/skills/` of this repository, found through
/// ``PackageRoot``. Each test copies it into the project layer of a session,
/// `<cwd>/.skills/`, which is the layer a real project uses. Nothing here
/// measures whether a model CHOOSES to load a skill; that question needs a
/// live model.
@Suite struct SkillsLibraryTests {
    // MARK: - The library

    /// The id of the visible fixture skill whose body names the code context
    /// verbs.
    static let exploreID = "fixture-explore"

    /// The id of the second visible fixture skill.
    static let releaseNotesID = "fixture-release-notes"

    /// The id of the fixture skill that carries
    /// `disable-model-invocation: true`.
    static let hiddenID = "fixture-hidden"

    /// A line of the `fixture-explore` body, which a loaded skill must carry.
    static let exploreMarker = "FIXTURE-EXPLORE-BODY"

    /// The dotfolder the skills stack roots at, under the session working
    /// directory.
    static let skillsDotfolder = ".skills"

    /// The library directory of this repository.
    static func libraryDirectory() throws -> URL {
        try PackageRoot.directory()
            .appendingPathComponent("Tests/Fixtures/skills", isDirectory: true)
    }

    /// Makes a session working directory that holds the library in its
    /// project layer.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The working directory.
    /// - Throws: Whatever the copy throws.
    static func makeWorkspace(label: String) throws -> URL {
        let cwd = makeResolvedDirectory(label: "SkillsLibraryTests-\(label)")
        try FileManager.default.copyItem(
            at: try Self.libraryDirectory(),
            to: cwd.appendingPathComponent(skillsDotfolder, isDirectory: true))
        return cwd
    }

    /// The rendered body of one fixture skill: the file text after its front
    /// matter.
    ///
    /// - Parameter id: The skill id, which is also its directory name.
    /// - Returns: The body, with no leading or trailing blank line.
    /// - Throws: Whatever the read throws.
    static func fixtureBody(of id: String) throws -> String {
        let file = try Self.libraryDirectory()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        let text = try String(contentsOf: file, encoding: .utf8)
        let parts = text.components(separatedBy: "---\n")
        return parts.dropFirst(2).joined(separator: "---\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The mounted tool

    /// Builds the session surface over a workspace that holds the library.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - configure: The mutation that shapes the configuration.
    /// - Returns: The mounted surface.
    /// - Throws: Whatever the profile or the catalog throws.
    static func makeSurface(
        label: String, configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> SessionSurface {
        var configuration = AgentConfiguration()
        configuration.tools.codeContext = .disabled
        configuration.tools.shell = .disabled
        configure(&configuration)
        let context = CatalogContext(
            workingDirectory: try Self.makeWorkspace(label: label),
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "SkillsLibraryTests-\(label)-cache")))
        return try await ToolCatalog.sessionSurface(context: context)
    }

    /// The mounted `skills` tool of a surface.
    static func skillsTool(in surface: SessionSurface) throws -> any FoundationModels.Tool {
        try #require(surface.tools.first { $0.name == "skills" })
    }

    /// The `id` parameter of a tool, as the JSON text of its schema.
    static func parametersJSON(of tool: any FoundationModels.Tool) throws -> String {
        String(decoding: try JSONEncoder().encode(tool.parameters), as: UTF8.self)
    }

    @Test func theMountedToolCarriesEveryVisibleSkillAndNoHiddenOne() async throws {
        let surface = try await Self.makeSurface(label: "catalog")

        let tool = try Self.skillsTool(in: surface)

        #expect(tool.description.contains("- \(Self.exploreID):"))
        #expect(tool.description.contains("- \(Self.releaseNotesID):"))
        #expect(!tool.description.contains(Self.hiddenID))
        #expect(tool.description.contains(#"{"op": "use skill", "id": "<id>"}"#))
    }

    @Test func theIdParameterIsTheEnumOfTheVisibleSkills() async throws {
        let surface = try await Self.makeSurface(label: "enum")

        let schema = try Self.parametersJSON(of: try Self.skillsTool(in: surface))

        #expect(schema.contains("\"\(Self.exploreID)\""))
        #expect(schema.contains("\"\(Self.releaseNotesID)\""))
        #expect(!schema.contains(Self.hiddenID))
    }

    @Test func aDisabledSkillsSectionMountsNoSkillsTool() async throws {
        let surface = try await Self.makeSurface(label: "disabled") { configuration in
            configuration.tools.skills = .disabled
        }

        #expect(!surface.tools.contains { $0.name == "skills" })
    }

    // MARK: - A turn that loads a skill

    /// The text of every `tool_call_update` content block of the collected
    /// sequence, joined in arrival order.
    ///
    /// The loaded skill reaches the model through the tool result, and it
    /// reaches the client through these blocks. Reading them proves both.
    static func toolCallText(in updates: [UpdateSessionNotification]) -> String {
        updates.flatMap { notification -> [String] in
            guard case .toolCallUpdate(let update) = notification.update,
                case .value(let blocks) = update.content
            else { return [] }
            return blocks.compactMap { block in
                guard case .content(let wrapped) = block, case .text(let text) = wrapped.content
                else { return nil }
                return decodedJSONString(text.text) ?? text.text
            }
        }.joined(separator: "\n")
    }

    /// Decodes a text block that carries a JSON string.
    ///
    /// A `skills` answer is one String. The projection of a tool result puts
    /// that value on the wire as JSON, so a plain-text answer arrives quoted
    /// and escaped. The model reads the value itself, thus a proof of the
    /// text reads the decoded value too.
    ///
    /// - Parameter text: The block text.
    /// - Returns: The decoded string, or `nil` when `text` is not a JSON
    ///   string.
    static func decodedJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// Runs one turn whose script makes the given `skills` call.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - argumentsJSON: The arguments of the `skills` call.
    /// - Returns: The text the tool call carried to the client.
    /// - Throws: Whatever the wiring or the prompt throws.
    static func runSkillsCall(label: String, argumentsJSON: String) async throws -> String {
        let fixture = try await ScriptedTurnFixture.make(
            script: [.toolCall(name: "skills", argumentsJSON: argumentsJSON), .endTurn],
            label: "SkillsLibraryTests-\(label)",
            workingDirectory: try Self.makeWorkspace(label: label),
            projectConfigYAML: "tools:\n  shell: false\n  codeContext: false\n")
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: fixture.sessionId, text: "load a skill"))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.harness.flushPendingChunks()
        return Self.toolCallText(in: updates)
    }

    @Test(.timeLimit(.minutes(1)))
    func aUseSkillCallGivesTheTextOfTheSkillFile() async throws {
        let text = try await Self.runSkillsCall(
            label: "use",
            argumentsJSON: #"{"op": "use skill", "id": "\#(Self.exploreID)"}"#)

        #expect(text.contains(Self.exploreMarker))
        #expect(text.contains("tools.code_context.getCallgraph"))
        // The answer is the text of the skill, not JSON around it.
        #expect(!text.contains("\"body\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func aSearchGivesPlainLinesThatNameTheLoadCall() async throws {
        let text = try await Self.runSkillsCall(
            label: "search",
            argumentsJSON: #"{"op": "search skill", "query": "understand unfamiliar code"}"#)

        #expect(text.contains("- \(Self.exploreID):"))
        #expect(text.contains("To load a skill, call the `skills` tool with"))
        #expect(text.contains(#"{"op": "use skill", "id": "\#(Self.exploreID)"}"#))
        #expect(!text.contains(Self.hiddenID))
        #expect(!text.contains("\"matches\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func aHiddenSkillCannotBeLoaded() async throws {
        let text = try await Self.runSkillsCall(
            label: "hidden",
            argumentsJSON: #"{"op": "use skill", "id": "\#(Self.hiddenID)"}"#)

        #expect(!text.contains("FIXTURE-HIDDEN-BODY"))
    }
}
