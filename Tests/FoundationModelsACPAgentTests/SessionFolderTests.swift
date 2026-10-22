import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The session and project records on disk, as the agent writes them through
/// Router (task ^am394r2): one folder for each session, with its own
/// `index.md`, and one file for each project in the projects folder of the
/// home. No file is shared by two sessions or two projects, because a file
/// that two devices write does not sync (iCloud).
///
/// The suite reads the files as text, through the Extras frontmatter split
/// and the YAML parse, so each proof reads what is on disk.
@Suite(.closesHarnesses) struct SessionFolderTests {
    /// The directory label of the suite.
    private static let label = "SessionFolderTests"

    /// The name of the record file in each session folder.
    private static let indexFileName = "index.md"

    /// The name of the shared session listing that the agent must not write.
    private static let sharedListingFileName = "sessions.jsonl"

    /// The extension of a project file in the projects folder.
    private static let projectFileExtension = "md"

    /// The prompt text of the first session, which is also its title.
    private static let firstTitle = "the first session"

    /// The prompt text of the second session, which is also its title.
    private static let secondTitle = "the second session"

    /// The script of each prompt: one text, then the end of the pass.
    private static let script: [ScriptedPassStep] = [.textDelta("done"), .endPass]

    // MARK: - Two sessions in one folder

    /// Two prompted sessions in one working folder give two session folders,
    /// each with an `index.md` that holds the title of its first prompt and
    /// its additional directories. `session/list` shows both, and the
    /// recording root holds no shared `sessions.jsonl`.
    @Test func twoSessionsInOneFolderGiveTwoSessionFoldersThatTheListShows() async throws {
        let extraOne = makeResolvedDirectory(label: "\(Self.label)-extra-one")
        let extraTwo = makeResolvedDirectory(label: "\(Self.label)-extra-two")
        let fixture = try await Self.makeFixture(additionalDirectories: [extraOne])
        let second = try await Self.newSession(on: fixture, in: fixture.cwd, additionalDirectories: [extraTwo])
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstTitle)
        try await Self.runPrompt(Self.secondTitle, in: second, on: fixture, count: 2)

        let listed = try await fixture.harness.connection.listSessions(
            ListSessionsRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
        await fixture.close()

        let root = try Self.recordingRoot(of: fixture.cwd)
        let first = try Self.frontmatter(ofSession: fixture.sessionId, under: root)
        let other = try Self.frontmatter(ofSession: second, under: root)
        #expect(first["title"] == .string(Self.firstTitle))
        #expect(Self.paths(in: first["additionalDirectories"]) == [extraOne.standardizedFileURL.path])
        #expect(other["title"] == .string(Self.secondTitle))
        #expect(Self.paths(in: other["additionalDirectories"]) == [extraTwo.standardizedFileURL.path])
        #expect(Set(listed.sessions.map(\.sessionId)) == [fixture.sessionId, second])
        #expect(Set(listed.sessions.compactMap(\.title)) == [Self.firstTitle, Self.secondTitle])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.sharedListingFileName).path))
    }

    // MARK: - A session with no prompt

    /// A session with no prompt has its own folder and `index.md`, and
    /// `session/list` leaves it out.
    @Test func aSessionWithNoPromptHasItsFolderAndDoesNotList() async throws {
        let fixture = try await Self.makeFixture()

        let listed = try await fixture.harness.connection.listSessions(
            ListSessionsRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
        await fixture.close()

        let root = try Self.recordingRoot(of: fixture.cwd)
        _ = try Self.frontmatter(ofSession: fixture.sessionId, under: root)
        #expect(listed.sessions.isEmpty)
    }

    // MARK: - Two projects

    /// Sessions in two working folders give two project files in the
    /// projects folder of the home, one for each folder.
    @Test func twoProjectsGiveTwoFilesInTheProjectsFolderOfTheHome() async throws {
        let fixture = try await Self.makeFixture()
        let otherProject = makeResolvedDirectory(label: "\(Self.label)-other-project")
        _ = try await Self.newSession(on: fixture, in: otherProject)
        let projectsDirectory = fixture.harness.agent.home.projectsDirectory
        await fixture.close()

        let files = try FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == Self.projectFileExtension }
        let paths = try files.map { file in try Self.frontmatter(of: file)["path"]?.text }
        #expect(files.count == 2)
        #expect(Set(paths) == [fixture.cwd.standardizedFileURL.path, otherProject.standardizedFileURL.path])
    }

    // MARK: - The delete

