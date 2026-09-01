import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras
import FoundationModelsSkills
import Testing

/// Session-instructions assembly through `InstructionsAssembler` (plan.md
/// §3). Every test builds its own throwaway tree under a temp directory
/// and injects the user directory and the environment, so no test touches
/// the real home directory.
@Suite struct InstructionsAssemblerTests {
    /// The dotfolder name every fixture stack is built for.
    static let agentName = "testagent"

    /// A distinctive line from the builtin prompt. Tests use it to show
    /// that the builtin is present or absent.
    static let builtinMarker = BuiltinInstructions.text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .first ?? BuiltinInstructions.text

    /// The frontmatter of a skill that the assembler must preload.
    static let preloadedFrontmatter = "description: a preloaded skill\npreload: true"

    /// Bytes that do not decode as UTF-8 — the "present but unreadable"
    /// file content.
    static let invalidUTF8Bytes: [UInt8] = [0xFF, 0xFE, 0xFF]

    /// A throwaway fixture tree: a workspace with a `.git` marker, an
    /// injected user layer root, a project layer, and a skills root. The
    /// OS reclaims the temp directory.
    struct Fixture {
        /// The temp root that holds every other directory.
        let root: URL
        /// The session working directory; the project layer roots under it.
        let workingDirectory: URL
        /// The injected user layer root.
        let userDirectory: URL
        /// The project layer root, `<workingDirectory>/.<name>/`.
        let projectDirectory: URL
        /// The layer root every fixture `SkillsRegistry` is built over.
        let skillsDirectory: URL

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "InstructionsAssemblerTests-\(UUID().uuidString)", isDirectory: true)
            workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            projectDirectory = workingDirectory.appendingPathComponent(
                ".\(InstructionsAssemblerTests.agentName)", isDirectory: true)
            skillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
            for directory in [userDirectory, projectDirectory, skillsDirectory] {
                try! FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            // The `.git` entry marks the workspace as the repository root
            // for the AGENTS.md walk.
            try! FileManager.default.createDirectory(
                at: workingDirectory.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
        }

        /// The assembler for a session at `directory`, or at the workspace
        /// when `directory` is `nil`. The stack injects the fixture's user
        /// layer and an empty environment.
        func assembler(at directory: URL? = nil) -> InstructionsAssembler {
            let sessionDirectory = directory ?? workingDirectory
            let stack = DotfolderStack(
                name: InstructionsAssemblerTests.agentName,
                workingDirectory: sessionDirectory,
                userDirectory: userDirectory,
                environment: [:])
            return InstructionsAssembler(stack: stack, workingDirectory: sessionDirectory)
        }

        /// Writes `text` at `relativePath` under `directory`, and creates
        /// the intermediate directories.
        func write(_ text: String, to relativePath: String, under directory: URL) {
            let url = directory.appendingPathComponent(relativePath)
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Writes bytes that are not valid UTF-8 at `relativePath` under
        /// `directory` — the "present but unreadable" case.
        func writeUnreadable(to relativePath: String, under directory: URL) {
            let url = directory.appendingPathComponent(relativePath)
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(InstructionsAssemblerTests.invalidUTF8Bytes).write(to: url)
        }

        /// Writes `<skillsDirectory>/<id>/SKILL.md` with `frontmatter`
        /// lines between the `---` fences and `body` below them.
        func writeSkill(id: String, frontmatter: String, body: String) {
            write(
                "---\n\(frontmatter)\n---\n\(body)\n",
                to: "\(id)/SKILL.md", under: skillsDirectory)
        }
    }

    // MARK: - The builtin floor

    @Test func assemblesExactlyTheBuiltinWithNoFiles() throws {
        let fixture = Fixture()

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text == BuiltinInstructions.text)
        #expect(assembled.warnings.isEmpty)
    }

    // MARK: - Wholesale replacement

