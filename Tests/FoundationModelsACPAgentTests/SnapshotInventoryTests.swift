import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsHooks
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The inventory of the snapshot folders that `acp-agent snapshots` shows and
/// removes: each shadow folder of the `SnapshotStore`, its timeline summary,
/// and its recorded state. A key is recorded when the recording root of a
/// project of the project store holds a listable session folder of that id.
///
/// Each test uses a temporary hook data directory, a temporary custom home
/// and temporary git work trees. No test reads the home directory.
struct SnapshotInventoryTests {
    // MARK: - Constants

    /// The session key that no recording root has a session folder of.
    private static let unrecordedKey = "01M5DF0Q6S3V6J5G4XN6C7T1RB"

    /// A session key that has no shadow folder: a key that the user mistyped.
    private static let mistypedKey = "01M5DF0Q6S3V6J5G4XN6C7T1RX"

    /// The permissions of a directory that its owner can read and enter, but
    /// not write. A remove of an entry in it fails.
    private static let readOnlyPermissions = NSNumber(value: 0o500)

    /// The owner that opens each key to make its timeline.
    private static let timelineOwner = "SnapshotInventoryTests-owner"

    /// The branch of each git work tree.
    private static let branchName = "main"

    /// The file that each timeline checkpoint writes.
    private static let changedFileName = "changed.txt"

    /// The text that each timeline checkpoint writes.
    private static let changedFileText = "a changed file\n"

    /// The opening of the warning of a project store that cannot be read.
    private static let projectStoreWarningOpening = "The project store cannot be read"

    /// The number of checkpoints that ``makeTimeline(sessionKey:in:label:)``
    /// takes after the baseline.
    private static let checkpointsPerTimeline = 1

    // MARK: - The fixture

    /// A temporary hook data directory, a settings store over a temporary
    /// custom home, and one registered project whose recording root holds
    /// the session folder of ``recordedKey``.
    private struct Fixture {
        /// The hook data directory. The snapshots are in its `snapshot`
        /// folder.
        let dataDirectory: URL

        /// The settings store that the inventory reads the project store and
        /// the project settings from.
        let settingsStore: SettingsStore

        /// The working directory of the registered project.
        let project: URL

        /// The store of the snapshots of ``dataDirectory``.
        let snapshotStore: SnapshotStore

        /// The session key that the recording root of the project has: the
        /// id of a prompted Router session recorded there.
        let recordedKey: String

        /// Makes the directories, registers the project and records one
        /// prompted session, whose id is ``recordedKey``, under its
        /// recording root.
        ///
        /// - Parameter label: The prefix that names the calling test.
        /// - Throws: The error of the settings folders, of the project store
        ///   write or of the recorded session.
        init(label: String) async throws {
            let settingsFolders = try SettingsFoldersFixture.make(label: "\(label)-settings")
            dataDirectory = makeResolvedDirectory(label: "\(label)-data")
            settingsStore = SettingsStore(settingsFolders: settingsFolders, secretStore: InMemorySecretStore())
            project = makeResolvedDirectory(label: "\(label)-project")
            snapshotStore = SnapshotStore(directory: AgentHooks.snapshotDirectory(in: dataDirectory))
            try ProjectStore(directory: RegisteredRecordingRoots.projectsDirectory(of: settingsStore))
                .register(workingDirectory: project)
            let recorder = try await makeRecordedProjectFixture(
                workingDirectory: project,
                cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
                recordingRoot: try projectRecordingRoot(of: project, dotfolderName: settingsFolders.name.rawValue))
            recordedKey = try await recorder.makeRecordedSession(title: "a recorded session").description
        }

        /// The inventory over the fixture.
        var inventory: SnapshotInventory {
            SnapshotInventory(hooksDataDirectory: dataDirectory, settingsStore: settingsStore)
        }

        /// The projects folder of the home: the project store, one file for
        /// each project.
        var projectsDirectory: URL {
            RegisteredRecordingRoots.projectsDirectory(of: settingsStore)
        }
    }

    // MARK: - Helpers

