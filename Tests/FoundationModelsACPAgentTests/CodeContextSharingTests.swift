import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCodeContext
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The sessions of one working directory share one code context (task
/// ^sxgcjds): each session surface leases the context of its working
/// directory, the close of a session gives its lease back, and the last
/// close stops the context. The index of the context is in the local root of
/// the home, never in the working directory.
@Suite struct CodeContextSharingTests {
    /// The name of the index folder that the code context makes in its root
    /// when the host gives it no index folder.
    private static let rootIndexFolderName = ".code-context"

    /// The projects folder of the local root of a home.
    private static let projectsFolderName = "projects"

    /// The index folder of one project in its state folder.
    private static let indexFolderName = "code-context"

    /// The database file of an index.
    private static let indexDatabaseName = "kit.db"

    /// A source file that the first index pass reads and embeds.
    private static let sourceFileName = "Answer.swift"

    /// The text of ``sourceFileName``.
    private static let sourceText = "func answer() -> Int { 42 }\n"

    /// What the sessions of one agent share: the resolved profile, whose
    /// embedding slot is the embedder of each code context, and the settings
    /// folders, whose home holds each index.
    private struct Agent {
        /// The resolved profile of the agent.
        let profile: LanguageModelProfile

        /// The settings folders of the agent.
        let settingsFolders: SettingsFolders

        /// The `codeContext:` options of each session.
        let options: CodeContextToolOptions
    }

    // MARK: Harness

    /// Makes an agent over a stub profile and a throwaway custom home.
    ///
    /// - Parameters:
    ///   - loader: The loader the stub profile resolves through.
    ///   - semanticSearch: Whether each code context embeds with the profile.
    /// - Returns: The agent.
    /// - Throws: Whatever the profile resolve throws.
    private static func makeAgent(
        loader: StubModelLoader = StubModelLoader(), semanticSearch: Bool = false
    ) async throws -> Agent {
        Agent(
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "CodeContextSharingTests-cache"), loader: loader),
            settingsFolders: try SettingsFoldersFixture.make(label: "CodeContextSharingTests"),
            options: CodeContextToolOptions(autoInstall: false, semanticSearch: semanticSearch))
    }

    /// Composes the surface of one session of `agent` in `workingDirectory`.
    /// Each section but the code context is off, so the surface starts
    /// nothing else.
    ///
    /// - Parameters:
    ///   - agent: The agent of the session.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The surface.
    /// - Throws: Whatever the composition throws.
    private static func openSession(of agent: Agent, in workingDirectory: URL) async throws -> SessionSurface {
        var configuration = AgentConfiguration.withoutMarketplaces
        configuration.tools.files = .disabled
        configuration.tools.shell = .disabled
        configuration.tools.codeContext = .enabled(agent.options)
        return try await ToolCatalog.sessionSurface(
            context: CatalogContext(
                workingDirectory: workingDirectory,
                configuration: configuration,
                profile: agent.profile,
                settingsFolders: agent.settingsFolders,
                environment: [:]))
    }

    /// The code context that `surface` leased.
    ///
    /// - Parameter surface: A session surface with the code context on.
    /// - Returns: The context.
    /// - Throws: When the surface leased no context.
    private static func codeContext(
        of surface: SessionSurface
    ) throws -> CodeContext<ProcessLanguageServerConnection> {
        try #require(surface.codeContextLease).context
    }

    /// Whether the code context that `surface` leased has its root at
    /// `directory`. Both paths are compared with their symbolic links
    /// resolved, because the code context keys a root that way: on macOS it
    /// gives `/tmp/x` for `/private/tmp/x`.
    ///
    /// - Parameters:
    ///   - surface: A session surface with the code context on.
    ///   - directory: The expected root.
    /// - Returns: Whether the root is `directory`.
    /// - Throws: When the surface leased no context.
    private static func isRooted(_ surface: SessionSurface, at directory: URL) throws -> Bool {
        try codeContext(of: surface).rootDirectory.resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path
    }

    /// Makes a new working directory.
    ///
    /// - Parameter name: The role of the directory.
    /// - Returns: The directory, under `/private/tmp`.
    private static func makeWorkingDirectory(named name: String) -> URL {
        makeResolvedDirectory(label: "CodeContextSharingTests-\(name)")
    }

    // MARK: One context per working directory

    @Test func twoSessionsInOneWorkingDirectoryShareOneCodeContext() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "shared")

        let first = try await Self.openSession(of: agent, in: workingDirectory)
        let second = try await Self.openSession(of: agent, in: workingDirectory)

        #expect(try Self.codeContext(of: first) === Self.codeContext(of: second))
        await first.shutdown()
        await second.shutdown()
    }

    @Test func closingOneOfTwoSessionsKeepsTheSharedContext() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "keeps")
        let first = try await Self.openSession(of: agent, in: workingDirectory)
        let second = try await Self.openSession(of: agent, in: workingDirectory)

        await first.shutdown()
        let third = try await Self.openSession(of: agent, in: workingDirectory)

        #expect(try Self.codeContext(of: third) === Self.codeContext(of: second))
        await second.shutdown()
        await third.shutdown()
    }

    /// The embedder never answers, so the first index pass of the context
    /// ends only when the context stops. The wait returns, so the close of
    /// the last session stopped the context; a new session then gets a new
    /// context.
    @Test(.timeLimit(.minutes(1)))
    func closingTheLastSessionStopsTheContext() async throws {
        var loader = StubModelLoader()
        loader.makeEmbeddingContainer = { _ in NeverAnsweringEmbeddingContainer() }
        let agent = try await Self.makeAgent(loader: loader, semanticSearch: true)
        let workingDirectory = Self.makeWorkingDirectory(named: "stops")
        try Self.sourceText.write(
            to: workingDirectory.appendingPathComponent(Self.sourceFileName), atomically: true, encoding: .utf8)
        let first = try await Self.openSession(of: agent, in: workingDirectory)
        let second = try await Self.openSession(of: agent, in: workingDirectory)
        let stopped = try Self.codeContext(of: first)

        await first.shutdown()
        await second.shutdown()
        await stopped.waitForFirstIndexPass()
        let next = try await Self.openSession(of: agent, in: workingDirectory)

        #expect(try Self.codeContext(of: next) !== stopped)
        await next.shutdown()
    }

    @Test func twoWorkingDirectoriesGetTwoContexts() async throws {
        let agent = try await Self.makeAgent()
        let left = Self.makeWorkingDirectory(named: "left")
        let right = Self.makeWorkingDirectory(named: "right")

        let leftSession = try await Self.openSession(of: agent, in: left)
        let rightSession = try await Self.openSession(of: agent, in: right)

        #expect(try Self.isRooted(leftSession, at: left))
        #expect(try Self.isRooted(rightSession, at: right))
        await leftSession.shutdown()
        await rightSession.shutdown()
    }

    @Test func aSessionInASubfolderSharesTheOpenContextOfItsParent() async throws {
        let agent = try await Self.makeAgent()
        let parent = Self.makeWorkingDirectory(named: "parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let parentSession = try await Self.openSession(of: agent, in: parent)
        let childSession = try await Self.openSession(of: agent, in: child)

        #expect(try Self.codeContext(of: childSession) === Self.codeContext(of: parentSession))
        await childSession.shutdown()
        await parentSession.shutdown()
    }

    /// A session in the parent folder of an open context cannot share it:
    /// the open context covers only the subfolder. The session still gets a
    /// code context over its own working directory.
    @Test func aSessionInTheParentOfAnOpenContextGetsItsOwnContext() async throws {
        let agent = try await Self.makeAgent()
        let parent = Self.makeWorkingDirectory(named: "outer")
        let child = parent.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let childSession = try await Self.openSession(of: agent, in: child)
        let parentSession = try await Self.openSession(of: agent, in: parent)

        #expect(try Self.isRooted(parentSession, at: parent))
        #expect(try Self.isRooted(childSession, at: child))
        await parentSession.shutdown()
        await childSession.shutdown()
    }

    // MARK: The manager key

    /// A manager has one language server install, so two sessions whose
    /// install differs cannot share a manager: their keys differ.
    @Test func settingsThatDifferOnlyInTheLanguageServerInstallGiveTwoManagerKeys() throws {
        let home = try SettingsFoldersFixture.make(label: "CodeContextSharingTests-key").home
        let installing = CodeContextLeases.ManagerSettings(
            embedder: nil, autoInstall: LspAutoInstall(isEnabled: true), home: home)
        let notInstalling = CodeContextLeases.ManagerSettings(
            embedder: nil, autoInstall: LspAutoInstall(isEnabled: false), home: home)

        #expect(installing.key != notInstalling.key)
    }

    // MARK: The index folder

    @Test func theIndexIsInTheLocalRootOfTheHomeAndNotInTheWorkingDirectory() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "index")

        let session = try await Self.openSession(of: agent, in: workingDirectory)

        let projects = agent.settingsFolders.home.local
            .appendingPathComponent(Self.projectsFolderName, isDirectory: true)
        let indexDatabases = try FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ).map {
            $0.appendingPathComponent(Self.indexFolderName, isDirectory: true)
                .appendingPathComponent(Self.indexDatabaseName)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(indexDatabases.count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: workingDirectory.appendingPathComponent(Self.rootIndexFolderName).path))
        await session.shutdown()
    }
}
