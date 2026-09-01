import Foundation
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The read side of plan.md §4.6 and §9: the record join of
/// `sessions(inProject:)`, the sort-key cursor pagination, the roots-only
/// and has-transcript listability predicate, `allProjects()`, and
/// `transcript(for:inProject:)`.
///
/// Every fixture session is a real recorded session, driven through
/// `makeRecordingStubProfile` — no shipped `TranscriptRecorder` is
/// reachable, and `TranscriptEvent` has no public init.
@Suite struct TranscriptStoreTests {
    /// The dotfolder name every fixture project uses.
    private static let agentName = "coding"

    /// The page size the pagination walks request.
    private static let pageSize = 2

    /// The instant the dated index records count from.
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// The gap between two dated index records, in seconds.
    private static let dateStep: TimeInterval = 60

    // MARK: - Harness

    /// One project under test: the working directory, the resolved
    /// recording root, a profile whose sessions record real events, and
    /// the store over them.
    private struct ProjectFixture {
        /// The project working directory.
        let workingDirectory: URL

        /// The router cache directory.
        let cacheDirectory: URL

        /// The user layer directory the store's registry lives in.
        let userDirectory: URL

        /// The resolved profile whose sessions record.
        let profile: LanguageModelProfile

        /// The store under test.
        let store: TranscriptStore

        /// The resolved recording root of the project.
        let root: URL

        /// The `sessions.jsonl` index of the root.
        let index: SessionIndex

        /// Removes every directory the fixture created.
        func cleanUp() {
            for directory in [workingDirectory, cacheDirectory, userDirectory] {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Makes a fresh throwaway directory and returns its URL.
    ///
    /// - Parameter label: The suffix that names the directory's role.
    /// - Returns: The created directory.
    /// - Throws: Whatever directory creation throws.
    private static func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptStoreTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Makes a project fixture over fresh directories and a recording
    /// profile.
    ///
    /// - Returns: The fixture. The caller cleans it up with
    ///   ``ProjectFixture/cleanUp()``.
    /// - Throws: Whatever directory creation or profile resolution throws.
    private static func makeFixture() async throws -> ProjectFixture {
        let workingDirectory = try makeTemporaryDirectory(label: "project")
        let cacheDirectory = try makeTemporaryDirectory(label: "cache")
        let userDirectory = try makeTemporaryDirectory(label: "user")
        let name = try DotfolderName(agentName)
        let root = TranscriptLocation.project.recordingRoot(
            workingDirectory: workingDirectory, name: name, userDirectory: userDirectory)
        let profile = try await makeRecordingStubProfile(
            cacheDirectory: cacheDirectory, recordingsDirectory: root)
        return ProjectFixture(
            workingDirectory: workingDirectory,
            cacheDirectory: cacheDirectory,
            userDirectory: userDirectory,
            profile: profile,
            store: TranscriptStore(location: .project, name: name, userDirectory: userDirectory),
            root: root,
            index: SessionIndex(root: root))
    }

    /// Drives one recorded root session with one turn per prompt and
    /// returns its id.
    ///
    /// - Parameters:
    ///   - fixture: The project the session records into.
    ///   - prompts: The turns to drive, in order.
    ///   - agentSpawn: The spawn context, or `nil` for a plain root.
    /// - Returns: The session's ULID — the name of its directory.
    /// - Throws: Whatever driving the session throws.
    private static func makeRecordedSession(
        in fixture: ProjectFixture,
        prompts: [String] = ["one turn"],
        agentSpawn: SessionSidecar.AgentSpawn? = nil
    ) async throws -> ULID {
        let session = fixture.profile.standard.makeSession(
            workingDirectory: fixture.workingDirectory,
            recordingRoot: fixture.root,
            agentSpawn: agentSpawn)
        for prompt in prompts {
            _ = try await session.respond(to: prompt)
        }
        await session.close()
        return session.id
    }

    /// Appends one index record naming `id` in the fixture's project.
    ///
    /// - Parameters:
    ///   - fixture: The project whose index gains the record.
    ///   - id: The session the record names.
    ///   - title: The record's title.
    ///   - updatedAt: The record's most-recent-activity instant.
    ///   - additionalDirectories: The record's ordered directory list.
    /// - Throws: Whatever the index append throws.
    private static func appendRecord(
        in fixture: ProjectFixture,
        id: ULID,
        title: String,
        updatedAt: Date,
        additionalDirectories: [String] = []
    ) throws {
        try fixture.index.append(
            SessionIndexRecord(
                sessionId: id.description,
                cwd: fixture.workingDirectory.standardizedFileURL.path,
                title: title,
                updatedAt: updatedAt,
                additionalDirectories: additionalDirectories))
    }

    /// The record date `position` steps after ``baseDate``.
    private static func steppedDate(_ position: Int) -> Date {
        Self.baseDate.addingTimeInterval(Double(position) * Self.dateStep)
    }

    /// Walks the whole paged listing and returns each page's session ids.
    ///
    /// - Parameter fixture: The project to walk.
    /// - Returns: One id array per fetched page, in fetch order.
    /// - Throws: Whatever the paged listing throws.
    private static func walkPages(in fixture: ProjectFixture) throws -> [[String]] {
        var pages: [[String]] = []
        var cursor: String?
        repeat {
            let page = try fixture.store.sessions(
                inProject: fixture.workingDirectory, limit: pageSize, cursor: cursor)
            pages.append(page.records.map(\.sessionId))
            cursor = page.nextCursor
        } while cursor != nil
        return pages
    }

    // MARK: - The plain listing and the record join

    @Test("an unknown project directory gives an empty list, not an error")
    func unknownProjectDirectoryGivesEmptyList() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let unknown = fixture.workingDirectory.appendingPathComponent("absent", isDirectory: true)

        #expect(try fixture.store.sessions(inProject: unknown).isEmpty)
        let page = try fixture.store.sessions(inProject: unknown, limit: Self.pageSize, cursor: nil)
        #expect(page.records.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("the listing joins the index records and sorts updatedAt-descending")
    func listingJoinsRecordsAndSortsUpdatedAtDescending() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let first = try await Self.makeRecordedSession(in: fixture)
        let second = try await Self.makeRecordedSession(in: fixture)
        let third = try await Self.makeRecordedSession(in: fixture)
        try Self.appendRecord(in: fixture, id: first, title: "first", updatedAt: Self.steppedDate(0))
        try Self.appendRecord(
            in: fixture, id: second, title: "second", updatedAt: Self.steppedDate(2),
            additionalDirectories: ["/extra/a", "/extra/b"])
        try Self.appendRecord(in: fixture, id: third, title: "third", updatedAt: Self.steppedDate(1))

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.sessionId) == [second, third, first].map(\.description))
        #expect(records.map(\.title) == ["second", "third", "first"])
        #expect(records.first?.additionalDirectories == ["/extra/a", "/extra/b"])
        #expect(records.allSatisfy { $0.cwd == fixture.workingDirectory.standardizedFileURL.path })
    }

