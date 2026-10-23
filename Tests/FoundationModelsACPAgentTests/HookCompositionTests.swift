import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsHooks
import FoundationModelsRouter
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The hook composition of the agent: one `HookDispatcher` that Router sends
/// the hook events of each session to, one `SnapshotStore` that `SnapshotHook`
/// and the Multitool `snapshots` capability share, the lineage of a model-slot
/// switch, and the drain of the dispatcher when the connection ends.
///
/// The post events reach the visitors on a background queue. Thus each
/// assertion on a post event or on a snapshot comes after
/// `HookDispatcher.drain()`.
@Suite(.closesHarnesses) struct HookCompositionTests {
    // MARK: - Constants

    /// The file that the scripted tool call writes. The snapshot proof
    /// commits it first, so a rollback has content to put back.
    private static let noteFileName = "note.txt"

    /// The content of the note in the commit of the snapshot proof.
    private static let committedNoteContent = "the committed note\n"

    /// The content that the scripted tool call writes into the note.
    private static let writtenNoteContent = "the written note"

    /// The ignore rules of the git work tree of the snapshot proof. The
    /// session writes its transcripts under `<cwd>/.<name>/`. An ignored file
    /// is not in a snapshot tree, thus only the tool call changes the tree.
    private static let gitIgnoreContent = ".\(AgentClientHarness.dotfolderName)/\n"

    /// The branch of the git work tree of the snapshot proof.
    private static let branchName = "main"

    /// The marker of the prompt that writes the note.
    private static let writePromptText = "write the note now"

    /// The marker of the prompt that lists the snapshots.
    private static let listPromptText = "list the snapshots now"

    /// The marker of the prompt that rolls back to the baseline.
    private static let rollbackPromptText = "roll back to the baseline now"

    /// The label of the checkpoint count that the list snippet answers.
    private static let checkpointCountLabel = "checkpoints="

    /// The answer of the rollback snippet when the rollback restored the
    /// files.
    private static let rolledBackAnswer = "the rollback restored the files"

    /// The checkpoint index of the baseline: the work tree before the first
    /// checkpoint.
    private static let baselineIndex = 0

    /// The snippet that writes the note through the files capability.
    private static var writeCode: String {
        """
        const written = await tools.files.write({ path: "\(noteFileName)", content: "\(writtenNoteContent)" });
        return written.correction ? written.correction : "written";
        """
    }

    /// The snippet that lists the snapshots and answers their count.
    private static var listCode: String {
        """
        const listed = await tools.snapshots.list({});
        return listed.correction ? listed.correction : "\(checkpointCountLabel)" + listed.checkpoints.length;
        """
    }

    /// The snippet that rolls back to the baseline.
    private static var rollbackCode: String {
        """
        const rolledBack = await tools.snapshots.rollback({ index: \(baselineIndex) });
        return rolledBack.correction ? rolledBack.correction : "\(rolledBackAnswer)";
        """
    }

    // MARK: - The hooks folder of the home

    /// With no `XDG_DATA_HOME`, or with a relative one, the hooks folder of
    /// the XDG home is `~/.local/share/<name>/hooks`, as the XDG Base
    /// Directory specification tells. `AgentHomeTests` covers an absolute
    /// `XDG_DATA_HOME`.
    @Test(arguments: [[:], [AgentHome.dataHomeEnvironmentKey: "relative/data"]])
    func theHooksOfTheXDGHomeDefaultToTheLocalShareFolderOfTheHome(environment: [String: String]) throws {
        let directory = AgentHome.makeXDG(
            name: try DotfolderName(AgentClientHarness.dotfolderName), environment: environment
        ).hooksDirectory

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(directory.path == "\(home)/.local/share/\(AgentClientHarness.dotfolderName)/hooks")
    }

