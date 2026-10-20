import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsHooks
import FoundationModelsRouter
import Logging
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

    // MARK: - The data directory

    /// An absolute `XDG_DATA_HOME` roots the hook data directory:
    /// `$XDG_DATA_HOME/<name>/hooks`.
    @Test
    func theDataDirectoryIsUnderAnAbsoluteXDGDataHome() throws {
        let dataHome = "/private/tmp/hook-composition-data-home"

        let directory = AgentHooks.dataDirectory(
            name: try DotfolderName(AgentClientHarness.dotfolderName), environment: ["XDG_DATA_HOME": dataHome])

        #expect(directory.path == "\(dataHome)/\(AgentClientHarness.dotfolderName)/hooks")
    }

    /// With no `XDG_DATA_HOME`, or with a relative one, the hook data
    /// directory is `~/.local/share/<name>/hooks`, as the XDG Base Directory
    /// specification tells.
    @Test(arguments: [[:], ["XDG_DATA_HOME": "relative/data"]])
    func theDataDirectoryDefaultsToTheLocalShareFolderOfTheHome(environment: [String: String]) throws {
        let directory = AgentHooks.dataDirectory(
            name: try DotfolderName(AgentClientHarness.dotfolderName), environment: environment)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(directory.path == "\(home)/.local/share/\(AgentClientHarness.dotfolderName)/hooks")
    }

    /// A composition with no `hooksDataDirectory` keeps the hook data in
    /// ``AgentHooks/dataDirectory(name:environment:)`` of its
    /// `XDG_DATA_HOME`, as before the parameter was added.
    @Test
    func aCompositionWithNoHooksDataDirectoryUsesTheDataHome() async throws {
        let dataHome = makeResolvedDirectory(label: "HookCompositionTests-compose-data")

        let composed = try await composeStubAgent(
            name: AgentClientHarness.dotfolderName, label: "HookCompositionTests-compose", dataHome: dataHome)

        let expected = AgentHooks.dataDirectory(
            name: try DotfolderName(AgentClientHarness.dotfolderName),
            environment: [AgentHooks.dataHomeEnvironmentKey: dataHome.path])
        #expect(composed.agent.hooks.dispatcher.dataDirectory.path == expected.path)
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

    // MARK: - The events of a session

    /// A new session with one prompt, whose tool call writes a file, and a
    /// close: a visitor that the host registers gets each event of the
    /// session, in order, and each event has the ACP session id as its key.
    @Test
    func aNewSessionSendsEachHookEventWithTheACPSessionIdAsItsKey() async throws {
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
        #expect(events.allSatisfy { $0.session.sessionKey == fixture.sessionId.rawValue })
    }

    /// A model-slot switch makes a replacement session in the same lineage:
    /// its `SessionStart` has the key of the session it replaces, the ACP
    /// session id, and the origin `replacement`.
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
        #expect(starts.allSatisfy { $0.session.sessionKey == fixture.sessionId.rawValue })
        await fixture.close()
    }

    /// A resume restores the recorded session: a visitor that the host
    /// registers after the agent is made gets `SessionStart(.resumed)`, with
    /// the ACP session id as its key.
    @Test
    func aResumedSessionStartsWithTheOriginResumedAndTheACPSessionIdAsItsKey() async throws {
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
        #expect(starts.allSatisfy { $0.session.sessionKey == resume.fixture.sessionId.rawValue })
        await resume.fixture.close()
    }

    // MARK: - The snapshots

    /// In a git work tree, a tool call that writes a file makes one
    /// checkpoint, which `tools.snapshots.list` of the session gives, and
    /// `tools.snapshots.rollback` to the baseline puts the committed content
    /// of the file back.
    @Test
    func aToolCallThatWritesAFileMakesOneCheckpointThatARollbackRestores() async throws {
        let cwd = try Self.makeSnapshotWorkTree(label: "HookCompositionTests-snapshots-repo")
        let fixture = try await ScriptedPromptFixture.make(
            loader: makeHookLayeredModelLoader(script: try Self.makeSnapshotScript()),
            label: "HookCompositionTests-snapshots", workingDirectory: cwd)
        let note = cwd.appendingPathComponent(Self.noteFileName, isDirectory: false)

        _ = try await Self.runPrompt(Self.writePromptText, in: fixture, count: 1)
        #expect(try String(contentsOf: note, encoding: .utf8) == Self.writtenNoteContent)
        let listed = try await Self.runPrompt(Self.listPromptText, in: fixture, count: 2)
        #expect(listed.contains("\(Self.checkpointCountLabel)1"))
        let rolledBack = try await Self.runPrompt(Self.rollbackPromptText, in: fixture, count: 3)
        #expect(rolledBack.contains(Self.rolledBackAnswer))
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

    /// Runs one prompt of the snapshot proof with
    /// ``ScriptedPromptFixture/runPrompt(on:text:count:whileRunning:)``, so
    /// the snapshot of the tool call of the prompt is complete, and reads
    /// the tool call text of this prompt.
    ///
    /// - Parameters:
    ///   - text: The prompt text, which holds the marker of one snippet.
    ///   - fixture: The wired fixture.
    ///   - count: The number of prompts that the session has ended after
    ///     this prompt.
    /// - Returns: The text of the tool call updates of this prompt.
    /// - Throws: Whatever the wire call or the waits throw.
    private static func runPrompt(
        _ text: String, in fixture: ScriptedPromptFixture, count: Int
    ) async throws -> String {
        let countBefore = await fixture.collector.updates.count
        let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: text, count: count)
        return SkillsLibraryTests.toolCallText(in: Array(run.updates.dropFirst(countBefore)))
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
        let cwd = try makeSnapshotWorkTree(label: "\(label)-repo")
        let fixture = try await ScriptedPromptFixture.make(
            loader: makeHookLayeredModelLoader(
                script: try ScriptedPromptFixture.makeToolPromptScript(code: writeCode)),
            label: label, workingDirectory: cwd)
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: writePromptText, count: 1)
        return fixture
    }

    /// `session/delete` removes the shadow folder of the session key (the
    /// ACP session id) after a turn that made a checkpoint.
    @Test
    func aSessionDeleteRemovesTheTimelineOfItsSessionKey() async throws {
        let fixture = try await Self.makeWrittenSnapshotFixture(label: "HookCompositionTests-delete")
        let store = fixture.harness.agent.hooks.snapshotStore
        let sessionKey = fixture.sessionId.rawValue
        #expect(!(try await store.checkpoints(sessionKey: sessionKey)).isEmpty)
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
        let sessionKey = fixture.sessionId.rawValue
        try await store.open(sessionKey: sessionKey, owner: Self.secondOwner, workingDirectory: fixture.cwd)

        _ = try await fixture.harness.connection.deleteSession(DeleteSessionRequest(sessionId: fixture.sessionId))

        #expect(try await store.shadowSessionKeys().contains(sessionKey))
        await store.release(sessionKey: sessionKey, owner: Self.secondOwner)
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

        #expect(try await store.shadowSessionKeys().contains(fixture.sessionId.rawValue))
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

    // MARK: - The end of the connection

    /// When the client goes away, the teardown of the connection closes each
    /// open session and then waits until the dispatcher delivered each post
    /// event. Thus the `SessionEnd` of a slow visitor is delivered before the
    /// teardown returns.
    @Test
    func theConnectionTeardownReturnsAfterTheDispatcherDrained() async throws {
        let milestones = WatchedValue<[TeardownMilestone]>([])
        let gate = WatchedValue(false)
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta("an answer"), .endPass], label: "HookCompositionTests-teardown",
            hookVisitors: [GatedSessionEndVisitor(milestones: milestones, gate: gate)])
        let agent = fixture.harness.agent

        await ConnectionCloseTests.dropClientEnd(of: fixture.harness)
        let teardown = Task {
            await agent.waitForConnectionTeardown()
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
    /// `waitForConnectionTeardown()` returned.
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
