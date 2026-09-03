import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `session/resume` wire surface (plan.md §7.4, §8.3, §10.1): the cwd
/// equality pre-check, the restore with freshly assembled instructions,
/// the root-set replacement, the missing-tool report, and replay as
/// whole-message upserts keyed by the recorded ids.
///
/// Every round trip records through a real routed session over
/// ``ResumeStubBackend`` and resumes over the same wire the client
/// drives, so the proofs read behavior — the recorded events, the raw
/// notification sequence, and what the restored backend received.
struct SessionResumeTests {
    /// One replayed message, as both the recording and the wire show it.
    private struct ReplayedMessage: Equatable {
        /// Which whole-message form carried it.
        let kind: Kind

        /// The message id on the wire.
        let id: String

        /// The joined text content.
        let text: String

        /// The three whole-message forms replay sends.
        enum Kind: Equatable {
            /// A `user_message` upsert.
            case user

            /// An `agent_message` upsert.
            case agent

            /// An `agent_thought` upsert.
            case thought
        }
    }

    // MARK: - Readers

    /// The messages replay is expected to send for `events`: one row per
    /// recorded `.prompt`, `.reasoning`, and `.response` event, keyed by
    /// the recorded first segment id.
    ///
    /// - Parameter events: The session's recorded events, in order.
    /// - Returns: The expected messages, in order.
    private static func expectedMessages(from events: [TranscriptEvent]) -> [ReplayedMessage] {
        events.compactMap { event in
            let kind: ReplayedMessage.Kind
            switch event.kind {
            case .prompt:
                kind = .user
            case .reasoning:
                kind = .thought
            case .response:
                kind = .agent
            default:
                return nil
            }
            guard let segments = event.entry?.segments,
                case .text(let id, let content) = segments.first
            else {
                return nil
            }
            return ReplayedMessage(kind: kind, id: id, text: content)
        }
    }

    /// The whole-message upserts in a raw update sequence.
    ///
    /// - Parameter updates: The recorded raw updates.
    /// - Returns: The messages, in arrival order.
    private static func replayedMessages(in updates: [SessionUpdate]) -> [ReplayedMessage] {
        updates.compactMap { update in
            switch update {
            case .userMessage(let message):
                return ReplayedMessage(
                    kind: .user, id: message.messageId.rawValue, text: text(of: message.content))
            case .agentMessage(let message):
                return ReplayedMessage(
                    kind: .agent, id: message.messageId.rawValue, text: text(of: message.content))
            case .agentThought(let message):
                return ReplayedMessage(
                    kind: .thought, id: message.messageId.rawValue, text: text(of: message.content))
            default:
                return nil
            }
        }
    }

    /// The joined text of a whole-message content patch.
    ///
    /// - Parameter content: The message's content patch.
    /// - Returns: The joined text of its text blocks; empty otherwise.
    private static func text(of content: PatchField<[ContentBlock]>?) -> String {
        guard case .value(let blocks)? = content else {
            return ""
        }
        return blocks.compactMap { block in
            if case .text(let text) = block {
                return text.text
            }
            return nil
        }.joined()
    }

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

    // MARK: - The unknown-id policy (plan.md §10.1)