    /// A composition with the XDG home keeps the hook data in
    /// `$XDG_DATA_HOME/<name>/hooks`, the folder that the CLI always used.
    @Test
    func aCompositionWithTheXDGHomeKeepsTheHookDataInTheDataHome() async throws {
        let dataHome = makeResolvedDirectory(label: "HookCompositionTests-compose-data")
        let environment = [
            AgentHome.configHomeEnvironmentKey: makeResolvedDirectory(label: "HookCompositionTests-compose-config")
                .path,
            AgentHome.dataHomeEnvironmentKey: dataHome.path,
        ]
        let home = AgentHome.makeXDG(name: try DotfolderName(AgentClientHarness.dotfolderName), environment: environment)

        let composed = try await composeStubAgent(
            name: AgentClientHarness.dotfolderName, label: "HookCompositionTests-compose", home: home,
            environment: environment)

        #expect(
            composed.agent.hooks.dispatcher.dataDirectory.path
                == "\(dataHome.path)/\(AgentClientHarness.dotfolderName)/hooks")
    }

    /// The agent hooks keep the snapshots in the `snapshot` folder of the
    /// data directory, and the dispatcher has the data directory and a
    /// visitor: the `SnapshotHook`.
    @Test
    func theAgentHooksKeepTheSnapshotsUnderTheDataDirectory() {
        let dataDirectory = makeResolvedDirectory(label: "HookCompositionTests-data")

        let hooks = AgentHooks(dataDirectory: dataDirectory)

        #expect(hooks.dispatcher.dataDirectory == dataDirectory)
        #expect(!hooks.dispatcher.isEmpty)
        #expect(
            AgentHooks.snapshotDirectory(in: dataDirectory).path == dataDirectory.path + "/snapshot")
    }

    /// Two agents of one process on one data directory share one snapshot
    /// store, the store of the snapshot folder in the process, so their
    /// sessions share the open keys instead of racing on a timeline.
    @Test
    func twoAgentHooksOnOneDataDirectoryShareOneSnapshotStore() {
        let dataDirectory = makeResolvedDirectory(label: "HookCompositionTests-shared-store")

        let first = AgentHooks(dataDirectory: dataDirectory)
        let second = AgentHooks(dataDirectory: dataDirectory)

        #expect(first.snapshotStore === second.snapshotStore)
        #expect(first.snapshotStore === SnapshotStore.shared(directory: AgentHooks.snapshotDirectory(in: dataDirectory)))
    }

    // MARK: - The events of a session

    /// A new session with one prompt, whose tool call writes a file, and a
    /// close: a visitor that the host registers gets each event of the
    /// session, in order, and each event has the key of the working directory
    /// of the session as its key.
    @Test
    func aNewSessionSendsEachHookEventWithTheKeyOfItsWorkingDirectory() async throws {
        let recorder = RecordingHookVisitor()
        let fixture = try await ScriptedPromptFixture.make(
            loader: makeHookLayeredModelLoader(
                script: try ScriptedPromptFixture.makeToolPromptScript(code: Self.writeCode)),
            label: "HookCompositionTests-events", hookVisitors: [recorder])
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.writePromptText, count: 1)
        await fixture.close()
        await fixture.harness.agent.hooks.dispatcher.drain()

        let events = recorder.events.value
        #expect(
            RecordedHookEvent.firstOccurrences(of: events.map(\.kind)) == [
                .sessionStart(.new), .prePrompt, .preToolUse, .preToolResult, .postToolUse, .postPrompt,
                .sessionEnd,
            ])
        #expect(events.allSatisfy { $0.session.sessionKey == AgentHome.projectKey(of: fixture.cwd) })
    }

    /// A model-slot switch makes a replacement session in the same lineage:
    /// its `SessionStart` has the key of the session it replaces, the key of
    /// the working directory, and the origin `replacement`.
    @Test
    func aModelSlotSwitchStartsAReplacementWithTheSameKey() async throws {
        let recorder = RecordingHookVisitor()
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta("an answer"), .endPass], label: "HookCompositionTests-switch",
            hookVisitors: [recorder])

        _ = try await fixture.harness.connection.setSessionConfigOption(
            SetSessionConfigOptionRequest(
                configId: ConfigOptions.modelOptionId, sessionId: fixture.sessionId,
                value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))
        await fixture.harness.agent.hooks.dispatcher.drain()

        let starts = recorder.events.value.filter(\.isSessionStart)
        #expect(starts.map(\.kind) == [.sessionStart(.new), .sessionStart(.replacement)])
        #expect(starts.allSatisfy { $0.session.sessionKey == AgentHome.projectKey(of: fixture.cwd) })
        await fixture.close()
    }

    /// A resume restores the recorded session: a visitor that the host
    /// registers after the agent is made gets `SessionStart(.resumed)`, with
    /// the key of the working directory as its key, and the snapshot
    /// endpoints map the resumed session to that key, so it shares the one
    /// timeline of its folder.
    @Test
    func aResumedSessionStartsWithTheOriginResumedAndTheKeyOfItsWorkingDirectory() async throws {
        var resume = try await ResumeSessionFixture.make(label: "HookCompositionTests-resume")
        try await resume.runPrompt("one prompt before the resume")
        _ = try await resume.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: resume.fixture.sessionId))
        let recorder = RecordingHookVisitor()
        await resume.fixture.harness.agent.registerHookVisitors([recorder])

        _ = try await resume.fixture.harness.connection.resumeSession(resume.makeResumeRequest())
        await resume.fixture.harness.agent.hooks.dispatcher.drain()

        let starts = recorder.events.value.filter(\.isSessionStart)
        #expect(starts.map(\.kind) == [.sessionStart(.resumed)])
        let cwdKey = AgentHome.projectKey(of: resume.fixture.cwd)
        #expect(starts.allSatisfy { $0.session.sessionKey == cwdKey })
        #expect(SnapshotSessionKeys.shared.sessionKey(of: resume.fixture.sessionId.rawValue) == cwdKey)
        await resume.fixture.close()
    }

    // MARK: - The snapshots

    /// In a git work tree, a tool call that writes a file makes one
    /// checkpoint, which `tools.snapshots.list` of the session gives, and
    /// `tools.snapshots.rollback` to the baseline puts the committed content
    /// of the file back.
    @Test
    func aToolCallThatWritesAFileMakesOneCheckpointThatARollbackRestores() async throws {
        let fixture = try await Self.makeSnapshotFixture(
            script: try Self.makeSnapshotScript(), label: "HookCompositionTests-snapshots")
        let note = fixture.cwd.appendingPathComponent(Self.noteFileName, isDirectory: false)

        _ = try await Self.runTurn(Self.writePromptText, in: fixture)
        #expect(try String(contentsOf: note, encoding: .utf8) == Self.writtenNoteContent)
        let listed = try await Self.runTurn(Self.listPromptText, in: fixture)
        #expect(listed.toolCallText.contains("\(Self.checkpointCountLabel)1"))
        let rolledBack = try await Self.runTurn(Self.rollbackPromptText, in: fixture)
        #expect(rolledBack.toolCallText.contains(Self.rolledBackAnswer))
        #expect(try String(contentsOf: note, encoding: .utf8) == Self.committedNoteContent)
        await fixture.close()
    }

    /// The script of the snapshot proof: each of the three prompts runs its
    /// own snippet, and each other pass plays no output.
    ///
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    private static func makeSnapshotScript() throws -> [ScriptedPassStep] {
        let plays = [(writePromptText, writeCode), (listPromptText, listCode), (rollbackPromptText, rollbackCode)]
        return try plays.map { marker, code in
            .onPrompt(containing: marker, play: try ScriptedPromptFixture.makeToolPromptScript(code: code))
        } + [.endPass]
    }

    /// One turn of a snapshot proof: what the client got for one prompt.
    private struct SnapshotTurn {
        /// The stop reason of the idle update of the turn, or `nil` when the
        /// turn sent no idle update.
        let stopReason: StopReason?

        /// The text of the tool call updates of the turn.
        let toolCallText: String
    }

    /// Runs one prompt of a snapshot proof with
    /// ``ScriptedPromptFixture/runPrompt(on:text:count:whileRunning:)``, so
    /// the snapshot of the tool call of the prompt is complete, and reads
    /// the updates of this prompt. The prompt ends when the collector holds
    /// one more idle update than before the prompt.
    ///
    /// - Parameters:
    ///   - text: The prompt text, which holds the marker of one snippet.
    ///   - fixture: The wired fixture.
    ///   - sessionId: The session that gets the prompt, or `nil` for the
    ///     session of `fixture`.
    /// - Returns: The stop reason and the tool call text of this prompt.
    /// - Throws: Whatever the wire call or the waits throw.
    private static func runTurn(
        _ text: String, in fixture: ScriptedPromptFixture, sessionId: SessionId? = nil
    ) async throws -> SnapshotTurn {
        let updatesBefore = await fixture.collector.updates
        let run = try await ScriptedPromptFixture.runPrompt(
            AgentClientHarness.makePromptRequest(sessionId: sessionId ?? fixture.sessionId, text: text),
            through: fixture.harness, count: ScriptedPromptFixture.idleCount(in: updatesBefore) + 1)
        let turnUpdates = Array(run.updates.dropFirst(updatesBefore.count))
        return SnapshotTurn(
            stopReason: ScriptedPromptFixture.idleStopReason(in: turnUpdates),
            toolCallText: SkillsLibraryTests.toolCallText(in: turnUpdates))
    }

    /// Opens one more session over the wire of `fixture`, in `workingDirectory`.
    ///
    /// - Parameters:
    ///   - fixture: The wired fixture.
    ///   - workingDirectory: The working directory of the new session.
    /// - Returns: The id of the new session.
    /// - Throws: Whatever `session/new` throws.
    private static func openSession(on fixture: ScriptedPromptFixture, in workingDirectory: URL) async throws -> SessionId {
        let session = try await fixture.harness.client.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workingDirectory.path)))
        return await MainActor.run { session.sessionId }
    }

    // MARK: - The timeline of a working directory

    /// The `snapshots` endpoint query of the owner and the trigger of each
    /// checkpoint of the timeline of one session.
    private static let checkpointOwnersQuery =
        "query Owners($sessionId: ID!) { checkpoints(sessionId: $sessionId) { owner trigger } }"

    /// One checkpoint of a reply of ``checkpointOwnersQuery``.
    private struct OwnedCheckpoint: Decodable, Equatable {
        /// The session that made the checkpoint.
        let owner: String

        /// The trigger of the checkpoint, as the endpoint names it.
        let trigger: String
    }

    /// The reply of ``checkpointOwnersQuery``.
    private struct CheckpointOwnersReply: Decodable {
        /// The data of the reply.
        struct Payload: Decodable {
            /// The checkpoints, oldest first.
            let checkpoints: [OwnedCheckpoint]
        }

        /// The data of the reply.
        let data: Payload
    }

    /// Reads the owner and the trigger of each checkpoint of the timeline of
    /// `sessionId` from the `snapshots` endpoint of the agent of `fixture`.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose timeline the endpoint reads.
    ///   - fixture: The wired fixture.
    /// - Returns: The checkpoints, oldest first.
    /// - Throws: Whatever the endpoint or the decode throws.
    private static func ownedCheckpoints(
        of sessionId: SessionId, in fixture: ScriptedPromptFixture
    ) async throws -> [OwnedCheckpoint] {
        let reply = try await fixture.harness.agent.snapshotsEndpoint.execute(
            query: checkpointOwnersQuery, variables: ["sessionId": .string(sessionId.rawValue)],
            operationName: nil, viewer: nil)
        return try JSONDecoder().decode(CheckpointOwnersReply.self, from: Data(reply.utf8)).data.checkpoints
    }

    /// Two sessions in one working directory share one timeline: the
    /// checkpoint of a tool call of session A is in the list of session B,
    /// and the rollback of session A is in the timeline of session B, with A
    /// as its owner.
    @Test
    func twoSessionsInOneWorkingDirectoryShareOneTimeline() async throws {
        let fixture = try await Self.makeSnapshotFixture(
            script: try Self.makeSnapshotScript(), label: "HookCompositionTests-shared")
        let second = try await Self.openSession(on: fixture, in: fixture.cwd)

        _ = try await Self.runTurn(Self.writePromptText, in: fixture)
        let listed = try await Self.runTurn(Self.listPromptText, in: fixture, sessionId: second)
        _ = try await Self.runTurn(Self.rollbackPromptText, in: fixture)

        #expect(listed.toolCallText.contains("\(Self.checkpointCountLabel)1"))
        let checkpoints = try await Self.ownedCheckpoints(of: second, in: fixture)
        #expect(checkpoints.map(\.owner) == [fixture.sessionId.rawValue, fixture.sessionId.rawValue])
        #expect(checkpoints.last?.trigger == Self.rollbackTrigger)
        await fixture.close()
    }

    /// The trigger of the rollback checkpoint to the baseline in the
    /// `snapshots` endpoint.
    private static let rollbackTrigger = "rollback to \(baselineIndex)"

    /// Sessions in two working directories have two keys, and a session in a
    /// symbolic link to a working directory has the key of that directory.
    @Test
    func theKeyOfASessionIsTheKeyOfItsResolvedWorkingDirectory() async throws {
        let recorder = RecordingHookVisitor()
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta("an answer"), .endPass], label: "HookCompositionTests-two-folders",
            hookVisitors: [recorder])
        let otherFolder = makeResolvedDirectory(label: "HookCompositionTests-two-folders-other")
        let link = makeResolvedDirectory(label: "HookCompositionTests-two-folders-links")
            .appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.cwd)

        _ = try await Self.openSession(on: fixture, in: otherFolder)
        _ = try await Self.openSession(on: fixture, in: link)
        await fixture.harness.agent.hooks.dispatcher.drain()

        let keys = recorder.events.value.filter(\.isSessionStart).map(\.session.sessionKey)
        let folderKey = AgentHome.projectKey(of: fixture.cwd)
        #expect(keys == [folderKey, AgentHome.projectKey(of: otherFolder), folderKey])
        #expect(folderKey != AgentHome.projectKey(of: otherFolder))
        await fixture.close()
    }

    /// Makes the git work tree of a snapshot proof: a repository on
    /// ``branchName`` with a commit that ignores the dotfolder and a commit
    /// that adds the note.
    ///
    /// - Parameter label: The directory label of the work tree.
    /// - Returns: The work tree.
    /// - Throws: The error of a git command.
    private static func makeSnapshotWorkTree(label: String) throws -> URL {
        let cwd = makeResolvedDirectory(label: label)
        try GitVerbSupport.makeRepository(in: cwd, branch: branchName)
        try GitVerbSupport.commitFile(
            named: ".gitignore", text: gitIgnoreContent, message: "ignore the dotfolder", in: cwd)
        try GitVerbSupport.commitFile(
            named: noteFileName, text: committedNoteContent, message: "add the note", in: cwd)
        return cwd
    }

    /// Makes a fixture of a snapshot proof: a git work tree from
    /// ``makeSnapshotWorkTree(label:)`` with the label and `-repo`, and a
    /// session in it whose hook-layered model plays `script`.
    ///
    /// - Parameters:
    ///   - script: The script of the model of the session.
    ///   - label: The directory label of the calling test.
    /// - Returns: The fixture, with its session open.
    /// - Throws: Whatever the work tree or the fixture throws.
    private static func makeSnapshotFixture(
        script: [ScriptedPassStep], label: String
    ) async throws -> ScriptedPromptFixture {
        let cwd = try makeSnapshotWorkTree(label: "\(label)-repo")
        return try await ScriptedPromptFixture.make(
            loader: makeHookLayeredModelLoader(script: script), label: label, workingDirectory: cwd)
    }

    // MARK: - The removal of a timeline

    /// The owner ID of the second owner that opens the session key beside
    /// the session.
    private static let secondOwner = "HookCompositionTests-second-owner"

    /// The session key of the log record proof.
    private static let loggedSessionKey = "01M5D4G51WVGFCTAEQK67NKW5X"

    /// Makes a fixture in a git work tree, and runs one prompt whose tool
    /// call writes the note. Thus the session key has a shadow folder with a
    /// checkpoint.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The fixture, with its session open.
    /// - Throws: Whatever the work tree, the fixture or the prompt throws.
    private static func makeWrittenSnapshotFixture(label: String) async throws -> ScriptedPromptFixture {
        let fixture = try await makeSnapshotFixture(
            script: try ScriptedPromptFixture.makeToolPromptScript(code: writeCode), label: label)
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: writePromptText, count: 1)
        return fixture
    }

    /// `session/delete` of the only session of a working directory removes
    /// the shadow folder of the key of that directory after a turn that made
    /// a checkpoint.
    @Test
    func aSessionDeleteRemovesTheTimelineOfItsSessionKey() async throws {
        let fixture = try await Self.makeWrittenSnapshotFixture(label: "HookCompositionTests-delete")
        let store = fixture.harness.agent.hooks.snapshotStore
        let sessionKey = AgentHome.projectKey(of: fixture.cwd)
        #expect(!(try await store.checkpoints(sessionKey: sessionKey, owner: fixture.sessionId.rawValue)).isEmpty)
        #expect(try await store.shadowSessionKeys().contains(sessionKey))

        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: fixture.sessionId))

        #expect(!(try await store.shadowSessionKeys()).contains(sessionKey))
        await fixture.close()
    }

    /// When a second owner has the session key open, `session/delete`
    /// succeeds and the shadow folder of the key stays.
    @Test
    func aSessionDeleteKeepsTheTimelineThatASecondOwnerHasOpen() async throws {
        let fixture = try await Self.makeWrittenSnapshotFixture(label: "HookCompositionTests-delete-shared")
        let store = fixture.harness.agent.hooks.snapshotStore
        let sessionKey = AgentHome.projectKey(of: fixture.cwd)
        try await store.open(sessionKey: sessionKey, owner: Self.secondOwner, workingDirectory: fixture.cwd)

        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: fixture.sessionId))

        #expect(try await store.shadowSessionKeys().contains(sessionKey))
        await store.release(sessionKey: sessionKey, owner: Self.secondOwner)
        await fixture.close()
    }

    /// Two sessions in one working directory: the delete of one keeps the
    /// timeline of the directory while the other session is left, also when
    /// that session is closed, and the delete of the last one removes it.
    @Test
    func aSessionDeleteKeepsTheTimelineUntilTheLastSessionOfItsWorkingDirectory() async throws {
        let fixture = try await Self.makeWrittenSnapshotFixture(label: "HookCompositionTests-delete-last")
        let store = fixture.harness.agent.hooks.snapshotStore
        let sessionKey = AgentHome.projectKey(of: fixture.cwd)
        let second = try await Self.openSession(on: fixture, in: fixture.cwd)
        _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))

        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: second))
        let keptAfterTheFirstDelete = try await store.shadowSessionKeys().contains(sessionKey)
        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: fixture.sessionId))

        #expect(keptAfterTheFirstDelete)
        #expect(!(try await store.shadowSessionKeys()).contains(sessionKey))
        await fixture.close()
    }

    /// `session/close` keeps the shadow folder of the session key, so the
    /// timeline stays for a resume.
    @Test
    func aSessionCloseKeepsTheTimelineOfItsSessionKey() async throws {
        let fixture = try await Self.makeWrittenSnapshotFixture(label: "HookCompositionTests-close")
        let store = fixture.harness.agent.hooks.snapshotStore

        _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.harness.agent.hooks.dispatcher.drain()

        #expect(try await store.shadowSessionKeys().contains(AgentHome.projectKey(of: fixture.cwd)))
        await fixture.close()
    }

    /// The log record of a kept or failed timeline removal names only the
    /// session key and, for a failure, the case of the error without its
    /// payload.
    ///
    /// - Parameters:
    ///   - error: The error of the removal, or `nil` for a kept timeline.
    ///   - expectedCase: The error case that the record names, or `nil`.
    @Test(arguments: [
        (nil, nil),
        (SnapshotError.unavailable, "unavailable"),
        (SnapshotError.sessionKeyOpen, "sessionKeyOpen"),
        (SnapshotError.invalidCheckpoint(index: Self.baselineIndex), "invalidCheckpoint"),
    ] as [(SnapshotError?, String?)])
    func theLogOfATimelineRemovalNamesOnlyTheKeyAndTheErrorCase(
        error: SnapshotError?, expectedCase: String?
    ) {
        let metadata = ACPAgentTelemetry.snapshotKeyMetadata(Self.loggedSessionKey, error: error)

        var expected: Logger.Metadata = [
            ACPAgentTelemetry.LogMetadataKey.snapshotSessionKey: "\(Self.loggedSessionKey)"
        ]
        if let expectedCase {
            expected[ACPAgentTelemetry.LogMetadataKey.errorCase] = "\(expectedCase)"
        }
        #expect(metadata == expected)
    }

    // MARK: - A session with no snapshots

    /// The file that ``secondOwner`` writes before its checkpoint.
    private static let secondNoteFileName = "second-note.txt"

    /// The content that ``secondOwner`` writes into ``secondNoteFileName``.
    /// No log record and no span may hold it.
    private static let secondNoteContent = "the note of the second owner"

    /// The text before the cause in the Multitool correction of
    /// `tools.snapshots` for a session with no snapshots.
    private static let notAvailablePrefix = "Snapshots are not available for this session: "

    /// The text after the cause in the Multitool correction of
    /// `tools.snapshots` for a session with no snapshots.
    private static let stopCallingSnapshotsText = "Do not call tools.snapshots again in this session."

    /// The metadata key of the session key in a log record of `SnapshotHook`.
    private static let hookSessionKeyMetadataKey = "sessionKey"

    /// A resume in a work tree that is not the work tree of the timeline of
    /// the session key. The open of the `SessionStart` gets
    /// `workingDirectoryMismatch`. The turn ends normally, and
    /// `tools.snapshots.list` gives the correction with that cause, not a
    /// thrown error and not the checkpoint of the second owner of the key.
    @Test
    func aSessionWithAWorkingDirectoryMismatchEndsItsTurnWithNoSnapshots() async throws {
        try await TelemetryCapture.run(forbidding: [Self.secondNoteContent]) { context in
            let fixture = try await Self.makeSnapshotFixture(
                script: try Self.makeSnapshotScript(), label: "HookCompositionTests-mismatch")
            let store = fixture.harness.agent.hooks.snapshotStore
            let sessionKey = AgentHome.projectKey(of: fixture.cwd)
            _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))
            await fixture.harness.agent.hooks.dispatcher.drain()
            try await store.remove(sessionKey: sessionKey)
            let otherWorkTree = try Self.makeSnapshotWorkTree(label: "HookCompositionTests-mismatch-other-repo")
            try await Self.takeSecondOwnerCheckpoint(in: store, sessionKey: sessionKey, workTree: otherWorkTree)

            _ = try await fixture.harness.connection.resumeSession(
                ResumeSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: fixture.sessionId))
            let listed = try await Self.runTurn(Self.listPromptText, in: fixture)

            Self.expectNoSnapshots(in: listed, cause: .workingDirectoryMismatch)
            try Self.expectOneFailureRecord(
                in: context.logRecords, sessionKey: sessionKey, error: .workingDirectoryMismatch,
                workTrees: [fixture.cwd, otherWorkTree])
            await store.release(sessionKey: sessionKey, owner: Self.secondOwner)
            await fixture.close()
        }
    }

    /// A second `SnapshotStore` on the same snapshot folder moves the
    /// timeline ref of the session key after the `SessionStart` of the
    /// session. The next snapshot of the session gets `timelineConflict`.
    /// The turn of that snapshot ends normally, the next turn ends normally
    /// too, and `tools.snapshots.list` gives the correction with that cause,
    /// not a thrown error and not the checkpoints of the second store.
    @Test
    func aSessionWithATimelineConflictEndsItsTurnWithNoSnapshots() async throws {
        try await TelemetryCapture.run(forbidding: [Self.secondNoteContent]) { context in
            let fixture = try await Self.makeSnapshotFixture(
                script: try Self.makeSnapshotScript(), label: "HookCompositionTests-conflict")
            let sessionKey = AgentHome.projectKey(of: fixture.cwd)
            await fixture.harness.agent.hooks.dispatcher.drain()
            let secondStore = SnapshotStore(
                directory: AgentHooks.snapshotDirectory(in: fixture.harness.agent.hooks.dispatcher.dataDirectory))
            try await Self.takeSecondOwnerCheckpoint(in: secondStore, sessionKey: sessionKey, workTree: fixture.cwd)

            let written = try await Self.runTurn(Self.writePromptText, in: fixture)
            let listed = try await Self.runTurn(Self.listPromptText, in: fixture)

            #expect(written.stopReason == .endTurn)
            Self.expectNoSnapshots(in: listed, cause: .timelineConflict)
            try Self.expectOneFailureRecord(
                in: context.logRecords, sessionKey: sessionKey, error: .timelineConflict, workTrees: [fixture.cwd])
            await secondStore.release(sessionKey: sessionKey, owner: Self.secondOwner)
            await fixture.close()
        }
    }

    /// Opens `sessionKey` in `store` for ``secondOwner`` in `workTree`,
    /// writes ``secondNoteFileName`` there, and takes a checkpoint. Thus the
    /// key has a checkpoint that is not a checkpoint of the session.
    ///
    /// - Parameters:
    ///   - store: The store that opens the key.
    ///   - sessionKey: The session key.
    ///   - workTree: The git work tree of the second owner.
    /// - Throws: The error of the open, of the write or of the take, or a
    ///   failed requirement when the take makes no checkpoint.
    private static func takeSecondOwnerCheckpoint(
        in store: SnapshotStore, sessionKey: String, workTree: URL
    ) async throws {
        try await store.open(sessionKey: sessionKey, owner: secondOwner, workingDirectory: workTree)
        try secondNoteContent.write(
            to: workTree.appendingPathComponent(secondNoteFileName, isDirectory: false), atomically: true,
            encoding: .utf8)
        let checkpoint = try await store.take(sessionKey: sessionKey, owner: secondOwner, trigger: .manual(label: nil))
        _ = try #require(checkpoint)
    }

    /// Expects that `turn` ended normally, and that its `tools.snapshots.list`
    /// call gave the Multitool correction with `cause` and no checkpoint
    /// count.
    ///
    /// - Parameters:
    ///   - turn: The turn that listed the snapshots.
    ///   - cause: The cause that the correction names.
    ///   - sourceLocation: The source location that each issue names.
    private static func expectNoSnapshots(
        in turn: SnapshotTurn, cause: SnapshotUnavailableCause, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(turn.stopReason == .endTurn, sourceLocation: sourceLocation)
        let correction = "\(notAvailablePrefix)\(cause.rawValue). \(stopCallingSnapshotsText)"
        #expect(turn.toolCallText.contains(correction), sourceLocation: sourceLocation)
        #expect(!turn.toolCallText.contains(checkpointCountLabel), sourceLocation: sourceLocation)
    }

    /// Expects one error record of `SnapshotHook` for `sessionKey`. Its
    /// message ends with the case name of `error`, and its message and its
    /// metadata hold no path of `workTrees`.
    ///
    /// - Parameters:
    ///   - records: The log records of the capture.
    ///   - sessionKey: The session key that the record names.
    ///   - error: The error whose case the record names.
    ///   - workTrees: The work trees whose paths the record must not hold.
    ///   - sourceLocation: The source location that each issue names.
    /// - Throws: A failed requirement when the records hold no such record.
    private static func expectOneFailureRecord(
        in records: [TelemetryCapture.LogRecord], sessionKey: String, error: SnapshotError, workTrees: [URL],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let failures = records.filter { record in
            record.level == .error && record.metadata[hookSessionKeyMetadataKey] == .string(sessionKey)
        }
        #expect(failures.count == 1, sourceLocation: sourceLocation)
        let failure = try #require(failures.first, sourceLocation: sourceLocation)
        let message = failure.message.description
        #expect(message.hasSuffix(": \(ACPAgentTelemetry.errorCaseName(of: error))"), sourceLocation: sourceLocation)
        let texts = [message] + failure.metadata.values.map(\.description)
        let paths = workTrees.map(\.path)
        #expect(!texts.contains { text in paths.contains { text.contains($0) } }, sourceLocation: sourceLocation)
    }

    // MARK: - The end of the connection

    /// When the client goes away, the connection frees its session (ACPA-5d),
    /// and the host then closes each open session
    /// (``RoutedACPAgent/closeOpenSessions()``), which waits until the
    /// dispatcher delivered each post event. Thus the `SessionEnd` of a slow
    /// visitor is delivered before the close returns.
    @Test
    func theHostCloseReturnsAfterTheDispatcherDrained() async throws {
        let milestones = WatchedValue<[TeardownMilestone]>([])
        let gate = WatchedValue(false)
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta("an answer"), .endPass], label: "HookCompositionTests-teardown",
            hookVisitors: [GatedSessionEndVisitor(milestones: milestones, gate: gate)])
        let agent = fixture.harness.agent

        await ConnectionCloseTests.dropClientEnd(of: fixture.harness)
        let teardown = Task {
            await agent.waitForTeardown(of: fixture.harness.routedConnection.id)
            await agent.closeOpenSessions()
            milestones.update { $0.append(.teardownReturned) }
        }
        _ = try await milestones.wait(for: "the SessionEnd delivery started") {
            $0.contains(.sessionEndEntered)
        }
        gate.update { $0 = true }
        await teardown.value

        // No `fixture.close()`: the client end is gone, so a `session/close`
        // cannot go out. The suite trait closes the harness.
        #expect(milestones.value == [.sessionEndEntered, .sessionEndDelivered, .teardownReturned])
    }
}

