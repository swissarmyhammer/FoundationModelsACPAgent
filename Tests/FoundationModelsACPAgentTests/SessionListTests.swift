import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `session/list` wire surface, driven from the client
/// end of the harness: the `SessionInfo` join, the `cwd` filter, the
/// opaque cursor walk, the invalid-cursor refusal, and the listability
/// rules as a client observes them.
@Suite(.closesHarnesses) struct SessionListTests {
    /// The instant the dated session records count from.
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// The RFC 3339 form of ``baseDate``, which pins the wire format of
    /// `updatedAt`.
    private static let baseDateRFC3339 = "2023-11-14T22:13:20Z"

    /// The RFC 3339 form of ``baseDate`` plus one ``dateStep``.
    private static let steppedDateRFC3339 = "2023-11-14T22:14:20Z"

    /// The gap between two dated session records, in seconds.
    private static let dateStep: TimeInterval = 60

    /// The session count a three-page walk needs: two full pages and one
    /// final record.
    private static let threePageSessionCount = 2 * TranscriptStore.maximumPageSize + 1

    /// The page count a cursor walk must not go past. A walk that makes
    /// more pages than this has a cursor defect, and the bound keeps the
    /// test from a loop that does not stop.
    private static let maximumWalkPages = 10

    /// A `cwd` filter string that is not absolute, so the agent must
    /// refuse it.
    private static let relativeCwd = "relative/project"

    // MARK: - Harness

    /// One wire fixture: an initialized recording harness whose agent
    /// reads the injected user directory, so no test touches the real
    /// home directory.
    private struct WireFixture {
        /// The connected harness.
        let harness: AgentClientHarness

        /// The injected user layer root, the synced root of the home of
        /// the agent.
        let userDirectory: URL

        /// The validated dotfolder name the agent runs under.
        let name: DotfolderName

        /// The client side of the wire.
        var connection: ClientSideConnection { harness.connection }

        /// The projects folder of the home of the agent: one file for each
        /// project, which the cross-project listing reads.
        var projectsDirectory: URL { harness.agent.home.projectsDirectory }

        /// Closes both ends of the wire.
        func close() async { await harness.close() }
    }

