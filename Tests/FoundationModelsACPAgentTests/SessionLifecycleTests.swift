import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Session lifecycle (plan.md §10): `session/close` runs the tree teardown
/// and keeps the transcript, and `session/delete` removes the transcript
/// directory and the index line for real. The suite drives the wire, and
/// checks the filesystem truth on disk and the spawned server process.
@Suite struct SessionLifecycleTests {
    // MARK: - Constants

    /// The prompt text of the active-turn cases.
    private static let promptText = "Run one long turn"

    /// The exit status `pgrep` reports when no process matches.
    private static let pgrepNoMatchStatus: Int32 = 1

    /// The exit status `pgrep` reports when at least one process matches.
    private static let pgrepMatchStatus: Int32 = 0

    /// The permission bits a copied server binary is set to, so the copy is
    /// executable whatever the source's bits were.
    private static let executablePermissions = 0o755

    // MARK: - Harness

    /// Wires the shared scripted fixture with this suite's directory label.
    ///
    /// - Parameter script: The steps the model plays on every turn.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        script: [ScriptedTurnStep]
    ) async throws -> ScriptedTurnFixture {
        try await ScriptedTurnFixture.make(script: script, label: "SessionLifecycleTests")
    }

    /// The prompt request with one text block and this suite's text.
    ///
    /// - Parameter sessionId: The session to prompt.
    /// - Returns: The request.
    private static func makePromptRequest(sessionId: SessionId) -> PromptRequest {
        ScriptedTurnFixture.makePromptRequest(sessionId: sessionId, text: promptText)
    }

    // MARK: - The unknown-id policy (plan.md §10.1)

    /// `session/close` on an unknown id answers `-32602` with the id in
    /// `data`, so a client bug is visible instead of a silent success.
    @Test(.timeLimit(.minutes(1)))
    func closeOfAnUnknownSessionIdAnswersInvalidParamsWithTheId() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        let bogus = SessionId(rawValue: syntheticSessionIdValue)

        do {
            _ = try await fixture.harness.connection.closeSession(
                CloseSessionRequest(sessionId: bogus))
            Issue.record("expected invalid params for the unknown id")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == bogus.rawValue)
        }

        await fixture.close()
    }

    /// A second close of the same known session answers `{}`: close is
    /// idempotent, so the session stays closed and no error goes out.
    @Test(.timeLimit(.minutes(1)))
    func aSecondCloseOfAKnownSessionAnswersEmpty() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))
        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.availability == .closed)
        await fixture.close()
    }

    // MARK: - Close during an active turn (plan.md §10.1)

    /// Closing a session during a scripted turn makes the collector see one
    /// `idle` with the `cancelled` stop reason — the close waited for the
    /// terminator before it answered — and the transcript directory survives
    /// on disk.
    @Test(.timeLimit(.minutes(1)))
    func closingDuringAnActiveTurnSendsIdleCancelledAndKeepsTheTranscript() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("working"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)
        let transcriptDirectory = try #require(
            await fixture.harness.agent.sessions[fixture.sessionId]?.transcriptDirectory)

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        let updates = await fixture.collector.updates
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        guard case .stateUpdate(.idle) = try #require(turnUpdates(in: updates).last).update else {
            Issue.record("expected idle(cancelled) as the last turn update, got \(updates)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: transcriptDirectory.path))
        await fixture.close()
    }

    // MARK: - The tree teardown (plan.md §10.1)

    /// After close, a `streamSessionEvents()` subscription taken before the
    /// close finishes: the session sweep finished every outstanding one.
    @Test(.timeLimit(.minutes(1)))
    func afterCloseAStreamSessionEventsSubscriptionFinishes() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let events = await session.streamSessionEvents()
        let drained = Task {
            for await _ in events {}
        }

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        await drained.value
        await fixture.close()
    }

    /// After close, a descendant the session adopted is closed too: its own
    /// `streamSessionEvents()` subscription finishes, so no orphan fork keeps
    /// a model gate.
    @Test(.timeLimit(.minutes(1)))
    func closingASessionClosesItsDescendants() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let fork = try await session.fork(workingDirectory: nil)
        await fixture.harness.agent.adoptDescendant(fork, of: fixture.sessionId)
        let forkEvents = await fork.streamSessionEvents()
        let drainedFork = Task {
            for await _ in forkEvents {}
        }

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        await drainedFork.value
        await fixture.close()
    }

    /// After close, no spawned stdio server process remains: the pool shut
    /// each subprocess down after the sweep. The server binary is copied to a
    /// unique path, so `pgrep` matches only this case's own process.
    @Test(.timeLimit(.minutes(2)))
    func afterCloseNoSpawnedStdioServerProcessRemains() async throws {
        let serverPath = try Self.copiedServerBinary()
        let fixture = try await ScriptedTurnFixture.make(
            script: [.endTurn],
            label: "SessionLifecycleTests-process",
            projectConfigYAML: Self.mcpConfigYAML(serverCommand: serverPath))
        #expect(try Self.serverProcessExists(matching: serverPath))

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        try await Self.waitForNoServerProcess(matching: serverPath)
        await fixture.close()
    }

    // MARK: - Resume after close (plan.md §10.1)

    /// After close, `session/resume` on that id still works: the transcript
    /// stayed on disk, so the session is resumable, and the resumed session
    /// is idle again.
    @Test(.timeLimit(.minutes(1)))
    func afterCloseResumeStillWorks() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionLifecycleTests-resume")
        let root = try resume.recordingRoot
        try await resume.runTurn("first")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        let transcriptDirectory = try #require(
            await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]?
                .transcriptDirectory)

        _ = try await resume.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: resume.fixture.sessionId))
        #expect(FileManager.default.fileExists(atPath: transcriptDirectory.path))

        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())
        #expect(
            await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]?.availability
                == .idle)
        await resume.fixture.close()
    }

    // MARK: - The real delete (plan.md §10.2)

    /// Delete removes the transcript directory and the index line, and a
    /// resume of the deleted session then fails: the absence does the work.
    @Test(.timeLimit(.minutes(1)))
    func deleteRemovesTheDirectoryAndTheIndexLineAndResumeThenFails() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionLifecycleTests-delete")
        let root = try resume.recordingRoot
        try await resume.runTurn("first")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        let transcriptDirectory = try #require(
            await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]?
                .transcriptDirectory)
        let index = SessionIndex(root: root)
        #expect(
            try index.read().records.contains { $0.sessionId == resume.fixture.sessionId.rawValue })

        _ = try await resume.fixture.harness.connection.deleteSession(
            DeleteSessionRequest(sessionId: resume.fixture.sessionId))

        #expect(!FileManager.default.fileExists(atPath: transcriptDirectory.path))
        #expect(
            try !index.read().records.contains {
                $0.sessionId == resume.fixture.sessionId.rawValue
            })
        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                try resume.makeResumeRequest())
            Issue.record("expected resume of a deleted session to fail")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
        }
        await resume.fixture.close()
    }

    /// Deleting an active session closes it first — the collector sees one
    /// `idle` with the `cancelled` stop reason — and then removes it from the
    /// table.
    @Test(.timeLimit(.minutes(1)))
    func deletingAnActiveSessionClosesItFirst() async throws {
        let fixture = try await Self.makeFixture(script: [.textDelta("working"), .hold])
        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(sessionId: fixture.sessionId))
        try await ScriptedTurnFixture.waitForRunning(fixture.collector)

        _ = try await fixture.harness.connection.deleteSession(
            DeleteSessionRequest(sessionId: fixture.sessionId))

        #expect(ScriptedTurnFixture.idleStopReason(in: await fixture.collector.updates) == .cancelled)
        #expect(await fixture.harness.agent.sessions[fixture.sessionId] == nil)
        await fixture.close()
    }

    /// Deleting an unknown sessionId succeeds silently: "nothing to remove"
    /// is not an error.
    @Test(.timeLimit(.minutes(1)))
    func deletingAnUnknownSessionIdSucceeds() async throws {
        let fixture = try await Self.makeFixture(script: [.endTurn])

        _ = try await fixture.harness.connection.deleteSession(
            DeleteSessionRequest(sessionId: SessionId(rawValue: syntheticSessionIdValue)))

        await fixture.close()
    }

    // MARK: - The spawned-server helpers

    /// Copies the `mcp-test-server` executable to a unique path, so a
    /// `pgrep -f` on that path matches only this case's own spawned process.
    ///
    /// - Returns: The absolute path of the copied executable.
    /// - Throws: The locator or the copy error.
    private static func copiedServerBinary() throws -> String {
        let source = try BuiltProductLocator.mcpTestServerURL()
        let directory = makeResolvedDirectory(label: "SessionLifecycleTests-server")
        let destination = directory.appendingPathComponent(
            "lifecycle-mcp-\(UUID().uuidString)", isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: executablePermissions], ofItemAtPath: destination.path)
        return destination.path
    }

    /// The project `config.yaml` that mounts one config-derived stdio MCP
    /// server over `serverCommand` in echo mode.
    ///
    /// - Parameter serverCommand: The absolute path of the server executable.
    /// - Returns: The YAML document.
    private static func mcpConfigYAML(serverCommand: String) -> String {
        """
        tools:
          mcp:
            - name: lifecycle
              command: \(serverCommand)
              args:
                - --mode
                - echo
        """
    }

    /// Whether a process whose command line holds `path` is running.
    ///
    /// - Parameter path: The full argument `pgrep -f` matches on.
    /// - Returns: `true` when at least one process matches.
    /// - Throws: The spawn error when `pgrep` cannot run.
    private static func serverProcessExists(matching path: String) throws -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", path]
        pgrep.standardOutput = Pipe()
        try pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == pgrepMatchStatus
    }

    /// Polls until no process whose command line holds `path` is running, or
    /// fails the case at the deadline.
    ///
    /// - Parameter path: The full argument `pgrep -f` matches on.
    /// - Throws: `CancellationError` when the test is cancelled, or the spawn
    ///   error when `pgrep` cannot run.
    private static func waitForNoServerProcess(matching path: String) async throws {
        for _ in 0..<ScriptedTurnFixture.maxPollAttempts {
            if try !serverProcessExists(matching: path) {
                return
            }
            try await Task.sleep(for: ScriptedTurnFixture.pollInterval)
        }
        Issue.record("a spawned mcp server process remains after close")
    }
}