    /// Makes the timeline of `sessionKey`: a git work tree, an open of the
    /// key, one changed file, one checkpoint, and a release.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key.
    ///   - store: The store that keeps the timeline.
    ///   - label: The directory label of the work tree.
    /// - Returns: The work tree.
    /// - Throws: The error of git, of the open, of the write or of the take,
    ///   or a failed requirement when the take makes no checkpoint.
    private static func makeTimeline(sessionKey: String, in store: SnapshotStore, label: String) async throws -> URL {
        let workTree = makeResolvedDirectory(label: label)
        try GitVerbSupport.makeRepository(in: workTree, branch: branchName)
        try await store.open(sessionKey: sessionKey, owner: timelineOwner, workingDirectory: workTree)
        try changedFileText.write(
            to: workTree.appendingPathComponent(changedFileName, isDirectory: false), atomically: true,
            encoding: .utf8)
        let checkpoint = try await store.take(sessionKey: sessionKey, owner: timelineOwner, trigger: .manual(label: nil))
        _ = try #require(checkpoint)
        await store.release(sessionKey: sessionKey, owner: timelineOwner)
        return workTree
    }

    /// Makes a shadow folder with no timeline for `sessionKey`.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key.
    ///   - dataDirectory: The hook data directory.
    /// - Throws: The error of the directory creation.
    private static func makeEmptyShadowFolder(sessionKey: String, in dataDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: AgentHooks.snapshotDirectory(in: dataDirectory).appendingPathComponent(sessionKey, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// The entry of `sessionKey` in `listing`.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key.
    ///   - listing: The listing of the inventory.
    /// - Returns: The entry.
    /// - Throws: A failed requirement when the listing has no such entry.
    private static func entry(
        of sessionKey: String, in listing: SnapshotInventoryListing
    ) throws -> SnapshotInventoryEntry {
        try #require(listing.entries.first { $0.sessionKey == sessionKey })
    }

    // MARK: - The listing

    /// Two keys with a timeline, one recorded in the recording root of a
    /// registered project and one not: the inventory reports both, each with
    /// its checkpoint count, its last checkpoint date, its working directory
    /// and the correct recorded state.
    @Test
    func theInventoryReportsEachKeyWithItsRecordedState() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-list")
        let recordedTree = try await Self.makeTimeline(
            sessionKey: fixture.recordedKey, in: fixture.snapshotStore, label: "SnapshotInventoryTests-list-recorded")
        _ = try await Self.makeTimeline(
            sessionKey: Self.unrecordedKey, in: fixture.snapshotStore, label: "SnapshotInventoryTests-list-unrecorded")

        let listing = try await fixture.inventory.list()

        #expect(listing.entries.map(\.sessionKey) == [fixture.recordedKey, Self.unrecordedKey].sorted())
        let recorded = try Self.entry(of: fixture.recordedKey, in: listing)
        #expect(recorded.recordedState == .recorded)
        #expect(recorded.checkpointCount == Self.checkpointsPerTimeline)
        #expect(recorded.lastCheckpointDate != nil)
        let workingDirectory = try #require(recorded.workingDirectory)
        #expect(
            URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
                == recordedTree.resolvingSymlinksInPath().path)
        #expect(try Self.entry(of: Self.unrecordedKey, in: listing).recordedState == .unrecorded)
        #expect(listing.warnings.isEmpty)
        #expect(listing.unrecordedKeys == [Self.unrecordedKey])
    }