    @Test func projectInstructionsReplaceTheBuiltinWholesale() throws {
        let fixture = Fixture()
        fixture.write(
            "PROJECT-PROMPT-TEXT", to: "Instructions.md", under: fixture.projectDirectory)

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains("PROJECT-PROMPT-TEXT"))
        #expect(!assembled.text.contains(Self.builtinMarker))
    }

    @Test func nearestInstructionsLayerWins() throws {
        let fixture = Fixture()
        fixture.write("USER-PROMPT-TEXT", to: "Instructions.md", under: fixture.userDirectory)
        fixture.write(
            "PROJECT-PROMPT-TEXT", to: "Instructions.md", under: fixture.projectDirectory)

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains("PROJECT-PROMPT-TEXT"))
        #expect(!assembled.text.contains("USER-PROMPT-TEXT"))
        #expect(!assembled.text.contains(Self.builtinMarker))
    }

    @Test func userInstructionsReplaceWhenNoProjectFile() throws {
        let fixture = Fixture()
        fixture.write("USER-PROMPT-TEXT", to: "Instructions.md", under: fixture.userDirectory)

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains("USER-PROMPT-TEXT"))
        #expect(!assembled.text.contains(Self.builtinMarker))
    }

    // MARK: - Trust from the source

    @Test func diskInstructionsRenderUntrusted() throws {
        let fixture = Fixture()
        // `{% now %}` is not in the untrusted tag whitelist, so an
        // untrusted render must refuse it.
        fixture.write(
            "PROMPT {% now %}", to: "Instructions.md", under: fixture.projectDirectory)

        #expect(throws: TemplateEngineError.self) {
            try fixture.assembler().assemble()
        }
    }

    // MARK: - Partials

    @Test func projectPartialReplacesOnePartialAndKeepsThePrompt() throws {
        let fixture = Fixture()
        fixture.write(
            "BASE-PROMPT-TEXT\n{% include \"style\" %}",
            to: "Instructions.md", under: fixture.userDirectory)
        fixture.write("USER-STYLE-TEXT", to: "_partials/style.md", under: fixture.userDirectory)
        fixture.write(
            "PROJECT-STYLE-TEXT", to: "_partials/style.md", under: fixture.projectDirectory)

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains("BASE-PROMPT-TEXT"))
        #expect(assembled.text.contains("PROJECT-STYLE-TEXT"))
        #expect(!assembled.text.contains("USER-STYLE-TEXT"))
    }

    // MARK: - Preloaded skill bodies

    @Test func preloadedSkillBodiesJoinAfterThePromptBeforeAgents() throws {
        let fixture = Fixture()
        fixture.writeSkill(
            id: "alpha",
            frontmatter: Self.preloadedFrontmatter,
            body: "PRELOADED-ALPHA-BODY")
        fixture.writeSkill(
            id: "beta",
            frontmatter: "description: a plain skill",
            body: "PLAIN-BETA-BODY")
        fixture.write("USER-AGENTS-TEXT", to: "AGENTS.md", under: fixture.userDirectory)
        let registry = SkillsRegistry(roots: [fixture.skillsDirectory])

        let assembled = try fixture.assembler().assemble(skills: registry)

        let text = assembled.text
        #expect(text.contains("PRELOADED-ALPHA-BODY"))
        #expect(!text.contains("PLAIN-BETA-BODY"))
        let promptRange = try #require(text.range(of: Self.builtinMarker))
        let skillRange = try #require(text.range(of: "PRELOADED-ALPHA-BODY"))
        let agentsRange = try #require(text.range(of: "USER-AGENTS-TEXT"))
        #expect(promptRange.lowerBound < skillRange.lowerBound)
        #expect(skillRange.lowerBound < agentsRange.lowerBound)
    }

    @Test func editedSkillChangesTheNextAssembly() async throws {
        let fixture = Fixture()
        fixture.writeSkill(
            id: "alpha",
            frontmatter: Self.preloadedFrontmatter,
            body: "PRELOADED-BODY-V1")
        let registry = SkillsRegistry(roots: [fixture.skillsDirectory], watch: true)
        let assembler = fixture.assembler()

        let before = try assembler.assemble(skills: registry)
        #expect(before.text.contains("PRELOADED-BODY-V1"))

        fixture.writeSkill(
            id: "alpha",
            frontmatter: Self.preloadedFrontmatter,
            body: "PRELOADED-BODY-V2")

        // The watcher rebuilds after a debounce; poll the next assemblies
        // until the edit shows.
        let reloadTimeout: Duration = .seconds(10)
        let pollInterval: Duration = .milliseconds(50)
        let deadline = ContinuousClock.now.advanced(by: reloadTimeout)
        var after = try assembler.assemble(skills: registry)
        while !after.text.contains("PRELOADED-BODY-V2"), ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            after = try assembler.assemble(skills: registry)
        }
        #expect(after.text.contains("PRELOADED-BODY-V2"))
        #expect(!after.text.contains("PRELOADED-BODY-V1"))
    }

    // MARK: - AGENTS.md assembly

    @Test func agentsDocumentsAssembleRootToCwdWithPathHeaders() throws {
        let fixture = Fixture()
        let subDirectory = fixture.workingDirectory.appendingPathComponent(
            "sub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: subDirectory, withIntermediateDirectories: true)
        fixture.write("USER-AGENTS-TEXT", to: "AGENTS.md", under: fixture.userDirectory)
        fixture.write("ROOT-AGENTS-TEXT", to: "AGENTS.md", under: fixture.workingDirectory)
        fixture.write("SUB-CLAUDE-TEXT", to: "CLAUDE.md", under: subDirectory)

        let assembled = try fixture.assembler(at: subDirectory).assemble()

        let text = assembled.text
        let builtinRange = try #require(text.range(of: Self.builtinMarker))
        let userRange = try #require(text.range(of: "USER-AGENTS-TEXT"))
        let rootRange = try #require(text.range(of: "ROOT-AGENTS-TEXT"))
        let subRange = try #require(text.range(of: "SUB-CLAUDE-TEXT"))
        #expect(builtinRange.lowerBound < userRange.lowerBound)
        #expect(userRange.lowerBound < rootRange.lowerBound)
        #expect(rootRange.lowerBound < subRange.lowerBound)

        // Every included file's absolute path appears as a divider header.
        let userAgentsURL = fixture.userDirectory.appendingPathComponent("AGENTS.md")
        #expect(text.contains(userAgentsURL.path))
        // One document for the workspace root, one for `sub/`.
        let expectedProjectDocumentCount = 2
        let documents = try AgentsMd.documents(from: subDirectory)
        #expect(documents.count == expectedProjectDocumentCount)
        for document in documents {
            #expect(text.contains(document.url.path))
        }
    }

    // MARK: - Unreadable files

    @Test func unreadableInstructionsWarnsAndFallsBackToTheBuiltin() throws {
        let fixture = Fixture()
        fixture.writeUnreadable(to: "Instructions.md", under: fixture.projectDirectory)
        let path = fixture.projectDirectory.appendingPathComponent("Instructions.md").path

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text == BuiltinInstructions.text)
        #expect(assembled.warnings == [.fileUnreadable(path: path)])
    }

    @Test func unreadableUserAgentsWarnsAndContinues() throws {
        let fixture = Fixture()
        fixture.writeUnreadable(to: "AGENTS.md", under: fixture.userDirectory)
        let path = fixture.userDirectory.appendingPathComponent("AGENTS.md").path

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains(Self.builtinMarker))
        #expect(assembled.warnings == [.fileUnreadable(path: path)])
    }

    @Test func unreadableProjectAgentsWarnsAndKeepsTheRest() throws {
        let fixture = Fixture()
        fixture.write("USER-AGENTS-TEXT", to: "AGENTS.md", under: fixture.userDirectory)
        fixture.writeUnreadable(to: "AGENTS.md", under: fixture.workingDirectory)

        let assembled = try fixture.assembler().assemble()

        #expect(assembled.text.contains(Self.builtinMarker))
        #expect(assembled.text.contains("USER-AGENTS-TEXT"))
        #expect(assembled.warnings.count == 1)
        switch try #require(assembled.warnings.first) {
        case .fileUnreadable(let warnedPath):
            #expect(warnedPath.hasSuffix("/AGENTS.md"))
        }
    }
}
