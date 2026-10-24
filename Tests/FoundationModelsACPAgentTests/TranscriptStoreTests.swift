import Foundation
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The read side of the transcripts and of `session/list`: the session
/// records that `sessions(inProject:)` reads from the `index.md` of each
/// session folder, the sort-key cursor pagination, the roots-only and
/// prompted listability predicate, `allProjects()`, and
/// `transcript(for:inProject:)`.
///
/// Every fixture session is a real recorded session, driven through
/// `makeRecordedProjectFixture` — no shipped `TranscriptRecorder` is
/// reachable, and `TranscriptEvent` has no public init.
@Suite struct TranscriptStoreTests {
    /// The dotfolder name every fixture project uses.
    private static let agentName = "coding"

    /// The page size the pagination walks request.
    private static let pageSize = 2

    /// The instant the dated session records count from.
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// The gap between two dated session records, in seconds.
    private static let dateStep: TimeInterval = 60

    // MARK: - Harness

    /// The name of the projects folder under the user layer directory.
    private static let projectsFolderName = "projects"

    /// One project under test: the recorded project, the router cache
    /// directory, the user layer directory, and the store over them.
    private struct ProjectFixture {
        /// The recorded project: its working directory, recording root,
        /// recording profile and session directory.
        let recorded: RecordedProjectFixture

        /// The router cache directory.
        let cacheDirectory: URL

        /// The user layer directory; the projects folder of the store is
        /// under it.
        let userDirectory: URL

        /// The store under test.
        let store: TranscriptStore

        /// The project working directory.
        var workingDirectory: URL { recorded.workingDirectory }

        /// The resolved recording root of the project.
        var root: URL { recorded.root }

        /// The resolved profile whose sessions record.
        var profile: LanguageModelProfile { recorded.profile }

        /// The folder of the project store of the store under test.
        var projectsDirectory: URL { store.projectsDirectory }

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
        return ProjectFixture(
            recorded: try await makeRecordedProjectFixture(
                workingDirectory: workingDirectory, cacheDirectory: cacheDirectory, recordingRoot: root),
            cacheDirectory: cacheDirectory,
            userDirectory: userDirectory,
            store: TranscriptStore(
                location: .project, name: name, userDirectory: userDirectory,
                projectsDirectory: userDirectory.appendingPathComponent(projectsFolderName, isDirectory: true)))
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
            pages.append(page.records.map(\.sessionId.description))
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