// MARK: - The recording visitors

/// One hook event that a ``RecordingHookVisitor`` got.
struct RecordedHookEvent: Sendable, Equatable {
    /// The type of a hook event, with the origin of a `SessionStart`.
    enum Kind: Sendable, Equatable {
        /// A `SessionStart`, with its origin.
        case sessionStart(SessionOrigin)
        /// A `PrePrompt`.
        case prePrompt
        /// A `PreToolUse`.
        case preToolUse
        /// A `PreToolResult`.
        case preToolResult
        /// A `PostToolUse`.
        case postToolUse
        /// A `PostPrompt`.
        case postPrompt
        /// A `SessionEnd`.
        case sessionEnd
    }

    /// The type of the event.
    let kind: Kind

    /// The session of the event.
    let session: HookSession

    /// `true` when the event is a `SessionStart`.
    var isSessionStart: Bool {
        if case .sessionStart = kind { return true }
        return false
    }

    /// The kinds of `kinds` in the order of their first occurrence. A prompt
    /// can run more than one pass, and each pass can send the same kind
    /// again.
    ///
    /// - Parameter kinds: The kinds, in the order of delivery.
    /// - Returns: Each kind one time, in the order of its first occurrence.
    static func firstOccurrences(of kinds: [Kind]) -> [Kind] {
        kinds.enumerated().filter { index, kind in !kinds[..<index].contains(kind) }.map(\.element)
    }
}