    @Test("a later index record for the same session wins the join")
    func laterIndexRecordWinsTheJoin() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let id = try await Self.makeRecordedSession(in: fixture)
        try Self.appendRecord(in: fixture, id: id, title: "stale", updatedAt: Self.steppedDate(0))
        try Self.appendRecord(in: fixture, id: id, title: "fresh", updatedAt: Self.steppedDate(1))

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.title) == ["fresh"])
        #expect(records.first?.updatedAt == Self.steppedDate(1))
    }

    @Test("a recorded session with no index line still lists, from the scan")
    func sessionWithoutIndexLineStillListsFromScan() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let id = try await Self.makeRecordedSession(in: fixture)

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.sessionId) == [id.description])
        #expect(records.first?.title == "")
        #expect(records.first?.additionalDirectories == [])
        #expect(records.first?.cwd == fixture.workingDirectory.standardizedFileURL.path)
    }

    // MARK: - The listability predicate

    @Test("a fork is excluded because its parentId is set")
    func forkIsExcludedBecauseItsParentIdIsSet() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let parent = fixture.profile.standard.makeSession(
            workingDirectory: fixture.workingDirectory, recordingRoot: fixture.root)
        _ = try await parent.respond(to: "parent turn")
        let fork = try await parent.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork turn")
        await fork.close()
        await parent.close()

        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId)

        #expect(ids == [parent.id.description])
        #expect(!ids.contains(fork.id.description))
    }

    @Test("a zero-turn session never wrote a transcript, so it does not list")
    func zeroTurnSessionDoesNotList() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let listed = try await Self.makeRecordedSession(in: fixture)
        let idle = fixture.profile.standard.makeSession(
            workingDirectory: fixture.workingDirectory, recordingRoot: fixture.root)
        await idle.close()

        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId)

        #expect(ids == [listed.description])
        #expect(!ids.contains(idle.id.description))
    }

    @Test("an index record with no session directory is excluded")
    func directoryLessIndexEntryIsExcluded() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let real = try await Self.makeRecordedSession(in: fixture)
        try Self.appendRecord(
            in: fixture, id: ULID.generate(), title: "ghost", updatedAt: Self.steppedDate(0))

        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId)

        #expect(ids == [real.description])
    }

    /// Pins the upstream gap this card's blocker comment records: with the
    /// pinned Router, `makeSession(agentSpawn:)` writes the spawn fact only
    /// into `session.json`, whose stored properties are all internal, and
    /// every recorded event of the spawned session carries `parentId == nil`.
    /// The public event stream therefore cannot separate an agent-spawned
    /// session from a plain root, and the spawned session still lists. The
    /// day the Router publishes a spawn fact through the events, this test
    /// fails — that is the signal to finish the exclusion in the predicate.
    @Test("an agent-spawned session is not separable from a root through the public event stream")
    func spawnedSessionStillListsBecauseEventsCarryNoSpawnFact() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let parent = try await Self.makeRecordedSession(in: fixture)
        let spawned = try await Self.makeRecordedSession(
            in: fixture,
            agentSpawn: SessionSidecar.AgentSpawn(
                parentSessionId: parent, parentToolCallId: "tool-call-1"))

        let events = try fixture.store.transcript(
            for: spawned, inProject: fixture.workingDirectory)
        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId)

        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.parentId == nil })
        #expect(ids.contains(spawned.description))
    }

    // MARK: - The cursor pagination

    @Test("a pagination walk keeps the sort order across page boundaries")
    func paginationWalkKeepsOrderAcrossPages() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        var ids: [ULID] = []
        for position in 0..<5 {
            let id = try await Self.makeRecordedSession(in: fixture)
            try Self.appendRecord(
                in: fixture, id: id, title: "session \(position)",
                updatedAt: Self.steppedDate(position))
            ids.append(id)
        }

        let pages = try Self.walkPages(in: fixture)

        let expected = ids.reversed().map(\.description)
        #expect(pages.flatMap { $0 } == expected)
        #expect(pages.allSatisfy { $0.count <= Self.pageSize })
    }

    @Test("adding a session between two fetches makes no duplicate and skips no existing entry")
    func insertionBetweenFetchesMakesNoDuplicateAndNoSkip() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        var ids: [ULID] = []
        for position in 0..<4 {
            let id = try await Self.makeRecordedSession(in: fixture)
            try Self.appendRecord(
                in: fixture, id: id, title: "session \(position)",
                updatedAt: Self.steppedDate(position))
            ids.append(id)
        }
        let firstPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)

        let inserted = try await Self.makeRecordedSession(in: fixture)
        let newestPosition = ids.count + 1
        try Self.appendRecord(
            in: fixture, id: inserted, title: "inserted",
            updatedAt: Self.steppedDate(newestPosition))
        let secondPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: cursor)

        #expect(firstPage.records.map(\.sessionId) == [ids[3], ids[2]].map(\.description))
        #expect(secondPage.records.map(\.sessionId) == [ids[1], ids[0]].map(\.description))
        #expect(secondPage.nextCursor == nil)
    }

    @Test("the sessionId breaks an updatedAt tie, across a page boundary too")
    func sessionIdBreaksAnUpdatedAtTie() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let first = try await Self.makeRecordedSession(in: fixture)
        let second = try await Self.makeRecordedSession(in: fixture)
        try Self.appendRecord(in: fixture, id: first, title: "first", updatedAt: Self.baseDate)
        try Self.appendRecord(in: fixture, id: second, title: "second", updatedAt: Self.baseDate)
        let expected = [max(first, second), min(first, second)].map(\.description)

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)
        #expect(records.map(\.sessionId) == expected)

        let firstPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: 1, cursor: nil)
        let secondPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: 1,
            cursor: try #require(firstPage.nextCursor))
        #expect(firstPage.records.map(\.sessionId) == [expected[0]])
        #expect(secondPage.records.map(\.sessionId) == [expected[1]])
        #expect(secondPage.nextCursor == nil)
    }

    @Test("an invalid cursor gives an error")
    func invalidCursorGivesError() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        _ = try await Self.makeRecordedSession(in: fixture)
        let garbled = "not-a-cursor"
        let wrongShape = Data("hello".utf8).base64EncodedString()

        #expect(throws: TranscriptStoreError.invalidCursor(garbled)) {
            _ = try fixture.store.sessions(
                inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: garbled)
        }
        #expect(throws: TranscriptStoreError.invalidCursor(wrongShape)) {
            _ = try fixture.store.sessions(
                inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: wrongShape)
        }
    }

    @Test("the page size is bounded on both sides")
    func pageSizeIsBoundedOnBothSides() {
        #expect(TranscriptStore.boundedPageSize(0) == 1)
        #expect(TranscriptStore.boundedPageSize(1) == 1)
        #expect(
            TranscriptStore.boundedPageSize(TranscriptStore.maximumPageSize + 1)
                == TranscriptStore.maximumPageSize)
    }

    // MARK: - The transcript read

    @Test("transcript(for:) returns the session's ordered events and nothing else")
    func transcriptReturnsOrderedEventsOfOneSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let id = try await Self.makeRecordedSession(
            in: fixture, prompts: ["first turn", "second turn"])
        _ = try await Self.makeRecordedSession(in: fixture, prompts: ["other session"])

        let events = try fixture.store.transcript(for: id, inProject: fixture.workingDirectory)

        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(events.compactMap(\.text) == ["first turn", "first turn", "second turn", "second turn"])
        #expect(events.allSatisfy { $0.sessionId == id })
        #expect(
            try fixture.store.transcript(
                for: ULID.generate(), inProject: fixture.workingDirectory
            ).isEmpty)
    }

    /// Drives one session in its own short-lived recorder run. The run's
    /// profile is released on return, which releases the recording-root
    /// claim, so the next run can record into the same root.
    ///
    /// - Parameters:
    ///   - fixture: The project the run records into.
    ///   - cacheDirectory: The run's own router cache directory.
    ///   - prompt: The one turn to drive.
    /// - Returns: The recorded session's id.
    /// - Throws: Whatever profile resolution or the turn throws.
    private static func driveSeparateRecorderRun(
        in fixture: ProjectFixture, cacheDirectory: URL, prompt: String
    ) async throws -> ULID {
        let profile = try await makeRecordingStubProfile(
            cacheDirectory: cacheDirectory, recordingsDirectory: fixture.root)
        let session = profile.standard.makeSession(
            workingDirectory: fixture.workingDirectory, recordingRoot: fixture.root)
        _ = try await session.respond(to: prompt)
        await session.close()
        return session.id
    }

    @Test("records from two separate recorder runs interleave correctly")
    func twoRecorderRunsInterleaveCorrectly() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let firstCache = try Self.makeTemporaryDirectory(label: "cache-run-one")
        defer { try? FileManager.default.removeItem(at: firstCache) }
        let secondCache = try Self.makeTemporaryDirectory(label: "cache-run-two")
        defer { try? FileManager.default.removeItem(at: secondCache) }
        let firstRun = try await Self.driveSeparateRecorderRun(
            in: fixture, cacheDirectory: firstCache, prompt: "first run")
        let secondRun = try await Self.driveSeparateRecorderRun(
            in: fixture, cacheDirectory: secondCache, prompt: "second run")

        let ids = Set(
            try fixture.store.sessions(inProject: fixture.workingDirectory).map(\.sessionId))
        let firstEvents = try fixture.store.transcript(
            for: firstRun, inProject: fixture.workingDirectory)
        let secondEvents = try fixture.store.transcript(
            for: secondRun, inProject: fixture.workingDirectory)

        #expect(ids == Set([firstRun, secondRun].map(\.description)))
        #expect(firstEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(secondEvents.map(\.kind) == [.session, .prompt, .response])
        // Both recorder runs start `seq` at zero, so the merged stream holds
        // colliding sequence numbers and only `ts` keeps the groups apart.
        #expect(firstEvents.first?.seq == 0)
        #expect(secondEvents.first?.seq == 0)
    }

    // MARK: - The project registry

    @Test("allProjects() lists the live registry entries and skips stale ones")
    func allProjectsSkipsStaleEntries() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let registry = ProjectRegistry(directory: fixture.userDirectory)
        try registry.recordSessionStart(
            workingDirectory: fixture.workingDirectory, at: Self.baseDate)
        let stale = try Self.makeTemporaryDirectory(label: "stale")
        try registry.recordSessionStart(workingDirectory: stale, at: Self.baseDate)
        try FileManager.default.removeItem(at: stale)

        let projects = try fixture.store.allProjects()

        #expect(projects.map(\.path) == [fixture.workingDirectory.standardizedFileURL.path])
    }
}
