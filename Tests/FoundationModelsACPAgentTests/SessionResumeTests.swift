import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `session/resume` wire surface: the cwd
/// equality pre-check, the restore with freshly assembled instructions,
/// the root-set replacement, the missing-tool report, the command list of
/// the response, and replay of the retained history as whole-message
/// upserts keyed by the ids that the client saw live.
///
/// Every round trip records through a real routed session over
/// ``ResumeStubBackend`` and resumes over the same wire the client
/// drives, so the proofs read behavior — the recorded events, the raw
/// notification sequence, and what the restored backend received.
@Suite(.closesHarnesses) struct SessionResumeTests {
    // MARK: - Readers
    //
    // The readers of the replayed messages are in
    // `Support/ReplayedMessage.swift`, shared with `PromptExecutionTests`.

    /// Whether an update is one of the chunk forms replay must not send.
    ///
    /// - Parameter update: The update to classify.
    /// - Returns: `true` for a chunk update.
    private static func isChunk(_ update: SessionUpdate) -> Bool {
        switch update {
        case .userMessageChunk, .agentMessageChunk, .agentThoughtChunk,
            .toolCallContentChunk, .terminalOutputChunk:
            return true
        default:
            return false
        }
    }

    /// The `missingTools` names of a resume response's `_meta`, or empty.
    ///
    /// - Parameter response: The resume response.
    /// - Returns: The reported names, in order.
    private static func missingToolNames(of response: ResumeSessionResponse) -> [String] {
        guard case .object(let fields)? = response.meta,
            case .array(let values)? = fields["missingTools"]
        else {
            return []
        }
        return values.compactMap { value in
            if case .string(let name) = value {
                return name
            }
            return nil
        }
    }

    /// The joined text of a restored transcript's leading `.instructions`
    /// entry, or `nil` when the transcript opens with another entry.
    ///
    /// - Parameter transcript: The transcript the restore handed over.
    /// - Returns: The instructions text, or `nil`.
    private static func leadingInstructionsText(of transcript: Transcript) -> String? {
        guard case .instructions(let instructions)? = Array(transcript).first else {
            return nil
        }
        return instructions.segments.compactMap { segment in
            if case .text(let text) = segment {
                return text.content
            }
            return nil
        }.joined()
    }

    /// The session's recorded `.divergence` events under `root`.
    ///
    /// - Parameters:
    ///   - root: The recording root to read.
    ///   - sessionId: The session whose events to keep.
    /// - Returns: The divergence events, in order.
    /// - Throws: Whatever the merged read throws.
    private static func divergenceEvents(
        under root: URL, sessionId: SessionId
    ) throws -> [TranscriptEvent] {
        try ResumeSessionFixture.recordedEvents(under: root, sessionId: sessionId)
            .filter { $0.kind == .divergence }
    }

    /// A `cwd` string that is not absolute, so the agent must refuse it.
    private static let relativeCwd = "relative/resume"

    /// An `additionalDirectories` entry that is not absolute, so the
    /// agent must refuse it too.
    private static let relativeAdditionalDirectory = "relative/extra"

    /// The name of the builtin `/help` command, which each command list
    /// holds.
    private static let builtinHelpCommandName = "help"

    // MARK: - The absolute-cwd rule