    /// Wires a fresh initialized harness over an injected user directory.
    ///
    /// - Returns: The fixture.
    /// - Throws: Whatever agent construction or `initialize` throws.
    private static func makeWireFixture() async throws -> WireFixture {
        let userDirectory = makeResolvedDirectory(label: "SessionListTests-user")
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "SessionListTests-agent-cache"),
            userDirectory: userDirectory)
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        return WireFixture(
            harness: harness,
            userDirectory: userDirectory,
            name: try DotfolderName(AgentClientHarness.dotfolderName))
    }

    /// Makes one registered project with a project-local recording root.
    ///
    /// - Parameters:
    ///   - fixture: The wire fixture whose project store gains the project.
    ///   - label: The suffix that names the project's directories.
    /// - Returns: The recorded-project fixture.
    /// - Throws: Whatever registration or profile resolution throws.
    private static func makeProject(
        in fixture: WireFixture, label: String
    ) async throws -> RecordedProjectFixture {
        let workingDirectory = makeResolvedDirectory(label: "SessionListTests-\(label)")
        try ProjectStore(directory: fixture.projectsDirectory).register(workingDirectory: workingDirectory)
        return try await makeRecordedProjectFixture(
            workingDirectory: workingDirectory,
            cacheDirectory: makeResolvedDirectory(label: "SessionListTests-\(label)-cache"),
            recordingRoot: TranscriptLocation.project.recordingRoot(
                workingDirectory: workingDirectory,
                name: fixture.name,
                userDirectory: fixture.userDirectory))
    }

    /// The record date `position` steps after ``baseDate``.
    private static func steppedDate(_ position: Int) -> Date {
        Self.baseDate.addingTimeInterval(Double(position) * Self.dateStep)
    }

    /// Builds a `session/list` request from test inputs.
    ///
    /// - Parameters:
    ///   - cwd: The project filter, or `nil` for the cross-project list.
    ///   - cursor: The raw cursor token, or `nil` for the first page.
    /// - Returns: The request.
    private static func listRequest(
        cwd: URL? = nil, cursor: String? = nil
    ) -> ListSessionsRequest {
        ListSessionsRequest(
            cursor: cursor.map(SessionListCursor.init(rawValue:)),
            cwd: cwd.map { AbsolutePath(rawValue: $0.path) })
    }

    /// Walks the whole unfiltered paged listing from the client end.
    ///
    /// - Parameter connection: The client side of the wire.
    /// - Returns: One `SessionInfo` array per fetched page, in fetch
    ///   order.
    /// - Throws: Whatever `session/list` throws.
    private static func walkPages(
        over connection: ClientSideConnection
    ) async throws -> [[SessionInfo]] {
        var pages: [[SessionInfo]] = []
        var cursor: SessionListCursor?
        repeat {
            let response = try await connection.listSessions(ListSessionsRequest(cursor: cursor))
            pages.append(response.sessions)
            cursor = response.nextCursor
        } while cursor != nil && pages.count < Self.maximumWalkPages
        return pages
    }

    // MARK: - The SessionInfo join

    @Test
    func cwdFilteredListReportsTheJoinedSessionInfoFields() async throws {
        let fixture = try await Self.makeWireFixture()
        let project = try await Self.makeProject(in: fixture, label: "fields")
        let first = try await project.makeRecordedSession(title: "first prompt", updatedAt: Self.baseDate)
        let second = try await project.makeRecordedSession(
            title: "second prompt",
            additionalDirectories: [URL(filePath: "/extra/a"), URL(filePath: "/extra/b")],
            updatedAt: Self.steppedDate(1))

        let response = try await fixture.connection.listSessions(
            Self.listRequest(cwd: project.workingDirectory))
        await fixture.close()

        #expect(response.sessions.map(\.sessionId.rawValue) == [second, first].map(\.description))
        #expect(response.nextCursor == nil)
        let expectedPath = project.workingDirectory.standardizedFileURL.path
        #expect(response.sessions.map(\.cwd.rawValue) == [expectedPath, expectedPath])
        #expect(response.sessions.map(\.title) == ["second prompt", "first prompt"])
        #expect(
            response.sessions.map(\.updatedAt)
                == [Self.steppedDateRFC3339, Self.baseDateRFC3339])
        #expect(
            response.sessions.first?.additionalDirectories?.map(\.rawValue)
                == ["/extra/a", "/extra/b"])
        #expect(response.sessions.last?.additionalDirectories?.isEmpty == true)
    }

    @Test
    func unknownCwdFilterGivesAnEmptySuccess() async throws {
        let fixture = try await Self.makeWireFixture()
        let absent = makeResolvedDirectory(label: "SessionListTests-known")
            .appendingPathComponent("absent", isDirectory: true)

        let response = try await fixture.connection.listSessions(Self.listRequest(cwd: absent))
        await fixture.close()

        #expect(response.sessions.isEmpty)
        #expect(response.nextCursor == nil)
    }

    // MARK: - The cursor on the wire

    @Test
    func invalidCursorGivesAnInvalidParamsError() async throws {
        let fixture = try await Self.makeWireFixture()
        let project = try await Self.makeProject(in: fixture, label: "cursor")
        _ = try await project.makeRecordedSession(title: "listed", updatedAt: Self.baseDate)

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue
        ) {
            _ = try await fixture.connection.listSessions(
                Self.listRequest(cwd: project.workingDirectory, cursor: "not-a-cursor"))
        }
        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue
        ) {
            _ = try await fixture.connection.listSessions(
                Self.listRequest(cursor: "not-a-cursor"))
        }
        await fixture.close()
    }

    // MARK: - The absolute-cwd filter

    /// A relative `cwd` filter is refused the same way `session/new` and
    /// `session/resume` refuse one, naming the field that failed and why.
    /// A relative filter would otherwise key the project read off the
    /// process working directory.
    @Test
    func aRelativeCwdFilterGivesAnInvalidParamsErrorNamingTheField() async throws {
        let fixture = try await Self.makeWireFixture()

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: SessionSetupTests.expectedRefusalData(naming: .cwd)
        ) {
            _ = try await fixture.connection.listSessions(
                ListSessionsRequest(cwd: AbsolutePath(rawValue: Self.relativeCwd)))
        }
        await fixture.close()
    }

    @Test
    func threePageWalkSeesEverySessionOnceAcrossTwoProjects() async throws {
        let fixture = try await Self.makeWireFixture()
        let projects = [
            try await Self.makeProject(in: fixture, label: "walk-one"),
            try await Self.makeProject(in: fixture, label: "walk-two"),
        ]
        var ids: [ULID] = []
        for position in 0..<Self.threePageSessionCount {
            let project = projects[position % projects.count]
            let id = try await project.makeRecordedSession(
                title: "session \(position)", updatedAt: Self.steppedDate(position))
            ids.append(id)
        }

        let pages = try await Self.walkPages(over: fixture.connection)
        await fixture.close()

        let flattened = pages.flatMap { $0 }.map(\.sessionId.rawValue)
        #expect(
            pages.map(\.count)
                == [TranscriptStore.maximumPageSize, TranscriptStore.maximumPageSize, 1])
        #expect(flattened == ids.reversed().map(\.description))
        #expect(Set(flattened).count == flattened.count)
    }

    // MARK: - The listability rules from the client end

    @Test
    func aClosedSessionListsAndADeletedOneDoesNot() async throws {
        let fixture = try await Self.makeWireFixture()
        let project = try await Self.makeProject(in: fixture, label: "deleted")
        // Every recorded fixture session is closed before the list, so
        // the kept row is the closed-session half of the rule.
        let kept = try await project.makeRecordedSession(title: "kept", updatedAt: Self.baseDate)
        let deleted = try await project.makeRecordedSession(title: "deleted", updatedAt: Self.steppedDate(1))
        try FileManager.default.removeItem(
            at: project.root.appendingPathComponent(deleted.description, isDirectory: true))

        let response = try await fixture.connection.listSessions(
            Self.listRequest(cwd: project.workingDirectory))
        await fixture.close()

        #expect(response.sessions.map(\.sessionId.rawValue) == [kept.description])
    }

    @Test
    func aForkDoesNotAppearBecauseItsParentIdIsSet() async throws {
        let fixture = try await Self.makeWireFixture()
        let project = try await Self.makeProject(in: fixture, label: "fork")
        let parent = project.profile.standard.makeSession(
            workingDirectory: project.workingDirectory, recordingRoot: project.root)
        _ = try await parent.respond(to: "parent prompt")
        let fork = try await parent.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork prompt")
        await fork.close()
        await parent.close()

        let response = try await fixture.connection.listSessions(
            Self.listRequest(cwd: project.workingDirectory))
        await fixture.close()

        let listed = response.sessions.map(\.sessionId.rawValue)
        #expect(listed == [parent.id.description])
        #expect(!listed.contains(fork.id.description))
    }

    @Test
    func aZeroPromptSessionFromSessionNewDoesNotList() async throws {
        let fixture = try await Self.makeWireFixture()
        let workingDirectory = makeResolvedDirectory(label: "SessionListTests-zero-prompt")
        _ = try await fixture.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workingDirectory.path)))

        let response = try await fixture.connection.listSessions(ListSessionsRequest())
        await fixture.close()

        #expect(response.sessions.isEmpty)
        #expect(response.nextCursor == nil)
    }

    // MARK: - The cross-project merge

    @Test
    func twoProjectsOverOneSharedRootListEachSessionOnce() async throws {
        let fixture = try await Self.makeWireFixture()
        let sharedRoot = makeResolvedDirectory(label: "SessionListTests-shared-root")
        let firstProject = makeResolvedDirectory(label: "SessionListTests-shared-one")
        let secondProject = makeResolvedDirectory(label: "SessionListTests-shared-two")
        for project in [firstProject, secondProject] {
            let dotfolder = project.appendingPathComponent(
                ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: dotfolder, withIntermediateDirectories: true)
            try "transcripts:\n  location: \(sharedRoot.path)\n".write(
                to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
                atomically: true,
                encoding: .utf8)
            try ProjectStore(directory: fixture.projectsDirectory).register(workingDirectory: project)
        }
        let recorder = try await makeRecordedProjectFixture(
            workingDirectory: firstProject,
            cacheDirectory: makeResolvedDirectory(label: "SessionListTests-shared-cache"),
            recordingRoot: sharedRoot)
        let firstSession = try await recorder.makeRecordedSession(
            title: "one", updatedAt: Self.baseDate, in: firstProject)
        let secondSession = try await recorder.makeRecordedSession(
            title: "two", updatedAt: Self.steppedDate(1), in: secondProject)

        let response = try await fixture.connection.listSessions(ListSessionsRequest())
        await fixture.close()

        #expect(
            response.sessions.map(\.sessionId.rawValue)
                == [secondSession, firstSession].map(\.description))
        #expect(
            response.sessions.map(\.cwd.rawValue)
                == [secondProject, firstProject].map { $0.standardizedFileURL.path })
    }
}