/// A visitor that records each hook event that it gets, and changes nothing.
/// Each pre method gives the default `.proceed`.
struct RecordingHookVisitor: HookVisitor {
    /// The recorded events, in the order of delivery.
    let events = WatchedValue<[RecordedHookEvent]>([])

    /// Records a `PrePrompt`.
    ///
    /// - Parameter context: The session and the event.
    /// - Returns: `.proceed`.
    func pre(_ context: HookContext<PrePrompt>) async -> PreDecision<PrePrompt> {
        record(.prePrompt, of: context.session)
        return .proceed
    }

    /// Records a `PreToolUse`.
    ///
    /// - Parameter context: The session and the event.
    /// - Returns: `.proceed`.
    func pre(_ context: HookContext<PreToolUse>) async -> PreDecision<PreToolUse> {
        record(.preToolUse, of: context.session)
        return .proceed
    }

    /// Records a `PreToolResult`.
    ///
    /// - Parameter context: The session and the event.
    /// - Returns: `.proceed`.
    func pre(_ context: HookContext<PreToolResult>) async -> PreDecision<PreToolResult> {
        record(.preToolResult, of: context.session)
        return .proceed
    }

    /// Records a `SessionStart` with its origin.
    ///
    /// - Parameter context: The session and the event.
    func post(_ context: HookContext<SessionStart>) async {
        record(.sessionStart(context.event.origin), of: context.session)
    }