    @Test(.timeLimit(.minutes(1)))
    func resumeWithAnUnknownIdAnswersInvalidParamsWithTheIdInData() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-unknown")
        let unknownId = SessionId(rawValue: ULID.generate().description)

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                ResumeSessionRequest(
                    cwd: try #require(AbsolutePath(rawValue: resume.fixture.cwd.path)),
                    sessionId: unknownId))
            Issue.record("expected the unknown-id refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == unknownId.rawValue)
        }
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWithAnIdThatIsNoULIDAnswersInvalidParamsWithTheIdInData() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-malformed")
        let malformedId = SessionId(rawValue: "not-a-ulid")

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                ResumeSessionRequest(
                    cwd: try #require(AbsolutePath(rawValue: resume.fixture.cwd.path)),
                    sessionId: malformedId))
            Issue.record("expected the unknown-id refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == malformedId.rawValue)
        }
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeAfterTheSessionDirectoryIsDeletedAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-deleted")
        try await resume.runTurn("one turn before the delete")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                resume.fixture.sessionId.rawValue, isDirectory: true))

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                try resume.makeResumeRequest())
            Issue.record("expected the deleted-session refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == resume.fixture.sessionId.rawValue)
        }
        await resume.fixture.close()
    }

    // MARK: - The cwd equality pre-check (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
    func resumeWithADifferentCwdErrorsBeforeAnySessionIsBuilt() async throws {
        // Both projects share one absolute recording root, so the
        // pre-check finds the session and sees the recorded cwd differ.
        let sharedRoot = makeResolvedDirectory(label: "SessionResumeTests-shared-root")
        let sharedRootYAML = "transcripts:\n  location: \(sharedRoot.path)\n"
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-cwd",
            projectConfigYAML: sharedRootYAML)
        try await resume.runTurn("one turn before the mismatch")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: sharedRoot, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let otherCwd = makeResolvedDirectory(label: "SessionResumeTests-cwd-other")
        try ScriptedTurnFixture.writeProjectConfig(yaml: sharedRootYAML, under: otherCwd)
        let requestsBefore = resume.container.backendRequestCount

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                try resume.makeResumeRequest(cwd: otherCwd))
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

    // MARK: - Replay as whole-message upserts (plan.md §7.4, §8.3)

    @Test(.timeLimit(.minutes(1)))
    func replayFromStartSendsWholeMessageUpsertsWithTheRecordedIds() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-replay")
        try await resume.runTurn("first question")
        try await resume.runTurn("second question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 2)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let expected = Self.expectedMessages(
            from: try ResumeSessionFixture.recordedEvents(
                under: root, sessionId: resume.fixture.sessionId))
        #expect(expected.count == 6)
        #expect(expected.map(\.kind).prefix(3) == [.user, .thought, .agent])
        #expect(expected.first?.text == "first question")

        let countBefore = await resume.fixture.collector.updates.count
        let response = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        // The replay went out before the response completed, so the
        // collector already holds every upsert.
        let replayUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        #expect(!replayUpdates.contains { Self.isChunk($0) })
        #expect(Self.replayedMessages(in: replayUpdates) == expected)
        #expect(response.configOptions?.isEmpty == false)

        // A second replay converges: the same ids again, no duplicates
        // under the §8.3 replace row.
        let countBetween = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let secondUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBetween))
            .map(\.update)
        #expect(Self.replayedMessages(in: secondUpdates) == expected)
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWithoutReplayFromSendsNoMessageUpserts() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-noreplay")
        try await resume.runTurn("one turn before the quiet resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())
        let updates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        #expect(Self.replayedMessages(in: updates).isEmpty)
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWithAnUnknownReplayCursorAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-cursor")
        try await resume.runTurn("one turn before the unknown cursor")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        do {
            _ = try await resume.fixture.harness.connection.resumeSession(
                try resume.makeResumeRequest(
                    replayFrom: .unknown("bookmark", .object([:]))))
            Issue.record("expected the unknown-cursor refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("replayFrom", of: error) == "bookmark")
        }
        await resume.fixture.close()
    }

    // MARK: - The resumed conversation (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
    func aResumedSessionContinuesTheConversationWithTheEarlierContext() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-continue")
        try await resume.runTurn("first question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())

        // The restored model received the earlier context: the transcript
        // handed to the backend carries the first turn.
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

        // The resumed session answers the next turn.
        try await resume.runTurn("second question")
        let updates = await resume.fixture.collector.updates.map(\.update)
        let answered = updates.contains { update in
            if case .agentMessageChunk(let chunk) = update,
                case .text(let text) = chunk.content
            {
                return text.text == ResumeStubBackend.replyPrefix + "second question"
            }
            return false
        }
        #expect(answered)
        await resume.fixture.close()
    }

    // MARK: - The root set (plan.md §7.2, §7.4)

    @Test(.timeLimit(.minutes(1)))
    func resumeOmittingAdditionalDirectoriesConfinesToTheCwdAlone() async throws {
        let outside = makeResolvedDirectory(label: "SessionResumeTests-roots-outside")
        let outsideFile = outside.appendingPathComponent("outside.txt")
        try "outside the resumed roots".write(to: outsideFile, atomically: true, encoding: .utf8)
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-roots",
            additionalDirectories: [try #require(AbsolutePath(rawValue: outside.path))])
        let insideFile = resume.fixture.cwd.appendingPathComponent("inside.txt")
        try "inside the cwd".write(to: insideFile, atomically: true, encoding: .utf8)
        try await resume.runTurn("one turn before the root change")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())

        // The confinement was rebuilt with the cwd only: a file outside
        // the cwd is now refused, and a file under it still reads.
        let entry = await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]
        let readVerb = try #require(entry?.surface.filesReadVerb)
        let refused = try await FilesVerbSupport.invokeRead(readVerb, path: outsideFile.path)
        #expect(refused.correction != nil)
        #expect(refused.lines.isEmpty)
        let accepted = try await FilesVerbSupport.invokeRead(readVerb, path: insideFile.path)
        #expect(accepted.correction == nil)

        // The new ordered list is persisted to the index: the last record
        // for this session carries no additional directories.
        let record = try SessionIndex(root: root).read().records
            .last { $0.sessionId == resume.fixture.sessionId.rawValue }
        #expect(try #require(record).additionalDirectories.isEmpty)
        await resume.fixture.close()
    }

    // MARK: - The missing-tool report (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
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
        _ = try await recorded.respond(to: "one recorded turn")
        await recorded.close()
        let recordedId = SessionId(rawValue: recorded.id.description)

        try ScriptedTurnFixture.writeProjectConfig(
            yaml: "tools:\n  shell: false\n", under: resume.fixture.cwd)
        let response = try await resume.fixture.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: try #require(AbsolutePath(rawValue: resume.fixture.cwd.path)),
                sessionId: recordedId))

        #expect(Self.missingToolNames(of: response).contains(ShellVerbSupport.executeVerbPath))
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumingWithAnUnchangedRosterReportsNoMissingTools() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-complete")
        try await resume.runTurn("one turn before the clean resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let response = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())

        #expect(Self.missingToolNames(of: response).isEmpty)
        await resume.fixture.close()
    }

    // MARK: - The instructions override (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
    func resumingWithChangedInstructionsReachesTheModelAndWritesOneDivergenceEvent() async throws {
        let marker = "Always answer in iambic pentameter."
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-diverge")
        try await resume.runTurn("one turn before the instructions change")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        try marker.write(
            to: resume.fixture.cwd.appendingPathComponent(
                InstructionsAssembler.agentsFileName),
            atomically: true, encoding: .utf8)
        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())

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

    @Test(.timeLimit(.minutes(1)))
    func resumingWithUnchangedInstructionsWritesNoDivergenceEvent() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-samewords")
        try await resume.runTurn("one turn before the unchanged resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            try resume.makeResumeRequest())

        let divergences = try Self.divergenceEvents(
            under: root, sessionId: resume.fixture.sessionId)
        #expect(divergences.isEmpty)
        await resume.fixture.close()
    }
}
