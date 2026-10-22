import ArgumentParser
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent snapshots list` and `acp-agent snapshots remove`: the explicit
/// commands that show and remove the snapshot folders. No sweep removes a
/// folder; the user decides. Each test parses the real arguments and builds
/// the report in process, over a temporary `XDG_CONFIG_HOME` and a temporary
/// `XDG_DATA_HOME`.
struct SnapshotsCommandTests {
    // MARK: - Constants

    /// The session key of the shadow folder of each test.
    private static let sessionKey = "01M5DF0Q6S3V6J5G4XN6C7T1RC"

    /// A session key that has no shadow folder: a key that the user mistyped.
    private static let mistypedKey = "01M5DF0Q6S3V6J5G4XN6C7T1RX"

    /// The text after the key on the stderr line of a key with no folder.
    private static let noSnapshotFolderText = "no snapshot folder"

    /// The permissions of a directory that its owner can read and enter, but
    /// not write. A remove of an entry in it fails.
    private static let readOnlyPermissions = NSNumber(value: 0o500)

    /// The recorded state of a key that no recording root has a session
    /// folder of.
    private static let unrecordedText = "unrecorded"

    /// The opening of the warning of a project store that cannot be read.
    private static let projectStoreWarningOpening = "The project store cannot be read"

    // MARK: - The fixture

    /// A temporary config home and a temporary data home, with one shadow
    /// folder with no timeline for ``SnapshotsCommandTests/sessionKey``.
    private struct Fixture {
        /// The config home and the working directory of the commands.
        let configFixture: ConfigCommandFixture

        /// The injected `XDG_DATA_HOME`.
        let dataHome: URL

        /// Makes the directories and the shadow folder.
        ///
        /// - Parameter label: The prefix that names the calling test.
        /// - Throws: The error of the directory creation.
        init(label: String) throws {
            configFixture = ConfigCommandFixture(label: label)
            dataHome = makeResolvedDirectory(label: "\(label)-data")
            try FileManager.default.createDirectory(
                at: shadowFolder(of: SnapshotsCommandTests.sessionKey), withIntermediateDirectories: true)
        }

        /// The environment that the commands read.
        var environment: [String: String] {
            configFixture.environment.merging([AgentHome.dataHomeEnvironmentKey: dataHome.path]) { _, data in data }
        }

        /// The XDG home of the CLI over ``environment``.
        ///
        /// - Returns: The home.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        func home() throws -> AgentHome {
            AgentHome.makeXDG(name: try DotfolderName(AgentComposition.dotfolderName), environment: environment)
        }

        /// The shadow folder of `sessionKey` in the hooks folder of the XDG
        /// home of the CLI, under the data home.
        ///
        /// - Parameter sessionKey: The session key.
        /// - Returns: The folder.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        func shadowFolder(of sessionKey: String) throws -> URL {
            AgentHooks.snapshotDirectory(in: try home().hooksDirectory)
                .appendingPathComponent(sessionKey, isDirectory: true)
        }

        /// Whether the shadow folder of `sessionKey` is on disk.
        ///
        /// - Parameter sessionKey: The session key.
        /// - Returns: `true` when the folder is on disk.
        func hasShadowFolder(of sessionKey: String) throws -> Bool {
            FileManager.default.fileExists(atPath: try shadowFolder(of: sessionKey).path)
        }

        /// Makes the project store of the home unreadable: its projects
        /// folder is a file.
        ///
        /// - Throws: The error of the directory creation or of the write.
        func makeProjectStoreUnreadable() throws {
            let projectsDirectory = try home().projectsDirectory
            try FileManager.default.createDirectory(
                at: projectsDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: projectsDirectory)
        }
    }

    // MARK: - Helpers

    /// Parses `arguments` as a `snapshots list` command.
    ///
    /// - Parameter arguments: The arguments after `snapshots list`.
    /// - Returns: The command.
    /// - Throws: The parse error, or a failed requirement for another command.
    private static func parseList(_ arguments: [String] = []) throws -> AcpAgentCommand.Snapshots.List {
        try #require(try AcpAgentCommand.parseAsRoot(["snapshots", "list"] + arguments) as? AcpAgentCommand.Snapshots.List)
    }

    /// Parses `arguments` as a `snapshots remove` command.
    ///
    /// - Parameter arguments: The arguments after `snapshots remove`.
    /// - Returns: The command.
    /// - Throws: The parse error, or a failed requirement for another command.
    private static func parseRemove(_ arguments: [String]) throws -> AcpAgentCommand.Snapshots.Remove {
        try #require(
            try AcpAgentCommand.parseAsRoot(["snapshots", "remove"] + arguments) as? AcpAgentCommand.Snapshots.Remove)
    }

    /// The exit outcome of a parse of `arguments`.
    ///
    /// - Parameter arguments: The arguments of the command line.
    /// - Returns: The outcome of the parse error, or `nil` when the parse
    ///   succeeds.
    private static func parseFailure(_ arguments: [String]) -> AcpAgentCommand.ExitOutcome? {
        do {
            _ = try AcpAgentCommand.parseAsRoot(arguments)
            return nil
        } catch {
            return AcpAgentCommand.exitOutcome(for: error)
        }
    }

    // MARK: - The usage errors

    /// `remove` with no key and no `--unrecorded` is a usage error, and the
    /// parse fails before the command can remove a folder.
    @Test
    func aRemoveWithNoArgumentIsAUsageError() {
        #expect(Self.parseFailure(["snapshots", "remove"]) == AcpAgentCommand.ExitOutcome(.usage))
    }

    /// `remove` with keys and `--unrecorded` is a usage error: the two
    /// selections are alternatives.
    @Test
    func aRemoveWithKeysAndTheUnrecordedFlagIsAUsageError() {
        #expect(
            Self.parseFailure(["snapshots", "remove", Self.sessionKey, "--unrecorded"])
                == AcpAgentCommand.ExitOutcome(.usage))
    }

    // MARK: - The listing

    /// `list` writes one line for each key, with the key first and the
    /// recorded state, and nothing to stderr.
    @Test
    func theListWritesOneLineForEachKey() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-list")

        let report = try await Self.parseList().report(environment: fixture.environment)

        let lines = report.standardOutput.split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.hasPrefix(Self.sessionKey))
        #expect(line.contains(Self.unrecordedText))
        #expect(report.standardErrorLines.isEmpty)
    }

    /// `list --json` writes the same entries as the inventory, as one JSON
    /// array.
    @Test
    func theListWithJSONWritesTheEntriesOfTheInventory() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-json")

        let report = try await Self.parseList(["--json"]).report(environment: fixture.environment)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([SnapshotInventoryEntry].self, from: Data(report.standardOutput.utf8))
        let listing = try await AcpAgentCommand.Snapshots.makeInventory(environment: fixture.environment).list()
        #expect(entries == listing.entries)
        #expect(entries.map(\.recordedState) == [.unrecorded])
    }

    // MARK: - The removal

    /// `remove <key>` removes the shadow folder of the key, writes the key to
    /// stdout and exits 0.
    @Test
    func aRemoveOfAKeyRemovesItsFolderAndWritesTheKey() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-remove")

        let outcome = try await Self.parseRemove([Self.sessionKey]).outcome(environment: fixture.environment)

        #expect(outcome.report.standardOutput == Self.sessionKey + "\n")
        #expect(outcome.report.standardErrorLines.isEmpty)
        #expect(outcome.exitCode == .success)
        #expect(try !fixture.hasShadowFolder(of: Self.sessionKey))
    }

    /// A mistyped key has no snapshot folder: it is not on stdout, stderr
    /// names it with "no snapshot folder", the command continues with the
    /// next key, and the exit status is 1.
    @Test
    func aMistypedKeyGoesToStderrAndTheNextKeyIsRemoved() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-mistyped")

        let outcome = try await Self.parseRemove([Self.mistypedKey, Self.sessionKey])
            .outcome(environment: fixture.environment)

        #expect(outcome.report.standardOutput == Self.sessionKey + "\n")
        #expect(!outcome.report.standardOutput.contains(Self.mistypedKey))
        #expect(outcome.report.standardErrorLines == ["\(Self.mistypedKey): \(Self.noSnapshotFolderText)"])
        #expect(outcome.exitCode == .error)
        #expect(try !fixture.hasShadowFolder(of: Self.sessionKey))
    }

    /// A remove that the file system refuses goes to stderr with the key and
    /// the case of the error, the key is not on stdout, and the exit status
    /// is 1.
    @Test
    func aRefusedRemoveGoesToStderrWithTheErrorCase() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-refused")
        let snapshotDirectory = try fixture.shadowFolder(of: Self.sessionKey).deletingLastPathComponent()
        try setPermissions(Self.readOnlyPermissions, of: snapshotDirectory)
        defer {
            #expect(throws: Never.self) { try setPermissions(ownerOnlyPermissions, of: snapshotDirectory) }
        }

        let outcome = try await Self.parseRemove([Self.sessionKey]).outcome(environment: fixture.environment)

        #expect(outcome.report.standardOutput.isEmpty)
        #expect(outcome.report.standardErrorLines.count == 1)
        let errorLine = try #require(outcome.report.standardErrorLines.first)
        #expect(errorLine.contains(Self.sessionKey))
        #expect(errorLine.contains(ACPAgentTelemetry.errorCaseName(of: CocoaError(.fileWriteNoPermission))))
        #expect(outcome.exitCode == .error)
        #expect(try fixture.hasShadowFolder(of: Self.sessionKey))
    }

    /// `remove --unrecorded` removes each key that no recording root has,
    /// and writes each removed key.
    @Test
    func aRemoveOfTheUnrecordedKeysRemovesThem() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-unrecorded")

        let outcome = try await Self.parseRemove(["--unrecorded"]).outcome(environment: fixture.environment)

        #expect(outcome.report.standardOutput == Self.sessionKey + "\n")
        #expect(outcome.exitCode == .success)
        #expect(try !fixture.hasShadowFolder(of: Self.sessionKey))
    }

    /// When the project store cannot be read, the recorded state is not
    /// known: `remove --unrecorded` removes nothing, writes the warning of
    /// the project store to stderr, and the exit status is not zero.
    @Test
    func aRemoveOfTheUnrecordedKeysRemovesNothingWhenTheRecordedStateIsUnknown() async throws {
        let fixture = try Fixture(label: "SnapshotsCommandTests-unknown")
        try fixture.makeProjectStoreUnreadable()

        let outcome = try await Self.parseRemove(["--unrecorded"]).outcome(environment: fixture.environment)

        #expect(outcome.report.standardOutput.isEmpty)
        #expect(outcome.report.standardErrorLines.contains { $0.contains(Self.projectStoreWarningOpening) })
        #expect(outcome.exitCode == .error)
        #expect(try fixture.hasShadowFolder(of: Self.sessionKey))
    }
}