    /// Records a `SessionEnd`.
    ///
    /// - Parameter context: The session and the event.
    func post(_ context: HookContext<SessionEnd>) async {
        record(.sessionEnd, of: context.session)
    }

    /// Records a `PostPrompt`.
    ///
    /// - Parameter context: The session and the event.
    func post(_ context: HookContext<PostPrompt>) async {
        record(.postPrompt, of: context.session)
    }

    /// Records a `PostToolUse`.
    ///
    /// - Parameter context: The session and the event.
    func post(_ context: HookContext<PostToolUse>) async {
        record(.postToolUse, of: context.session)
    }

    /// Appends one event to ``events``.
    ///
    /// - Parameters:
    ///   - kind: The type of the event.
    ///   - session: The session of the event.
    private func record(_ kind: RecordedHookEvent.Kind, of session: HookSession) {
        events.update { $0.append(RecordedHookEvent(kind: kind, session: session)) }
    }
}

/// A step of the teardown proof, in the order that the proof records it.
enum TeardownMilestone: Sendable, Equatable {
    /// The visitor got the `SessionEnd`, and waits for the gate.
    case sessionEndEntered
    /// The visitor ended its work on the `SessionEnd`.
    case sessionEndDelivered
    /// `closeOpenSessions()` returned, after the connection teardown.
    case teardownReturned
}

/// A visitor whose work on a `SessionEnd` waits until a gate opens. Thus the
/// delivery of the `SessionEnd` ends only after the test opens the gate.
struct GatedSessionEndVisitor: HookVisitor {
    /// The log that the visitor writes its milestones into.
    let milestones: WatchedValue<[TeardownMilestone]>

    /// The gate. The delivery of a `SessionEnd` waits until it is `true`.
    let gate: WatchedValue<Bool>

    /// Records the start of the delivery, waits for the gate, and records the
    /// end of the delivery.
    ///
    /// - Parameter context: The session and the event.
    func post(_ context: HookContext<SessionEnd>) async {
        milestones.update { $0.append(.sessionEndEntered) }
        _ = try? await gate.wait(for: "the gate opens") { $0 }
        milestones.update { $0.append(.sessionEndDelivered) }
    }
}