    /// A shadow folder with no timeline is still listed, with no checkpoint
    /// count, no date and no working directory, so that the user can remove
    /// it. It gives no warning.
    @Test
    func aShadowFolderWithNoTimelineIsListedWithNoCount() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-empty")
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: fixture.dataDirectory)

        let listing = try await fixture.inventory.list()

        let entry = try Self.entry(of: Self.unrecordedKey, in: listing)
        #expect(entry.checkpointCount == nil)
        #expect(entry.lastCheckpointDate == nil)
        #expect(entry.workingDirectory == nil)
        #expect(entry.recordedState == .unrecorded)
        #expect(listing.warnings.isEmpty)
    }

    /// A project store that cannot be read makes the recorded state
    /// unknown: the listing has a warning, and it tells that the project
    /// store cannot be read and that the recorded state is not known, so
    /// that a remove of the unrecorded keys removes nothing.
    @Test
    func anUnreadableProjectStoreMakesTheRecordedStateUnknown() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-project-store")
        try FileManager.default.removeItem(at: fixture.projectsDirectory)
        try Data().write(to: fixture.projectsDirectory)
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: fixture.dataDirectory)

        let listing = try await fixture.inventory.list()

        #expect(!listing.isRecordedStateKnown)
        #expect(listing.warnings.count == 1)
        #expect(listing.warnings.allSatisfy { $0.makesRecordedStateUnknown })
        #expect(listing.warnings.allSatisfy { $0.description.hasPrefix(Self.projectStoreWarningOpening) })
    }

    // MARK: - The removal

    /// A remove of the unrecorded keys of the listing removes only the
    /// unrecorded key. The recorded key keeps its shadow folder.
    @Test
    func aRemoveOfTheUnrecordedKeysRemovesOnlyTheUnrecordedKey() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-unrecorded")
        _ = try await Self.makeTimeline(
            sessionKey: fixture.recordedKey, in: fixture.snapshotStore,
            label: "SnapshotInventoryTests-unrecorded-recorded")
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: fixture.dataDirectory)
        let inventory = fixture.inventory

        let outcomes = try await inventory.remove(sessionKeys: try await inventory.list().unrecordedKeys)

        #expect(outcomes == [.removed(sessionKey: Self.unrecordedKey)])
        #expect(try await fixture.snapshotStore.shadowSessionKeys() == [fixture.recordedKey])
    }

    /// A key with no snapshot folder, for example a mistyped key, is not
    /// removed and does not show as removed: it gets the outcome
    /// `noSnapshotFolder`, and the next key is removed.
    @Test
    func aKeyWithNoSnapshotFolderIsNotRemovedAndTheNextKeyIs() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-unknown")
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: fixture.dataDirectory)

        let outcomes = try await fixture.inventory.remove(sessionKeys: [Self.mistypedKey, Self.unrecordedKey])

        #expect(
            outcomes == [
                .noSnapshotFolder(sessionKey: Self.mistypedKey),
                .removed(sessionKey: Self.unrecordedKey),
            ])
        #expect(try await fixture.snapshotStore.shadowSessionKeys().isEmpty)
    }

    /// A remove that the file system refuses gives a failed outcome with the
    /// case of the error, and the shadow folder stays.
    @Test
    func aRefusedRemoveGivesAFailedOutcomeWithTheErrorCase() async throws {
        let fixture = try await Fixture(label: "SnapshotInventoryTests-refused")
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: fixture.dataDirectory)
        let snapshotDirectory = AgentHooks.snapshotDirectory(in: fixture.dataDirectory)
        try setPermissions(Self.readOnlyPermissions, of: snapshotDirectory)
        defer {
            #expect(throws: Never.self) { try setPermissions(ownerOnlyPermissions, of: snapshotDirectory) }
        }

        let outcomes = try await fixture.inventory.remove(sessionKeys: [Self.unrecordedKey])

        #expect(
            outcomes == [
                .failed(
                    sessionKey: Self.unrecordedKey,
                    errorCase: ACPAgentTelemetry.errorCaseName(of: CocoaError(.fileWriteNoPermission)))
            ])
        #expect(try await fixture.snapshotStore.shadowSessionKeys() == [Self.unrecordedKey])
    }

    // MARK: - The start of the agent

    /// The start of the agent keeps each snapshot folder: there is no sweep
    /// of the orphan folders at start, because another process can run the
    /// session of a folder.
    @Test
    func theStartOfTheAgentKeepsTheSnapshotFolders() async throws {
        let home = AgentHomeFixture.make(label: "SnapshotInventoryTests-start")
        try Self.makeEmptyShadowFolder(sessionKey: Self.unrecordedKey, in: home.hooksDirectory)

        _ = try await composeStubAgent(
            name: AgentClientHarness.dotfolderName, label: "SnapshotInventoryTests-start", home: home)

        let store = SnapshotStore(directory: AgentHooks.snapshotDirectory(in: home.hooksDirectory))
        #expect(try await store.shadowSessionKeys() == [Self.unrecordedKey])
    }
}
