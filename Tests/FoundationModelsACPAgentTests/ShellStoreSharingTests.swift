import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The sessions of one working directory share one shell store (task
/// ^v3xvh4t): one history, one log and one set of command records. Each
/// session surface leases the store of its resolved store directory from
/// ``ShellStores/shared``, the close of a session gives its lease back, and
/// the last close drops the store. Each command records the session that ran
/// it, and the readers of every session see that owner.
@Suite struct ShellStoreSharingTests {
    /// The ACP session id that the first session of a test binds.
    private static let firstSessionID = "session-A"

    /// The ACP session id that the second session of a test binds.
    private static let secondSessionID = "session-B"

    /// How many lines each command of the concurrency proof writes.
    private static let concurrentLineCount = 400

    /// How many sessions run a command at the same time in the concurrency
    /// proof.
    private static let concurrentSessionCount = 2

    /// What the sessions of one agent share: the resolved profile and the
    /// settings folders, whose home holds the shell store of each project.
    private struct Agent {
        /// The resolved profile of the agent.
        let profile: LanguageModelProfile

        /// The settings folders of the agent.
        let settingsFolders: SettingsFolders
    }

    // MARK: Harness

    /// Makes an agent over a stub profile and a throwaway custom home.
    ///
    /// - Returns: The agent.
    /// - Throws: Whatever the profile resolve throws.
    private static func makeAgent() async throws -> Agent {
        Agent(
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "ShellStoreSharingTests-cache")),
            settingsFolders: try SettingsFoldersFixture.make(label: "ShellStoreSharingTests"))
    }

    /// The catalog context of one session of `agent` in `workingDirectory`.
    /// The code context is off, so the composition starts no index.
    ///
    /// - Parameters:
    ///   - agent: The agent of the session.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The context.
    private static func catalogContext(of agent: Agent, in workingDirectory: URL) -> CatalogContext {
        var configuration = AgentConfiguration.withoutMarketplaces
        configuration.tools.codeContext = .disabled
        return CatalogContext(
            workingDirectory: workingDirectory,
            configuration: configuration,
            profile: agent.profile,
            settingsFolders: agent.settingsFolders,
            environment: [:])
    }

    /// Builds the registry of one session of `agent` in `workingDirectory`,
    /// and binds its shell to `sessionID`, as the activation of a session
    /// binds the ACP session id.
    ///
    /// - Parameters:
    ///   - agent: The agent of the session.
    ///   - workingDirectory: The working directory of the session.
    ///   - sessionID: The ACP session id of the session.
    /// - Returns: The built registry.
    /// - Throws: Whatever the build throws, or when the shell is not mounted.
    private static func openRegistry(
        of agent: Agent, in workingDirectory: URL, sessionID: String
    ) async throws -> ToolCatalog.BuiltRegistry {
        let built = try await ToolCatalog.makeRegistry(context: catalogContext(of: agent, in: workingDirectory))
        try #require(built.shellSessionIdentity).bind(sessionID)
        return built
    }

    /// Composes the surface of one session of `agent` in `workingDirectory`.
    ///
    /// - Parameters:
    ///   - agent: The agent of the session.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The surface.
    /// - Throws: Whatever the composition throws.
    private static func openSurface(of agent: Agent, in workingDirectory: URL) async throws -> SessionSurface {
        try await ToolCatalog.sessionSurface(context: catalogContext(of: agent, in: workingDirectory))
    }

    /// The shell store that `surface` leased.
    ///
    /// - Parameter surface: A session surface with the shell on.
    /// - Returns: The store.
    /// - Throws: When the surface leased no store.
    private static func store(of surface: SessionSurface) throws -> ShellStore {
        try #require(surface.shellStoreLease).store
    }

    /// The shell store that `built` leased.
    ///
    /// - Parameter built: A built registry with the shell on.
    /// - Returns: The store.
    /// - Throws: When the build leased no store.
    private static func store(of built: ToolCatalog.BuiltRegistry) throws -> ShellStore {
        try #require(built.shellStoreLease).store
    }

    /// Makes a new working directory.
    ///
    /// - Parameter name: The role of the directory.
    /// - Returns: The directory, under `/private/tmp`.
    private static func makeWorkingDirectory(named name: String) -> URL {
        makeResolvedDirectory(label: "ShellStoreSharingTests-\(name)")
    }

    /// Runs `command` in `built` and returns the `commandID` of its report.
    ///
    /// - Parameters:
    ///   - command: The shell command.
    ///   - built: The registry of the session that runs it.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The command id.
    /// - Throws: Whatever the run throws, or when the report has no id.
    private static func run(
        _ command: String, in built: ToolCatalog.BuiltRegistry, workingDirectory: URL
    ) async throws -> String {
        let report = try await ShellVerbSupport.executeReport(
            in: built.registry, command: command, workingDirectory: workingDirectory)
        return try #require(report["commandID"] as? String)
    }

    /// The shell command that writes `count` lines `<tag>-1` to
    /// `<tag>-<count>`, one line at a time.
    ///
    /// - Parameters:
    ///   - tag: The text each line starts with.
    ///   - count: How many lines to write.
    /// - Returns: The command line.
    private static func numberedLinesCommand(tag: String, count: Int) -> String {
        "i=1; while [ $i -le \(count) ]; do echo \(tag)-$i; i=$((i+1)); done"
    }

    /// The lines that ``numberedLinesCommand(tag:count:)`` writes.
    ///
    /// - Parameters:
    ///   - tag: The text each line starts with.
    ///   - count: How many lines.
    /// - Returns: The lines, in order.
    private static func numberedLines(tag: String, count: Int) -> [String] {
        (1...count).map { "\(tag)-\($0)" }
    }

    /// The `lines` that `tools.shell.getLines` answers for a command that
    /// wrote `written`: each line after its line number, `N: text`.
    ///
    /// - Parameter written: The lines the command wrote, in order.
    /// - Returns: The lines as the verb renders them.
    private static func readLines(of written: [String]) -> [String] {
        written.enumerated().map { "\($0.offset + 1): \($0.element)" }
    }

    // MARK: One store per resolved store directory

    @Test func sessionBReadsTheCommandThatSessionARanWithItsOwner() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "shared")
        let first = try await Self.openRegistry(of: agent, in: workingDirectory, sessionID: Self.firstSessionID)
        let second = try await Self.openRegistry(of: agent, in: workingDirectory, sessionID: Self.secondSessionID)
        let marker = "ran-by-the-first-session"

        let report = try await ShellVerbSupport.executeReport(
            in: first.registry, command: "echo \(marker)", workingDirectory: workingDirectory)
        let commandID = try #require(report["commandID"] as? String)
        let lines = try await ShellVerbSupport.getLines(in: second.registry, commandID: commandID)
        let grep = try await ShellVerbSupport.grepHistory(in: second.registry, pattern: marker)
        let matches = try #require(grep["matches"] as? [[String: Any]])

        #expect(report["sessionID"] as? String == Self.firstSessionID)
        #expect(lines["lines"] as? [String] == Self.readLines(of: [marker]))
        #expect(lines["sessionID"] as? String == Self.firstSessionID)
        #expect(matches.map { $0["commandID"] as? String } == [commandID])
        #expect(matches.map { $0["sessionID"] as? String } == [Self.firstSessionID])
        await first.shellStoreLease?.release()
        await second.shellStoreLease?.release()
    }

    @Test func twoWorkingDirectoriesKeepSeparateStores() async throws {
        let agent = try await Self.makeAgent()
        let left = Self.makeWorkingDirectory(named: "left")
        let right = Self.makeWorkingDirectory(named: "right")
        let leftSession = try await Self.openRegistry(of: agent, in: left, sessionID: Self.firstSessionID)
        let rightSession = try await Self.openRegistry(of: agent, in: right, sessionID: Self.secondSessionID)
        let marker = "ran-in-the-left-directory"

        _ = try await Self.run("echo \(marker)", in: leftSession, workingDirectory: left)
        let grep = try await ShellVerbSupport.grepHistory(in: rightSession.registry, pattern: marker)

        #expect(try Self.store(of: leftSession) !== Self.store(of: rightSession))
        #expect(try Self.store(of: leftSession).directory != Self.store(of: rightSession).directory)
        #expect((grep["matches"] as? [[String: Any]])?.isEmpty == true)
        await leftSession.shellStoreLease?.release()
        await rightSession.shellStoreLease?.release()
    }

    /// Two sessions run a command each at the same time, on one store. Each
    /// session reads the other's lines whole and in order, and each line of
    /// the log is one whole record.
    @Test func concurrentCommandsFromTwoSessionsLeaveEveryLogLineWhole() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "concurrent")
        let first = try await Self.openRegistry(of: agent, in: workingDirectory, sessionID: Self.firstSessionID)
        let second = try await Self.openRegistry(of: agent, in: workingDirectory, sessionID: Self.secondSessionID)
        let count = Self.concurrentLineCount

        async let firstID = Self.run(
            Self.numberedLinesCommand(tag: "a", count: count), in: first, workingDirectory: workingDirectory)
        async let secondID = Self.run(
            Self.numberedLinesCommand(tag: "b", count: count), in: second, workingDirectory: workingDirectory)
        let (firstCommand, secondCommand) = try await (firstID, secondID)
        let firstRead = try await ShellVerbSupport.getLines(in: second.registry, commandID: firstCommand)
        let secondRead = try await ShellVerbSupport.getLines(in: first.registry, commandID: secondCommand)
        let logLines = try Self.storedLogLines(in: Self.store(of: first).directory)
            .filter { $0.contains(firstCommand) || $0.contains(secondCommand) }

        #expect(firstRead["lines"] as? [String] == Self.readLines(of: Self.numberedLines(tag: "a", count: count)))
        #expect(secondRead["lines"] as? [String] == Self.readLines(of: Self.numberedLines(tag: "b", count: count)))
        #expect(logLines.count == Self.concurrentSessionCount * count)
        #expect(logLines.allSatisfy(Self.isWholeRecord))
        await first.shellStoreLease?.release()
        await second.shellStoreLease?.release()
    }

    /// Every line of every file in `directory`.
    ///
    /// - Parameter directory: The store directory.
    /// - Returns: The lines, file by file.
    /// - Throws: Whatever the listing or a read throws.
    private static func storedLogLines(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .flatMap { file in
                try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            }
    }

    /// Whether `line` is one whole log record
    /// `{store}:{commandID}:{lineNumber}:{tag}-{number}`, so no other write
    /// cut into it.
    ///
    /// - Parameter line: One line of the log.
    /// - Returns: Whether the line is whole.
    private static func isWholeRecord(_ line: String) -> Bool {
        line.wholeMatch(of: /[^:]+:[^:]+:[0-9]+:[ab]-[0-9]+/) != nil
    }

    // MARK: The lease

    @Test func closingOneOfTwoSessionsKeepsTheSharedStore() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "keeps")
        let first = try await Self.openSurface(of: agent, in: workingDirectory)
        let second = try await Self.openSurface(of: agent, in: workingDirectory)

        await first.shutdown()
        let third = try await Self.openSurface(of: agent, in: workingDirectory)

        #expect(try Self.store(of: first) === Self.store(of: second))
        #expect(try Self.store(of: third) === Self.store(of: second))
        await second.shutdown()
        await third.shutdown()
    }

    @Test func closingTheLastSessionDropsTheStore() async throws {
        let agent = try await Self.makeAgent()
        let workingDirectory = Self.makeWorkingDirectory(named: "drops")
        let first = try await Self.openSurface(of: agent, in: workingDirectory)
        let dropped = try Self.store(of: first)

        await first.shutdown()
        let next = try await Self.openSurface(of: agent, in: workingDirectory)

        #expect(try Self.store(of: next) !== dropped)
        #expect(try Self.store(of: next).directory == dropped.directory)
        await next.shutdown()
    }
}
