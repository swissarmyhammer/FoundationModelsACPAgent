import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Multi-root confinement, end to end (plan.md §7.2)
//
// The advertised `additionalDirectories: {}` capability must be honest:
// the agent applies each accepted root, it does not accept and ignore.
// This suite is the proof, from the client end of the wire: a session
// made with an additional root R reads under R, refuses a path outside
// the union of cwd and R, lets a shell command write into R, keeps the
// transcripts under the cwd dotfolder, reports the ordered list through
// `session/list`, and refuses a relative entry outright.

/// The client-end proofs of plan.md §7.2: the additional roots extend
/// confinement, and nothing else about the session moves.
struct MultiRootConfinementTests {
    /// The content the read tests write under the additional root.
    private static let insideContent = "inside the additional root"

    /// A throwaway directory under `/private/tmp`, labeled with this
    /// suite's name and the directory's role.
    ///
    /// - Parameter name: The directory's role.
    /// - Returns: The created directory.
    private static func makeResolvedDirectory(named name: String) -> URL {
        FoundationModelsACPAgentTestSupport.makeResolvedDirectory(
            label: "MultiRootConfinementTests-\(name)")
    }

    /// Makes one wired fixture whose session carries `additionalRoots`.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - additionalRoots: The `session/new` additional roots, in order.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        label: String, additionalRoots: [URL]
    ) async throws -> ResumeSessionFixture {
        try await ResumeSessionFixture.make(
            label: "MultiRootConfinementTests-\(label)",
            additionalDirectories: additionalRoots.map { root in
                AbsolutePath(rawValue: root.path)
            })
    }

    /// The table entry of the fixture's one session.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The entry.
    /// - Throws: When the session is not in the table.
    private static func sessionEntry(
        of fixture: ResumeSessionFixture
    ) async throws -> ActiveSession {
        try #require(
            await fixture.fixture.harness.agent.sessions[fixture.fixture.sessionId])
    }

    // MARK: - The read verb over the union (plan.md §7.2, §11.4)

    /// A session made over the wire with an additional root R reads a
    /// file under R through its mounted `tools.files.read` verb, and the
    /// session's table entry holds R in wire order.
    @Test(.timeLimit(.minutes(1)))
    func aSessionReadsAFileUnderAnAdditionalRootFromTheClientEnd() async throws {
        let additionalRoot = Self.makeResolvedDirectory(named: "read-extra")
        let insideFile = additionalRoot.appendingPathComponent("inside.txt")
        try Self.insideContent.write(to: insideFile, atomically: true, encoding: .utf8)
        let fixture = try await Self.makeFixture(
            label: "read", additionalRoots: [additionalRoot])

        let entry = try await Self.sessionEntry(of: fixture)
        let readVerb = try #require(entry.surface.filesReadVerb)
        let result = try await FilesVerbSupport.invokeRead(readVerb, path: insideFile.path)

        #expect(entry.additionalRoots.map(\.path) == [additionalRoot.path])
        #expect(result.correction == nil)
        #expect(!result.lines.isEmpty)
        await fixture.fixture.close()
    }

    /// A path outside the union of the cwd and the additional root is
    /// still refused: the verb answers a correction and no content.
    @Test(.timeLimit(.minutes(1)))
    func aPathOutsideTheRootUnionIsStillRefused() async throws {
        let additionalRoot = Self.makeResolvedDirectory(named: "refuse-extra")
        let outside = Self.makeResolvedDirectory(named: "refuse-outside")
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try "outside the union".write(to: outsideFile, atomically: true, encoding: .utf8)
        let fixture = try await Self.makeFixture(
            label: "refuse", additionalRoots: [additionalRoot])

        let entry = try await Self.sessionEntry(of: fixture)
        let readVerb = try #require(entry.surface.filesReadVerb)
        let result = try await FilesVerbSupport.invokeRead(readVerb, path: outsideFile.path)

        #expect(result.correction != nil)
        #expect(result.lines.isEmpty)
        await fixture.fixture.close()
    }

    // MARK: - The refusal rule (plan.md §7.2)

    /// The one converter from wire path strings to confinement roots
    /// refuses a relative entry, naming its own field. The wire decode
    /// carries every entry as sent, so a skip here would drop a
    /// confinement root the client asked for and never say so.
    @Test func aRelativePathStringIsRefusedFromTheAdditionalRoots() async {
        await SessionSetupTests.expectRelativePathRefusal(naming: .additionalDirectories) {
            _ = try SessionSetup.additionalRoots(
                fromPaths: ["relative/entry", "/extra/a", "/extra/b"])
        }
    }

    /// An absolute entry list still converts in wire order, so the
    /// refusal above reads one relative entry and not the whole list.
    @Test func absolutePathStringsKeepTheirWireOrder() throws {
        let roots = try SessionSetup.additionalRoots(fromPaths: ["/extra/a", "/extra/b"])

        #expect(roots.map(\.path) == ["/extra/a", "/extra/b"])
    }

    /// A `session/new` that carries a relative entry beside an absolute
    /// one starts no session: the agent owns the file system, so the
    /// agent answers invalid params and the client fixes its request.
    @Test(.timeLimit(.minutes(1)))
    func aRelativeEntryRefusesTheWholeSessionRequest() async throws {
        let cwd = Self.makeResolvedDirectory(named: "raw-cwd")
        let additionalRoot = Self.makeResolvedDirectory(named: "raw-extra")
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: Self.makeResolvedDirectory(named: "raw-cache"),
            recordingsDirectory: Self.makeResolvedDirectory(named: "raw-recordings"),
            userDirectory: Self.makeResolvedDirectory(named: "raw-user"))
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())

        await SessionSetupTests.expectRelativePathRefusal(naming: .additionalDirectories) {
            _ = try await harness.connection.newSession(
                NewSessionRequest(
                    cwd: AbsolutePath(rawValue: cwd.path),
                    additionalDirectories: [
                        AbsolutePath(rawValue: "relative/entry"),
                        AbsolutePath(rawValue: additionalRoot.path),
                    ]))
        }
        #expect(await agent.sessions.isEmpty)
        await harness.close()
    }

    // MARK: - The shell write into the additional root (plan.md §11.7)

    /// A shell command run in the additional root writes a file there,
    /// shown by reading the file from disk: the sandbox's writable roots
    /// carry the whole root set, not the cwd alone.
    @Test(.timeLimit(.minutes(1)))
    func aShellCommandWritesIntoTheAdditionalRoot() async throws {
        let cwd = Self.makeResolvedDirectory(named: "shell-cwd")
        let additionalRoot = Self.makeResolvedDirectory(named: "shell-extra")
        var configuration = AgentConfiguration()
        configuration.tools.shell = .enabled(
            ShellToolOptions(storeDirectory: Self.makeResolvedDirectory(named: "shell-store")))
        let context = CatalogContext(
            workingDirectory: cwd,
            additionalRoots: [additionalRoot],
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: Self.makeResolvedDirectory(named: "shell-cache")))
        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        _ = try await ShellVerbSupport.invokeExecute(
            in: registry,
            command: "printf reachable > written.txt",
            workingDirectory: additionalRoot)

        let written = additionalRoot.appendingPathComponent("written.txt")
        #expect(try String(contentsOf: written, encoding: .utf8) == "reachable")
    }

    // MARK: - The transcript location (plan.md §7.2, §4.1)

    /// The transcripts stay under `<cwd>/.<name>/` when an additional
    /// root is supplied: the recorded turn lands under the cwd dotfolder
    /// and the additional root stays empty.
    @Test(.timeLimit(.minutes(1)))
    func transcriptsStayUnderTheCwdDotfolderWhenAnAdditionalRootIsSupplied() async throws {
        let additionalRoot = Self.makeResolvedDirectory(named: "transcripts-extra")
        var fixture = try await Self.makeFixture(
            label: "transcripts", additionalRoots: [additionalRoot])

        try await fixture.runTurn("one recorded turn")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: fixture.recordingRoot,
            sessionId: fixture.fixture.sessionId,
            count: 1)

        let entry = try await Self.sessionEntry(of: fixture)
        let dotfolder = fixture.fixture.cwd.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        #expect(entry.transcriptDirectory.path.hasPrefix(dotfolder.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: additionalRoot.path).isEmpty)
        await fixture.fixture.close()
    }

    // MARK: - The `session/list` report (plan.md §9)

    /// `session/list` reports the complete ordered list from the most
    /// recent activation: the two roots come back in wire order after
    /// the first prompt writes the index record.
    @Test(.timeLimit(.minutes(1)))
    func sessionListReportsTheOrderedListFromTheActivation() async throws {
        let firstRoot = Self.makeResolvedDirectory(named: "list-first")
        let secondRoot = Self.makeResolvedDirectory(named: "list-second")
        var fixture = try await Self.makeFixture(
            label: "list", additionalRoots: [firstRoot, secondRoot])

        try await fixture.runTurn("write the index record")
        let cwd = AbsolutePath(rawValue: fixture.fixture.cwd.path)
        let response = try await fixture.fixture.harness.connection.listSessions(
            ListSessionsRequest(cwd: cwd))

        let info = try #require(
            response.sessions.first { $0.sessionId == fixture.fixture.sessionId })
        #expect(
            info.additionalDirectories?.map(\.rawValue) == [firstRoot.path, secondRoot.path])
        await fixture.fixture.close()
    }
}
