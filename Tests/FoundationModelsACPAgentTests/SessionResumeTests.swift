import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
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

    // MARK: - The repeated-part journal line

    /// The file name of the journal in the directory of one session.
    private static let journalFileName = "transcript.jsonl"

    /// The content of a cut that keeps each entry whole, so the restored
    /// render is the same as the recorded one.
    private static let wholeRenderCutJSON = #"{"keptUTF8Lengths":{}}"#

    /// The journal keys of a `.response` line that a `repeatedPartRemoval`
    /// line does not carry.
    private static let responseOnlyJournalKeys = ["tokensIn", "tokensOut", "ms"]

    /// Puts one `repeatedPartRemoval` line in the journal of `sessionId`,
    /// directly after its first `.response` line, as Router writes one
    /// after the entries of a stopped attempt. The line takes the sequence
    /// number and the time of that response, thus it stands between the
    /// messages of the first prompt and the messages of the prompts after it.
    ///
    /// - Parameters:
    ///   - root: The recording root that holds the session directory.
    ///   - sessionId: The session whose journal gets the line.
    /// - Throws: When the journal cannot be read or written, or holds no
    ///   `.response` line.
    private static func insertRepeatedPartRemoval(under root: URL, sessionId: SessionId) throws {
        let journal = root.appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent(journalFileName)
        var lines = try String(contentsOf: journal, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let responseIndex = try #require(
            lines.firstIndex { journalKind(of: $0) == TranscriptEvent.Kind.response.rawValue })
        lines.insert(
            try repeatedPartRemovalLine(copying: lines[responseIndex]), at: responseIndex + 1)
        try (lines.joined(separator: "\n") + "\n").write(to: journal, atomically: true, encoding: .utf8)
    }

    /// The `kind` of one journal line, or `nil` when the line is no JSON
    /// object.
    ///
    /// - Parameter line: The journal line.
    /// - Returns: The raw kind.
    private static func journalKind(of line: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return object?["kind"] as? String
    }

    /// A `repeatedPartRemoval` journal line made from the identity fields of
    /// `responseLine`, with the payload Router writes: one structure segment
    /// that carries the cut.
    ///
    /// - Parameter responseLine: The `.response` line whose session, sequence
    ///   number and time the new line takes.
    /// - Returns: The new journal line.
    /// - Throws: When `responseLine` is no JSON object, or an encode fails.
    private static func repeatedPartRemovalLine(copying responseLine: String) throws -> String {
        var fields = try #require(
            JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        let segment = SegmentPayload.structure(
            id: UUID().uuidString, schemaName: ResumeSessionFixture.repeatedPartRemovalSchemaName,
            contentJSON: wholeRenderCutJSON)
        let segmentObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segment))
        for key in responseOnlyJournalKeys {
            fields.removeValue(forKey: key)
        }
        fields["kind"] = TranscriptEvent.Kind.repeatedPartRemoval.rawValue
        fields["text"] = ResumeSessionFixture.repeatedPartRemovalText
        fields["entry"] = ["entryId": UUID().uuidString, "segments": [segmentObject]]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A `cwd` string that is not absolute, so the agent must refuse it.
    private static let relativeCwd = "relative/resume"

    /// An `additionalDirectories` entry that is not absolute, so the
    /// agent must refuse it too.
    private static let relativeAdditionalDirectory = "relative/extra"

    // MARK: - The absolute-cwd rule (plan.md §7.1, §7.4)

    /// A relative `cwd` is refused before the session id is read, and the
    /// refusal names the field that failed and why. `session/new`,
    /// `session/list` and `session/resume` all answer the same way,
    /// because one validator serves all three.
    @Test(.timeLimit(.minutes(1)))
    func resumeWithARelativeCwdAnswersInvalidParamsNamingTheField() async throws {
        let resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-relative")

        await SessionSetupTests.expectRelativePathRefusal(naming: .cwd) {
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
    @Test(.timeLimit(.minutes(1)))
    func resumeWithARelativeAdditionalDirectoryAnswersInvalidParamsNamingTheField() async throws {
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-relative-extra")
        try await resume.runPrompt("one prompt before the resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        await SessionSetupTests.expectRelativePathRefusal(naming: .additionalDirectories) {
            _ = try await resume.fixture.harness.connection.resumeSession(
                resume.makeResumeRequest(
                    additionalDirectories: [
                        AbsolutePath(rawValue: Self.relativeAdditionalDirectory)
                    ]))
        }
        await resume.fixture.close()
    }

    // MARK: - The unknown-id policy (plan.md §10.1)

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
    func resumeAfterTheSessionDirectoryIsDeletedAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-deleted")
        try await resume.runPrompt("one prompt before the delete")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
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
        try await resume.runPrompt("one prompt before the mismatch")
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: sharedRoot, sessionId: resume.fixture.sessionId, count: 1)
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

    // MARK: - Replay as whole-message upserts (plan.md §7.4, §8.3)

    @Test(.timeLimit(.minutes(1)))
    func replayFromStartSendsWholeMessageUpsertsWithTheRecordedIds() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-replay")
        try await resume.runPrompt("first question")
        try await resume.runPrompt("second question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 2)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let expected = ReplayedMessage.expected(
            from: try ResumeSessionFixture.recordedEvents(
                under: root, sessionId: resume.fixture.sessionId))
        #expect(expected.count == 6)
        #expect(expected.map(\.kind).prefix(3) == [.user, .thought, .agent])
        #expect(expected.first?.text == "first question")

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
        // under the §8.3 replace row.
        let countBetween = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let secondUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBetween))
            .map(\.update)
        #expect(ReplayedMessage.replayed(in: secondUpdates) == expected)
        await resume.fixture.close()
    }

    /// A journal that holds a `repeatedPartRemoval` line replays no message
    /// for that line, and replays each recorded message around it. The line
    /// is Router's record of a cut in its own render after a repetition
    /// stop: bookkeeping, not a message.
    @Test(.timeLimit(.minutes(1)))
    func replaySendsNoMessageForARepeatedPartRemovalLine() async throws {
        var resume = try await ResumeSessionFixture.make(
            label: "SessionResumeTests-repeated-part")
        try await resume.runPrompt("first question")
        try await resume.runPrompt("second question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 2)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)
        let expected = ReplayedMessage.expected(
            from: try ResumeSessionFixture.recordedEvents(
                under: root, sessionId: resume.fixture.sessionId))
        try Self.insertRepeatedPartRemoval(under: root, sessionId: resume.fixture.sessionId)
        let recorded = try ResumeSessionFixture.recordedEvents(
            under: root, sessionId: resume.fixture.sessionId)
        #expect(recorded.contains { $0.kind == .repeatedPartRemoval })

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest(replayFrom: .start(ReplayFromStart())))
        let replayUpdates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)

        #expect(ReplayedMessage.replayed(in: replayUpdates) == expected)
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWithoutReplayFromSendsNoMessageUpserts() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-noreplay")
        try await resume.runPrompt("one prompt before the quiet resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())
        let updates = Array(await resume.fixture.collector.updates.dropFirst(countBefore))
            .map(\.update)
        #expect(ReplayedMessage.replayed(in: updates).isEmpty)
        await resume.fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWithAnUnknownReplayCursorAnswersInvalidParams() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-cursor")
        try await resume.runPrompt("one prompt before the unknown cursor")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
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

    // MARK: - The resumed conversation (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
    func aResumedSessionContinuesTheConversationWithTheEarlierContext() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-continue")
        try await resume.runPrompt("first question")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
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

    // MARK: - The root set (plan.md §7.2, §7.4)

    @Test(.timeLimit(.minutes(1)))
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
            under: root, sessionId: resume.fixture.sessionId, count: 1)
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

    @Test(.timeLimit(.minutes(1)))
    func resumingWithAnUnchangedRosterReportsNoMissingTools() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-complete")
        try await resume.runPrompt("one prompt before the clean resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        let response = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        #expect(Self.missingToolNames(of: response).isEmpty)
        await resume.fixture.close()
    }

    // MARK: - The instructions override (plan.md §7.4)

    @Test(.timeLimit(.minutes(1)))
    func resumingWithChangedInstructionsReachesTheModelAndWritesOneDivergenceEvent() async throws {
        let marker = "Always answer in iambic pentameter."
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-diverge")
        try await resume.runPrompt("one prompt before the instructions change")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
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

    @Test(.timeLimit(.minutes(1)))
    func resumingWithUnchangedInstructionsWritesNoDivergenceEvent() async throws {
        var resume = try await ResumeSessionFixture.make(label: "SessionResumeTests-samewords")
        try await resume.runPrompt("one prompt before the unchanged resume")
        let root = try resume.recordingRoot
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)

        _ = try await resume.fixture.harness.connection.resumeSession(
            resume.makeResumeRequest())

        let divergences = try Self.divergenceEvents(
            under: root, sessionId: resume.fixture.sessionId)
        #expect(divergences.isEmpty)
        await resume.fixture.close()
    }
}