    @Test("the listing reads the record of each session folder and sorts updatedAt-descending")
    func listingReadsRecordsAndSortsUpdatedAtDescending() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let extras = [URL(filePath: "/extra/a"), URL(filePath: "/extra/b")]
        let first = try await fixture.recorded.makeRecordedSession(
            title: "first", updatedAt: Self.steppedDate(0))
        let second = try await fixture.recorded.makeRecordedSession(
            title: "second", additionalDirectories: extras, updatedAt: Self.steppedDate(2))
        let third = try await fixture.recorded.makeRecordedSession(
            title: "third", updatedAt: Self.steppedDate(1))

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.sessionId) == [second, third, first])
        #expect(records.map(\.facts.title) == ["second", "third", "first"])
        #expect(records.first?.additionalDirectories.map(\.path) == ["/extra/a", "/extra/b"])
        #expect(
            records.allSatisfy {
                $0.workingDirectory.standardizedFileURL.path == fixture.workingDirectory.standardizedFileURL.path
            })
    }

    @Test("a record changed after the close lists with its new title and updatedAt")
    func recordChangedAfterTheCloseListsWithItsNewValues() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let id = try await fixture.recorded.makeRecordedSession(
            title: "stale", updatedAt: Self.steppedDate(0))
        try await fixture.recorded.directory.setTitle("fresh", of: id)
        try RecordedProjectFixture.setUpdatedAt(Self.steppedDate(1), ofSession: id, under: fixture.root)

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.facts.title) == ["fresh"])
        #expect(records.first?.updatedAt == Self.steppedDate(1))
    }

    @Test("a recorded session with no title still lists")
    func sessionWithNoTitleStillLists() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let id = try await fixture.recorded.makeRecordedSession()

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records.map(\.sessionId) == [id])
        #expect(records.first?.facts.title == nil)
        #expect(records.first?.additionalDirectories == [])
        #expect(
            records.first?.workingDirectory.standardizedFileURL.path
                == fixture.workingDirectory.standardizedFileURL.path)
    }

    @Test("the listing gives the record that Router's index.md holds")
    func listingGivesTheRecordRoutersIndexFileHolds() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.recorded.makeRecordedSession(
            title: "held by Router", additionalDirectories: [URL(filePath: "/extra/router")],
            updatedAt: Self.steppedDate(1))

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)

        #expect(records == (try RouterSessionDirectory.recordedSessions(in: fixture.root)))
    }

    // MARK: - The listability predicate

    /// A fork from a recorded fork tree is excluded: its folder is in the
    /// folder of its parent. See ``RecordedProjectFixture/makeRecordedFork(of:)``.
    @Test("a fork is excluded because its parentId is set")
    func forkIsExcludedBecauseItsParentIdIsSet() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let parent = try await fixture.recorded.makeRecordedSession(prompts: ["parent prompt"])
        let fork = try await fixture.recorded.makeRecordedFork(of: parent)

        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId.description)

        #expect(ids == [parent.description])
        #expect(!ids.contains(fork.description))
    }

    @Test("a zero-prompt session never wrote a transcript, so it does not list")
    func zeroPromptSessionDoesNotList() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let listed = try await fixture.recorded.makeRecordedSession()
        let idle = fixture.profile.standard.makeSession(
            workingDirectory: fixture.workingDirectory, recordingRoot: fixture.root)
        await idle.close()

        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId.description)

        #expect(ids == [listed.description])
        #expect(!ids.contains(idle.id.description))
    }

    /// The spawn half of the listability predicate: the Router stamps
    /// `agentSpawn` on the `session` event of a session made with
    /// `makeSession(agentSpawn:)`, and the predicate must exclude that
    /// session from the listing. Its events still carry `parentId == nil`,
    /// which proves the exclusion reads the spawn fact, not the parentage.
    /// The transcript itself stays readable — only the listing excludes it.
    @Test("an agent-spawned session is excluded from the listing through the spawn fact")
    func spawnedSessionIsExcludedFromTheListing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let parent = try await fixture.recorded.makeRecordedSession()
        let spawned = try await fixture.recorded.makeRecordedSession(
            agentSpawn: SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: "tool-call-1"))

        let events = try fixture.store.transcript(
            for: spawned, inProject: fixture.workingDirectory)
        let ids = try fixture.store.sessions(inProject: fixture.workingDirectory)
            .map(\.sessionId.description)

        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.parentId == nil })
        #expect(events.contains { $0.agentSpawn != nil })
        #expect(ids == [parent.description])
    }

    // MARK: - The cursor pagination

    @Test("a pagination walk keeps the sort order across page boundaries")
    func paginationWalkKeepsOrderAcrossPages() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        var ids: [ULID] = []
        for position in 0..<5 {
            let id = try await fixture.recorded.makeRecordedSession(
                title: "session \(position)", updatedAt: Self.steppedDate(position))
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
            let id = try await fixture.recorded.makeRecordedSession(
                title: "session \(position)", updatedAt: Self.steppedDate(position))
            ids.append(id)
        }
        let firstPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)

        let newestPosition = ids.count + 1
        _ = try await fixture.recorded.makeRecordedSession(
            title: "inserted", updatedAt: Self.steppedDate(newestPosition))
        let secondPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: Self.pageSize, cursor: cursor)

        #expect(firstPage.records.map(\.sessionId.description) == [ids[3], ids[2]].map(\.description))
        #expect(secondPage.records.map(\.sessionId.description) == [ids[1], ids[0]].map(\.description))
        #expect(secondPage.nextCursor == nil)
    }

    @Test("the sessionId breaks an updatedAt tie, across a page boundary too")
    func sessionIdBreaksAnUpdatedAtTie() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let first = try await fixture.recorded.makeRecordedSession(title: "first", updatedAt: Self.baseDate)
        let second = try await fixture.recorded.makeRecordedSession(title: "second", updatedAt: Self.baseDate)
        let expected = [max(first, second), min(first, second)].map(\.description)

        let records = try fixture.store.sessions(inProject: fixture.workingDirectory)
        #expect(records.map(\.sessionId.description) == expected)

        let firstPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: 1, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)
        let secondPage = try fixture.store.sessions(
            inProject: fixture.workingDirectory, limit: 1, cursor: cursor)
        #expect(firstPage.records.map(\.sessionId.description) == [expected[0]])
        #expect(secondPage.records.map(\.sessionId.description) == [expected[1]])
        #expect(secondPage.nextCursor == nil)
    }

    @Test("an invalid cursor gives an error")
    func invalidCursorGivesError() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.recorded.makeRecordedSession()
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
        let id = try await fixture.recorded.makeRecordedSession(
            prompts: ["first prompt", "second prompt"])
        _ = try await fixture.recorded.makeRecordedSession(prompts: ["other session"])

        let events = try fixture.store.transcript(for: id, inProject: fixture.workingDirectory)
        // Router also records the facts of each mail as `.mail` events
        // (mailbox.md, section 5, problem 10). They belong to the session,
        // but they are not the conversation.
        let conversation = events.filter { $0.kind != .mail }

        #expect(events.allSatisfy { $0.sessionId == id })
        #expect(events.contains { $0.kind == .mail })
        #expect(conversation.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(
            conversation.compactMap(\.text)
                == ["first prompt", "first prompt", "second prompt", "second prompt"])
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
    ///   - prompt: The one prompt text to send.
    /// - Returns: The recorded session's id.
    /// - Throws: Whatever profile resolution or the request throws.
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
            try fixture.store.sessions(inProject: fixture.workingDirectory).map(\.sessionId.description))
        let firstEvents = try fixture.store.transcript(
            for: firstRun, inProject: fixture.workingDirectory)
        let secondEvents = try fixture.store.transcript(
            for: secondRun, inProject: fixture.workingDirectory)

        #expect(ids == Set([firstRun, secondRun].map(\.description)))
        // The `.mail` events are the mail facts that Router records beside
        // the conversation (mailbox.md, section 5, problem 10).
        #expect(firstEvents.filter { $0.kind != .mail }.map(\.kind) == [.session, .prompt, .response])
        #expect(secondEvents.filter { $0.kind != .mail }.map(\.kind) == [.session, .prompt, .response])
        // Both recorder runs start `seq` at zero, so the merged stream holds
        // colliding sequence numbers and only `ts` keeps the groups apart.
        #expect(firstEvents.first?.seq == 0)
        #expect(secondEvents.first?.seq == 0)
    }

    // MARK: - The project store

    @Test("allProjects() lists the live projects of the project store and skips stale ones")
    func allProjectsSkipsStaleEntries() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let projects = ProjectStore(directory: fixture.projectsDirectory)
        try projects.register(workingDirectory: fixture.workingDirectory, at: Self.baseDate)
        let stale = try Self.makeTemporaryDirectory(label: "stale")
        try projects.register(workingDirectory: stale, at: Self.baseDate)
        try FileManager.default.removeItem(at: stale)

        let listed = try fixture.store.allProjects()

        #expect(listed.map(\.path) == [fixture.workingDirectory.standardizedFileURL.path])
    }

    @Test("allProjects() gives the project that Router's ProjectStore holds")
    func allProjectsGivesTheProjectRoutersProjectStoreHolds() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        try ProjectStore(directory: fixture.projectsDirectory)
            .register(workingDirectory: fixture.workingDirectory, at: Self.baseDate)

        let projects = try fixture.store.allProjects()

        #expect(
            projects == [
                ProjectRecord(
                    path: fixture.workingDirectory.standardizedFileURL.path,
                    firstSeen: Self.baseDate,
                    lastSeen: Self.baseDate)
            ])
    }
}