    /// A relative `cwd` is refused before the session id is read, and the
    /// refusal names the field that failed and why. `session/new`,
    /// `session/list` and `session/resume` all answer the same way,
    /// because one validator serves all three.
    @Test
    func resumeWithARelativeCwdAnswersInvalidParamsNamingTheField() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-relative")

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: SessionSetupTests.expectedRefusalData(naming: .cwd)
        ) {
            _ = try await resume.fixture.harness.connection.resumeSession(
                ResumeSessionRequest(
                    cwd: AbsolutePath(rawValue: Self.relativeCwd),
                    sessionId: resume.fixture.sessionId))
        }
        await resume.fixture.close()
    }

    /// The mirror of the proof above: a relative `additionalDirectories`
    /// entry refuses the resume too, and names its own field. Each
    /// reconnect carries the complete new root set, so a dropped entry
    /// would narrow the confinement and never say so.
    @Test
    func resumeWithARelativeAdditionalDirectoryAnswersInvalidParamsNamingTheField() async throws {
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-relative-extra")
        try await resume.runPrompt("one prompt before the resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: SessionSetupTests.expectedRefusalData(naming: .additionalDirectories)
        ) {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest(
                    additionalDirectories: [
                        AbsolutePath(rawValue: Self.relativeAdditionalDirectory)
                    ]))
        }
        await resume.fixture.close()
    }

    // MARK: - The unknown-id policy

    @Test
    func resumeWithAnUnknownIdAnswersInvalidParamsWithTheIdInData() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-unknown")
        let unknownId = SessionId(rawValue: ULID.generate().description)

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                ResumeSessionRequest(
                    cwd: AbsolutePath(rawValue: resume.fixture.cwd.path),
                    sessionId: unknownId))
            Issue.record("expected the unknown-id refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == unknownId.rawValue)
        }
        await resume.fixture.close()
    }

    @Test
    func resumeWithAnIdThatIsNoULIDAnswersInvalidParamsWithTheIdInData() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-malformed")
        let malformedId = SessionId(rawValue: "not-a-ulid")

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                ResumeSessionRequest(
                    cwd: AbsolutePath(rawValue: resume.fixture.cwd.path),
                    sessionId: malformedId))
            Issue.record("expected the unknown-id refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == malformedId.rawValue)
        }
        await resume.fixture.close()
    }

    @Test
    func resumeAfterTheSessionDirectoryIsDeletedAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-deleted")
        try await resume.runPrompt("one prompt before the delete")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                resume.fixture.sessionId.rawValue, isDirectory: true))

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest())
            Issue.record("expected the deleted-session refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == resume.fixture.sessionId.rawValue)
        }
        await resume.fixture.close()
    }

    // MARK: - The cwd equality pre-check

    @Test
    func resumeWithADifferentCwdErrorsBeforeAnySessionIsBuilt() async throws {
        // Both projects share one absolute recording root, so the
        // pre-check finds the session and sees the recorded cwd differ.
        let sharedRoot = makeResolvedDirectory(label: "SessionResumeTests-shared-root")
        let sharedRootYAML = "transcripts:\n  location: \(sharedRoot.path)\n"
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-cwd",
            projectConfigYAML: sharedRootYAML)
        try await resume.runPrompt("one prompt before the mismatch")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: sharedRoot, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let otherCwd = makeResolvedDirectory(label: "SessionResumeTests-cwd-other")
        try ScriptedPromptFixture.writeProjectConfig(yaml: sharedRootYAML, under: otherCwd)
        let requestsBefore = resume.container.backendRequestCount

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest(cwd: otherCwd))
            Issue.record("expected the cwd-mismatch refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == resume.fixture.sessionId.rawValue)
            #expect(
                errorDataField("recordedCwd", of: error)
                    == resume.fixture.cwd.standardizedFileURL.path)
        }
        // The mismatch was checked before any restore: the loader was
        // never asked for another backend.
        #expect(resume.container.backendRequestCount == requestsBefore)
        await resume.fixture.close()
    }

    // MARK: - The missing working directory

    /// The `reason` the prompt refusal of a replay-only session reports.
    private static let missingWorkingDirectoryReason =
        "the working directory of this session does not exist"

    /// The user-layer `tools:` section a deleted-cwd resume reads: the code
    /// context on, with no language-server install and no embedding. A
    /// resume that composes the tool surface would watch and index the
    /// deleted cwd, and the replay-only resume mounts no tool at all.
    private static let codeContextOnYAML =
        "tools:\n  codeContext:\n    autoInstall: false\n    semanticSearch: false\n"

    /// One resume of a session whose cwd was deleted after its close.
    private struct DeletedCwdResume {
        /// The resumed fixture.
        let resume: ResumeSessionFixture

        /// The messages the client saw live, before the close.
        let live: [ReplayedMessage]

        /// The messages the resume replayed.
        let replayed: [ReplayedMessage]
    }

    /// Runs one prompt in a new session, closes the session, deletes its
    /// cwd, and resumes it with a replay from the start.
    ///
    /// The transcripts are under an absolute root outside the cwd, so the
    /// recording stays when the cwd goes. The project layer gives that root
    /// to `session/new`. The project layer goes with the cwd, so the user
    /// layer gives the same root to the resume, with the code context on.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The resumed fixture, and the live and the replayed messages.
    /// - Throws: Whatever the fixture, the wire calls, or the file
    ///   operations throw.
    private static func resumeAfterDeletingTheCwd(label: String) async throws -> DeletedCwdResume {
        let sharedRoot = makeResolvedDirectory(label: "\(label)-root")
        let locationYAML = "transcripts:\n  location: \(sharedRoot.path)\n"
        var resume = try await ResumeSessionFixture.make(label: label, projectConfigYAML: locationYAML)
        try await resume.runPrompt("first question")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: sharedRoot, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        let live = ReplayedMessage.live(in: await resume.fixture.collector.updates.map(\.update))
        _ = try await resume.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: resume.fixture.sessionId))

        let userDirectory = resume.fixture.harness.agent.settingsFolders.home.synced
        try ConfigFileFixture.write(locationYAML + codeContextOnYAML, in: userDirectory)
        try FileManager.default.removeItem(at: resume.fixture.cwd)

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let replayUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        return DeletedCwdResume(
            resume: resume, live: live, replayed: ReplayedMessage.replayed(in: replayUpdates))
    }

    /// Asserts that a prompt on `sessionId` is refused because the working
    /// directory of the session does not exist. The refusal is invalid
    /// params, with the session id and the reason in `data`.
    ///
    /// - Parameters:
    ///   - sessionId: The replay-only session.
    ///   - connection: The client end of the wire.
    private static func expectMissingWorkingDirectoryRefusal(
        of sessionId: SessionId, through connection: ClientSideConnection
    ) async {
        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: .object([
                "sessionId": .string(sessionId.rawValue),
                "reason": .string(Self.missingWorkingDirectoryReason),
            ])
        ) {
            _ = try await connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: sessionId, text: "after the delete"))
        }
    }

    /// A resume of a session whose cwd was deleted replays every message,
    /// and the cwd still does not exist after the resume: the agent mounts
    /// no tool surface, so nothing makes the cwd again.
    @Test
    func resumeAfterTheCwdIsDeletedReplaysTheHistoryAndCreatesNoDirectory() async throws {
        let deleted = try await Self.resumeAfterDeletingTheCwd(
            label: "SessionResumeTests-deleted-cwd-replay")

        #expect(!deleted.live.isEmpty)
        #expect(deleted.replayed == deleted.live)
        #expect(!FileManager.default.fileExists(atPath: deleted.resume.fixture.cwd.path))
        let entry = await deleted.resume.fixture.harness.agent.sessions[deleted.resume.fixture.sessionId]
        #expect(try #require(entry).surface.tools.isEmpty)
        await deleted.resume.fixture.close()
    }

    /// A prompt on a session that was resumed with a deleted cwd is refused
    /// with invalid params and the reason, and the cwd still does not exist.
    @Test
    func aPromptAfterAResumeWithADeletedCwdIsRefused() async throws {
        let deleted = try await Self.resumeAfterDeletingTheCwd(
            label: "SessionResumeTests-deleted-cwd-prompt")

        await Self.expectMissingWorkingDirectoryRefusal(
            of: deleted.resume.fixture.sessionId, through: deleted.resume.fixture.harness.connection)

        #expect(!FileManager.default.fileExists(atPath: deleted.resume.fixture.cwd.path))
        await deleted.resume.fixture.close()
    }

    /// A resume whose `additionalDirectories` entry does not exist makes a
    /// replay-only session too: a prompt is refused, and the entry is not
    /// made.
    @Test
    func aResumeWithAMissingAdditionalDirectoryRefusesAPrompt() async throws {
        let extra = makeResolvedDirectory(label: "SessionResumeTests-missing-extra")
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-missing-extra",
            additionalDirectories: [AbsolutePath(rawValue: extra.path)])
        try await resume.runPrompt("one prompt before the delete")
        _ = try await resume.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: resume.fixture.sessionId))
        try FileManager.default.removeItem(at: extra)

        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(additionalDirectories: [AbsolutePath(rawValue: extra.path)]))

        await Self.expectMissingWorkingDirectoryRefusal(
            of: resume.fixture.sessionId, through: resume.fixture.harness.connection)
        #expect(!FileManager.default.fileExists(atPath: extra.path))
        await resume.fixture.close()
    }

    // MARK: - Replay as whole-message upserts

    /// The replay sends the retained history of the session: each message
    /// that the client saw live, as one whole-message upsert with the id it
    /// had live (ACP schema-v2.0.0-alpha.7). The user message keeps the id
    /// that the prompt response named.
    @Test
    func replayFromStartSendsWholeMessageUpsertsWithTheLiveIds() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-replay")
        let firstPrompt = try await resume.runPrompt("first question")
        let secondPrompt = try await resume.runPrompt("second question")
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let expected = ReplayedMessage.live(in: await resume.fixture.collector.updates.map(\.update))
        #expect(expected.count == 6)
        // The stub streams the reply of a pass before its reasoning.
        #expect(expected.map(\.kind).prefix(3) == [.user, .agent, .thought])
        #expect(expected.first?.text == "first question")
        #expect(
            expected.filter { $0.kind == .user }.map(\.id)
                == [firstPrompt.messageId.rawValue, secondPrompt.messageId.rawValue])

        let countBefore = await resume.fixture.collector.updates.count
        let response = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        // The replay went out before the response completed, so the
        // collector already holds every upsert.
        let replayUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        #expect(!replayUpdates.contains { Self.isChunk($0) })
        #expect(ReplayedMessage.replayed(in: replayUpdates) == expected)
        #expect(response.configOptions?.isEmpty == false)

        // A second replay converges: the same ids again, no duplicates
        // because a whole-message upsert replaces all accumulated content.
        let countBetween = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let secondUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBetween))
            .map(\.update)
        #expect(ReplayedMessage.replayed(in: secondUpdates) == expected)
        await resume.fixture.close()
    }

    /// A new agent over the same project resumes a session that an earlier
    /// agent ran, and replays each message with the id that the earlier
    /// agent gave it. The earlier agent wrote the retained history beside
    /// the transcript, so the ids do not come from the Router journal.
    @Test
    func aNewAgentReplaysTheMessagesWithTheIdsOfTheEarlierAgent() async throws {
        var first = try await ResumeSessionFixture.make(label: "SessionResumeTests-new-agent")
        try await first.runPrompt("first question")
        try await first.runPrompt("second question")
        let expected = ReplayedMessage.live(in: await first.fixture.collector.updates.map(\.update))
        _ = try await first.fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: first.fixture.sessionId))
        await first.fixture.close()

        let second = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-new-agent-second", workingDirectory: first.fixture.cwd)
        let countBefore = await second.fixture.collector.updates.count
        _ = try await second.fixture.harness.connection.resumeSession(
            first.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let replayUpdates = Array(await second.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)

        #expect(expected.count == 6)
        #expect(ReplayedMessage.replayed(in: replayUpdates) == expected)
        await second.fixture.close()
    }

    /// A session that has no retained history (an earlier build recorded
    /// it: a Router journal and no history file) replays no message. The
    /// Router journal serves only the restore of the model context: its
    /// messages have no ACP ids, and after a compaction it holds a summary
    /// in place of the messages that it folded.
    @Test
    func aSessionWithNoRetainedHistoryReplaysNoMessage() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-no-history")
        let recordedId = try await resume.recordSessionOutsideTheAgent(prompts: ["first question"])
        let recorded = try ResumeSessionFixture.recordedEvents(
            under: try resume.recordingRoot, sessionId: recordedId)
        #expect(recorded.contains { $0.kind == .prompt })

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: resume.fixture.cwd.path), sessionId: recordedId,
                replayFrom: .start(ReplayFromStart())))
        let replayUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)

        #expect(ReplayedMessage.replayed(in: replayUpdates).isEmpty)
        await resume.fixture.close()
    }

    /// The resume response holds the command list of the resumed session
    /// (ACP schema-v2.0.0-alpha.7), as the `session/new` response does.
    @Test
    func theResumeResponseHoldsTheCommandList() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-commands")
        try await resume.runPrompt("one prompt before the resume")
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let response = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        #expect((response.availableCommands ?? []).map(\.name).contains(Self.builtinHelpCommandName))
        await resume.fixture.close()
    }

    @Test
    func resumeWithoutReplayFromSendsNoMessageUpserts() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-noreplay")
        try await resume.runPrompt("one prompt before the quiet resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())
        let updates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        #expect(ReplayedMessage.replayed(in: updates).isEmpty)
        await resume.fixture.close()
    }

    @Test
    func resumeWithAnUnknownReplayCursorAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-cursor")
        try await resume.runPrompt("one prompt before the unknown cursor")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest(
                    replayFrom: .unknown("bookmark", .object([:]))))
            Issue.record("expected the unknown-cursor refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("replayFrom", of: error) == "bookmark")
        }
        await resume.fixture.close()
    }

    // MARK: - The resumed conversation

    @Test
    func aResumedSessionContinuesTheConversationWithTheEarlierContext() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-continue")
        try await resume.runPrompt("first question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        // The restored model received the earlier context: the transcript
        // handed to the backend carries the first prompt.
        let transcript = try #require(resume.container.restoredTranscripts.last)
        let hadEarlierPrompt = Array(transcript).contains { entry in
            if case .prompt(let prompt) = entry {
                return prompt.segments.contains { segment in
                    if case .text(let text) = segment {
                        return text.content == "first question"
                    }
                    return false
                }
            }
            return false
        }
        #expect(hadEarlierPrompt)

        // The resumed session answers the next prompt.
        try await resume.runPrompt("second question")
        let texts = ScriptedPromptFixture.agentChunkTexts(in: await resume.fixture.collector.updates)
        #expect(texts.contains(ResumeStubBackend.replyPrefix + "second question"))
        await resume.fixture.close()
    }

    // MARK: - The root set

    @Test
    func resumeOmittingAdditionalDirectoriesConfinesToTheCwdAlone() async throws {
        let outside = makeResolvedDirectory(label: "SessionResumeTests-roots-outside")
        let outsideFile = outside.appendingPathComponent("outside.txt")
        try "outside the resumed roots".write(to: outsideFile, atomically: true, encoding: .utf8)
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-roots",
            additionalDirectories: [AbsolutePath(rawValue: outside.path)])
        let insideFile = resume.fixture.cwd.appendingPathComponent("inside.txt")
        try "inside the cwd".write(to: insideFile, atomically: true, encoding: .utf8)
        try await resume.runPrompt("one prompt before the root change")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        // The confinement was rebuilt with the cwd only: a file outside
        // the cwd is now refused, and a file under it still reads.
        let entry = await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]
        let readVerb = try #require(entry?.surface.filesReadVerb)
        let refused = try await FilesVerbSupport.invokeRead(readVerb, path: outsideFile.path)
        #expect(refused.correction != nil)
        #expect(refused.lines.isEmpty)
        let accepted = try await FilesVerbSupport.invokeRead(readVerb, path: insideFile.path)
        #expect(accepted.correction == nil)

        // The new ordered list is persisted to the `index.md` of the
        // session: its record carries no additional directories.
        let record = try RouterSessionDirectory.recordedSessions(in: root)
            .first { $0.sessionId.description == resume.fixture.sessionId.rawValue }
        #expect(try #require(record).additionalDirectories.isEmpty)
        await resume.fixture.close()
    }

    // MARK: - The MCP server outcomes

    /// The name of the client MCP server of the resume request that cannot
    /// connect.
    private static let brokenServerName = "resume-broken"

    /// A command that is not an absolute path, so the server cannot start.
    private static let relativeServerCommand = "session-resume-tests-relative-command"

    /// `session/resume` connects the `mcpServers` of the resume request, and
    /// the resumed surface keeps the outcome of each one. A client server that
    /// cannot connect does not stop the resume.
    @Test
    func resumeKeepsTheOutcomeOfEachMCPServerOfTheRequest() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-mcp-outcomes")
        try await resume.runPrompt("one prompt before the resume")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: try resume.recordingRoot, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)
        var request = resume.makeResumeRequest()
        request.mcpServers = [
            .stdio(
                MCPServerStdio(
                    command: AbsolutePath(rawValue: Self.relativeServerCommand),
                    name: Self.brokenServerName))
        ]

        _ = try await resume.fixture.harness.connection.resumeSession(request)

        let entry = await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]
        #expect(
            entry?.surface.mcpServerOutcomes == [
                MCPComposition.ServerOutcome(
                    name: Self.brokenServerName, transport: .stdio, origin: .client,
                    result: .failed(reason: .commandNotAbsolute))
            ])
        await resume.fixture.close()
    }

    // MARK: - The missing-tool report

    @Test
    func resumingWithShellNewlyDisabledReportsTheMissingShellVerbs() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-missing")
        let agent = resume.fixture.harness.agent
        let root = try resume.recordingRoot

        // Record a root session whose roster names the shell verb, the
        // way an older recording can name tools the resumed composition
        // no longer supplies.
        let recorded = agent.residentProfile.standard.makeSession(
            instructions: "recorded instructions",
            workingDirectory: resume.fixture.cwd,
            recordingRoot: root,
            tools: [RosterNameTool(name: ShellVerbSupport.executeVerbPath)],
            budget: nil,
            compactionPrompt: .default)
        _ = try await recorded.respond(to: "one recorded prompt")
        await recorded.close()
        let recordedId = SessionId(rawValue: recorded.id.description)

        try ScriptedPromptFixture.writeProjectConfig(
            yaml: "tools:\n  shell: false\n", under: resume.fixture.cwd)
        let response = try await resume.fixture.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: resume.fixture.cwd.path),
                sessionId: recordedId))

        #expect(Self.missingToolNames(of: response).contains(ShellVerbSupport.executeVerbPath))
        await resume.fixture.close()
    }

    @Test
    func resumingWithAnUnchangedRosterReportsNoMissingTools() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-complete")
        try await resume.runPrompt("one prompt before the clean resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let response = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        #expect(Self.missingToolNames(of: response).isEmpty)
        await resume.fixture.close()
    }

    // MARK: - The instructions override

    @Test
    func resumingWithChangedInstructionsReachesTheModelAndWritesOneDivergenceEvent() async throws {
        let marker = "Always answer in iambic pentameter."
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-diverge")
        try await resume.runPrompt("one prompt before the instructions change")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        try marker.write(
            to: resume.fixture.cwd.appendingPathComponent(
                InstructionsAssembler.agentsFileName),
            atomically: true, encoding: .utf8)
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        // The MODEL sees the changed instructions: the transcript the
        // restored backend received opens with them.
        let transcript = try #require(resume.container.restoredTranscripts.last)
        let instructions = try #require(Self.leadingInstructionsText(of: transcript))
        #expect(instructions.contains(marker))

        // One divergence event, opening with the pinned phrase.
        let divergences = try Self.divergenceEvents(
            under: root, sessionId: resume.fixture.sessionId)
        #expect(divergences.count == 1)
        let text = try #require(divergences.first?.text)
        #expect(text.hasPrefix(RestoredSession.instructionsDivergencePhrase))
        await resume.fixture.close()
    }

    @Test
    func resumingWithUnchangedInstructionsWritesNoDivergenceEvent() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-samewords")
        try await resume.runPrompt("one prompt before the unchanged resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1, agent: resume.fixture.harness.agent)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        let divergences = try Self.divergenceEvents(
            under: root, sessionId: resume.fixture.sessionId)
        #expect(divergences.isEmpty)
        await resume.fixture.close()
    }
}
