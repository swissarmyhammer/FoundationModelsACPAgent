import Foundation
import FoundationModelsACPAgent
import Testing

/// The cross-project registry `projects.jsonl` (plan.md §4.5): one appended
/// record per new working directory, `lastSeen` updates on a revisit, and a
/// stale entry is skipped on read. Every test builds its own throwaway user
/// directory and project directories under a temp directory.
@Suite struct ProjectRegistryTests {
    /// A throwaway user layer root plus real project directories, so the
    /// stale-skip check can delete one.
    struct Fixture {
        /// The temp root that holds every other directory.
        let root: URL

        /// The injected user layer root the registry file lives in.
        let userDirectory: URL

        /// The registry under test.
        let registry: ProjectRegistry

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ProjectRegistryTests-\(UUID().uuidString)", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            registry = ProjectRegistry(directory: userDirectory)
            try! FileManager.default.createDirectory(
                at: userDirectory, withIntermediateDirectories: true)
        }

        /// Makes a real project directory named `name` and returns its URL.
        func makeProjectDirectory(named name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// The raw text of the registry file.
        func registryText() throws -> String {
            try String(
                contentsOf: userDirectory.appendingPathComponent(ProjectRegistry.registryFileName),
                encoding: .utf8)
        }
    }

    /// The instant of the first visit in each test.
    static let firstVisit = Date(timeIntervalSince1970: 1_756_000_000)

    /// A later instant, for the revisit tests.
    static let secondVisit = Date(timeIntervalSince1970: 1_756_100_000)

    /// A session start in a new working directory appends one record with
    /// equal `firstSeen` and `lastSeen`.
    @Test func newWorkingDirectoryAppendsOneRecord() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.path) == [project.path])
        #expect(records.map(\.firstSeen) == [Self.firstVisit])
        #expect(records.map(\.lastSeen) == [Self.firstVisit])
    }

    /// A revisit updates `lastSeen`, keeps `firstSeen`, and appends no
    /// second line for the same working directory.
    @Test func revisitUpdatesLastSeenWithoutASecondLine() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.secondVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.firstSeen) == [Self.firstVisit])
        #expect(records.map(\.lastSeen) == [Self.secondVisit])
        let lines = try fixture.registryText().split(separator: "\n")
        #expect(lines.count == 1)
    }

    /// Two different working directories give two records, in visit order.
    @Test func secondWorkingDirectoryAppendsASecondRecord() throws {
        let fixture = Fixture()
        let first = try fixture.makeProjectDirectory(named: "alpha")
        let second = try fixture.makeProjectDirectory(named: "beta")

        try fixture.registry.recordSessionStart(workingDirectory: first, at: Self.firstVisit)
        try fixture.registry.recordSessionStart(workingDirectory: second, at: Self.secondVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.path) == [first.path, second.path])
    }

    /// A record whose directory no longer exists is stale: the read skips
    /// it and keeps the live ones.
    @Test func staleEntryIsSkippedOnRead() throws {
        let fixture = Fixture()
        let kept = try fixture.makeProjectDirectory(named: "alpha")
        let removed = try fixture.makeProjectDirectory(named: "beta")
        try fixture.registry.recordSessionStart(workingDirectory: kept, at: Self.firstVisit)
        try fixture.registry.recordSessionStart(workingDirectory: removed, at: Self.secondVisit)
        try FileManager.default.removeItem(at: removed)

        let records = try fixture.registry.projects()

        #expect(records.map(\.path) == [kept.path])
    }

    /// A missing registry file reads as an empty list, not an error.
    @Test func missingRegistryFileReadsAsEmpty() throws {
        let fixture = Fixture()

        let records = try fixture.registry.projects()

        #expect(records.isEmpty)
    }
}