    /// `session/delete` removes the folder of its own session and nothing
    /// else: the folder of the other session stays, and the recording root
    /// holds no other file.
    @Test func aDeleteRemovesOnlyTheFolderOfItsOwnSession() async throws {
        let fixture = try await Self.makeFixture()
        let kept = try await Self.newSession(on: fixture, in: fixture.cwd)
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.firstTitle)
        try await Self.runPrompt(Self.secondTitle, in: kept, on: fixture, count: 2)

        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()

        let root = try Self.recordingRoot(of: fixture.cwd)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == [kept.rawValue])
        #expect(try Self.frontmatter(ofSession: kept, under: root)["title"] == .string(Self.secondTitle))
    }

    // MARK: - Helpers

    /// Wires a scripted agent with one open session in a new working folder.
    ///
    /// - Parameter additionalDirectories: The additional directories of the
    ///   first session.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(additionalDirectories: [URL] = []) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(
            script: script, label: label,
            additionalDirectories: additionalDirectories.map { AbsolutePath(rawValue: $0.path) })
    }

    /// Opens one more session on the wire of `fixture`.
    ///
    /// - Parameters:
    ///   - fixture: The wired fixture.
    ///   - workingDirectory: The working folder of the session.
    ///   - additionalDirectories: The additional directories of the session.
    /// - Returns: The id of the new session.
    /// - Throws: Whatever `session/new` throws.
    private static func newSession(
        on fixture: ScriptedPromptFixture, in workingDirectory: URL, additionalDirectories: [URL] = []
    ) async throws -> SessionId {
        try await fixture.harness.connection.newSession(
            NewSessionRequest(
                cwd: AbsolutePath(rawValue: workingDirectory.path),
                additionalDirectories: additionalDirectories.map { AbsolutePath(rawValue: $0.path) })
        ).sessionId
    }

    /// Sends one prompt to `sessionId` and waits until it and its end work
    /// are done.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - sessionId: The session to prompt.
    ///   - fixture: The wired fixture.
    ///   - count: The number of idle updates the collector holds after it.
    /// - Throws: Whatever the prompt or a wait throws.
    private static func runPrompt(
        _ text: String, in sessionId: SessionId, on fixture: ScriptedPromptFixture, count: Int
    ) async throws {
        try await ScriptedPromptFixture.runPrompt(
            AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text),
            through: fixture.harness, count: count)
    }

    /// The recording root of the sessions of one working folder.
    ///
    /// - Parameter workingDirectory: The working folder.
    /// - Returns: The recording root.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func recordingRoot(of workingDirectory: URL) throws -> URL {
        try projectRecordingRoot(of: workingDirectory, dotfolderName: AgentClientHarness.dotfolderName)
    }

    /// The frontmatter keys of the `index.md` of one session folder.
    ///
    /// - Parameters:
    ///   - sessionId: The session, whose id names its folder.
    ///   - root: The recording root.
    /// - Returns: The keys and their values.
    /// - Throws: The read error, or a failed requirement when the file holds
    ///   no frontmatter mapping.
    private static func frontmatter(ofSession sessionId: SessionId, under root: URL) throws -> [String: YAMLValue] {
        try frontmatter(
            of: root.appendingPathComponent(sessionId.rawValue, isDirectory: true)
                .appendingPathComponent(indexFileName, isDirectory: false))
    }

    /// The frontmatter keys of one markdown file.
    ///
    /// - Parameter file: The file.
    /// - Returns: The keys and their values.
    /// - Throws: The read or the parse error, or a failed requirement when
    ///   the file holds no frontmatter mapping.
    private static func frontmatter(of file: URL) throws -> [String: YAMLValue] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let block = try #require(FrontmatterDocument<Never>.split(text: text).frontmatter)
        return try #require(try YAMLValue.parse(block).mapping, "the frontmatter is not a mapping")
    }

    /// The standardized paths of a YAML list of paths.
    ///
    /// - Parameter value: The YAML value of the list, or `nil`.
    /// - Returns: Each path, standardized, in order; none for a value that is
    ///   not a list of strings.
    private static func paths(in value: YAMLValue?) -> [String] {
        (value?.items ?? []).compactMap(\.text).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

extension YAMLValue {
    /// The keys of a mapping, or `nil` for any other value.
    fileprivate var mapping: [String: YAMLValue]? {
        if case .dictionary(let keys) = self { keys } else { nil }
    }

    /// The items of a sequence, or `nil` for any other value.
    fileprivate var items: [YAMLValue]? {
        if case .array(let items) = self { items } else { nil }
    }

    /// The text of a string scalar, or `nil` for any other value.
    fileprivate var text: String? {
        if case .string(let text) = self { text } else { nil }
    }
}
