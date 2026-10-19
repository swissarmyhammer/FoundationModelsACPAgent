import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The compaction report (task ^e8hafh0): each Router compaction
/// shows as one `compaction_update` entry, keyed by one `compactionId`, and a
/// compaction changes only the model context. The ACP history keeps every
/// earlier message with its id, and a resume replays the compaction entry
/// from the retained history.
///
/// The automatic proofs drive the projection with synthetic Router events:
/// `compactionStarted`, then `compaction` or `compactionFailed` with the same
/// id (task ^fhwk6sn). The manual proofs drive `/compact` over the wire against
/// the seeded ``CompactionStubBackend``, so Router runs a real fold.
@Suite(.closesHarnesses) struct CompactionReportTests {
    // MARK: - The scripted values

    /// The id of the synthetic automatic compaction.
    private static let automaticCompactionId = "01J9ZCOMPACTION0000000000A"

    /// The summary of the synthetic automatic compaction.
    private static let automaticSummary = "The model read three files and fixed one test."

    /// The error text of the synthetic automatic compaction that failed.
    private static let automaticFailureText = "summarizerUnavailable"

    /// The context size before the synthetic compaction, in tokens.
    private static let tokensBefore = 900

    /// The context size after the synthetic compaction, in tokens.
    private static let tokensAfter = 300

    /// The input of the synthetic shortfall, in tokens.
    private static let shortfallInputTokens = 5000

    /// The summarizer window of the synthetic shortfall, in tokens.
    private static let shortfallWindowTokens = 4000

    /// The words that the reason of a window shortfall holds.
    private static let windowShortfallWords = "does not fit the window of any summarizer"

    /// The prompt that the history proofs send before `/compact`.
    private static let earlierPrompt = "first question"

    // MARK: - Readers

    /// The compaction updates in a sequence of session updates, in order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The compaction updates.
    private static func compactionUpdates(in updates: [SessionUpdate]) -> [CompactionUpdate] {
        updates.compactMap { update in
            guard case .compactionUpdate(let compaction) = update else {
                return nil
            }
            return compaction
        }
    }

    /// The text of the summary in a summary patch: its first text block. The
    /// last text block of a completed entry is the report of the fold
    /// (``CompactionReporter/reportText(of:)``).
    ///
    /// - Parameter summary: The summary patch.
    /// - Returns: The text of the first block, or `nil` when the patch
    ///   carries no value.
    private static func summaryText(of summary: PatchField<[ContentBlock]>) -> String? {
        patchValue(summary).map { blocks in joinedText(of: Array(blocks.prefix(1))) }
    }

    /// The joined text of the text blocks in `blocks`.
    ///
    /// - Parameter blocks: The content blocks.
    /// - Returns: The joined text.
    private static func joinedText(of blocks: [ContentBlock]) -> String {
        blocks.map { block in
            guard case .text(let text) = block else { return "" }
            return text.text
        }.joined()
    }

    /// The compaction entries of a retained history, in transcript order.
    ///
    /// - Parameter history: The retained history.
    /// - Returns: The compaction states.
    private static func compactionEntries(of history: SessionMergeEngine) -> [SessionEntry.Compaction] {
        history.entries.compactMap { entry in
            guard case .compaction(let compaction) = entry.kind else { return nil }
            return compaction
        }
    }

    /// The message entries of a retained history, in transcript order.
    ///
    /// - Parameter history: The retained history.
    /// - Returns: Each message as its kind, id and text.
    private static func messages(of history: SessionMergeEngine) -> [ReplayedMessage] {
        history.entries.compactMap { entry in
            switch entry.kind {
            case .userMessage(let message):
                ReplayedMessage(kind: .user, id: message.messageId.rawValue, text: joinedText(of: message.content))
            case .agentMessage(let message):
                ReplayedMessage(kind: .agent, id: message.messageId.rawValue, text: joinedText(of: message.content))
            case .agentThought(let message):
                ReplayedMessage(
                    kind: .thought, id: message.messageId.rawValue, text: joinedText(of: message.content))
            default:
                nil
            }
        }
    }

    // MARK: - Fixtures

    /// Projects one synthetic `compaction` event and returns what it sent.
    ///
    /// - Parameter result: The compaction result the event carries.
    /// - Returns: The updates the prompt sent, in order.
    private static func project(_ result: CompactionResult) async -> [SessionUpdate] {
        await SyntheticPrompt.sentUpdates([.compaction(result)])
    }

    /// The `compactionStarted` event of the synthetic automatic compaction.
    ///
    /// - Returns: The event.
    private static func makeAutomaticStart() -> SessionEvent {
        .compactionStarted(CompactionStart(id: automaticCompactionId, reason: .triggerReached))
    }

    /// The `compactionFailed` event of the synthetic automatic compaction.
    ///
    /// - Parameter outcome: How the compaction ended.
    /// - Returns: The event.
    private static func makeAutomaticFailure(_ outcome: CompactionFailure.Outcome) -> SessionEvent {
        .compactionFailed(
            CompactionFailure(id: automaticCompactionId, reason: .triggerReached, outcome: outcome))
    }

    /// The completed result of the synthetic automatic compaction, with its
    /// summary.
    ///
    /// - Returns: The result.
    private static func makeAutomaticResult() -> CompactionResult {
        CompactionResult(
            id: automaticCompactionId, summary: automaticSummary,
            tokensBefore: tokensBefore, tokensAfter: tokensAfter,
            stagesApplied: [Summarization.stageName])
    }

    /// Wires an agent over the seeded compaction backend and opens one
    /// session.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - shouldFail: Whether the summarizer call throws.
    ///   - phraseRepeat: How many times the seed phrase repeats in one
    ///     segment.
    ///   - workingDirectory: The session working directory, or `nil` for a
    ///     fresh one.
    ///   - gate: The gate that each summarizer call waits at, or `nil`.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        label: String,
        shouldFail: Bool = false,
        phraseRepeat: Int = CompactionStubBackend.seedPhraseRepeat,
        workingDirectory: URL? = nil,
        gate: SummarizerGate? = nil
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(
            loader: CompactionStubBackend.makeLoader(
                shouldFail: shouldFail, phraseRepeat: phraseRepeat, gate: gate),
            label: label,
            workingDirectory: workingDirectory)
    }

    /// Waits until the collector of `fixture` holds the terminal entry of a
    /// compaction. The entry comes from the compaction events, after the end
    /// of the `/compact` command.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The raw updates collected so far.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForTerminalEntry(of fixture: ScriptedPromptFixture) async throws -> [SessionUpdate] {
        try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the terminal entry of the compaction"
        ) { updates in
            compactionUpdates(in: updates.map(\.update)).contains { $0.status != .inProgress }
        }.map(\.update)
    }

    /// Projects synthetic Router events through the history sink of the
    /// session of `fixture`, the sink that a prompt of the session sends
    /// through. Each update goes into the retained history and to the client.
    ///
    /// - Parameters:
    ///   - events: The events to project, in order.
    ///   - fixture: The wired fixture.
    private static func projectThroughHistory(_ events: [SessionEvent], of fixture: ScriptedPromptFixture) async {
        let send = fixture.harness.agent.boundHistorySink(for: fixture.sessionId)
        let execution = SyntheticExecution(send: send)
        _ = await execution.drive(events: makeEventStream(events))
    }

    /// Closes the session of `first`, which writes its history file, and
    /// resumes the session in a new agent over the same working directory.
    ///
    /// - Parameters:
    ///   - first: The fixture of the earlier agent.
    ///   - label: The directory label of the new agent.
    /// - Returns: The updates that the resume replayed, in order.
    /// - Throws: Whatever the close, the construction or the resume throws.
    private static func closeAndResume(
        _ first: ScriptedPromptFixture, label: String
    ) async throws -> [SessionUpdate] {
        _ = try await first.harness.connection.closeSession(CloseSessionRequest(sessionId: first.sessionId))
        await first.close()

        let second = try await makeFixture(label: label, workingDirectory: first.cwd)
        let countBefore = await second.collector.updates.count
        _ = try await second.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: first.cwd.path), sessionId: first.sessionId,
                replayFrom: .start(ReplayFromStart())))
        let replay = Array(await second.collector.updates.dropFirst(countBefore)).map(\.update)
        await second.close()
        return replay
    }

    // MARK: - Automatic compaction (Router's compaction events)

    /// The check of task ^9xs24pn: a compaction while no prompt is open
    /// reaches the client. The projector reads the events of the session
    /// for its whole life, so the compaction of a `compact` signal sends its
    /// `in_progress` entry and its terminal entry under the `SignalID`. The
    /// compaction is Router work, so the session goes `running` before the
    /// compaction, also with no prompt open (elicitation-plan task 2).
    @Test
    func aCompactionWithNoPromptOpenReachesTheClient() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta(Self.automaticSummary), .endPass], label: "CompactionReportTests-no-prompt")
        let promptUpdates = try await ScriptedPromptFixture.runPrompt(
            on: fixture, text: Self.earlierPrompt, count: 1)

        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let signal = session.compact()
        let updates = try await ScriptedPromptFixture.waitForUpdatesBeforeSettle(
            of: fixture.collector, toReach: "the terminal entry of the compaction"
        ) { updates in
            Self.compactionUpdates(in: updates.map(\.update)).contains { $0.status != .inProgress }
        }
        await fixture.close()

        let afterPrompt = Array(updates.dropFirst(promptUpdates.count)).map(\.update)
        let compactions = Self.compactionUpdates(in: afterPrompt)
        #expect(compactions.first?.status == .inProgress)
        #expect(compactions.count == 2)
        #expect(compactions.allSatisfy { $0.compactionId.rawValue == signal.description })
        #expect(isRunningState(afterPrompt.first { if case .stateUpdate = $0 { true } else { false } }))
    }

    /// An automatic compaction that applied a summary sends one completed
    /// `compaction_update` keyed by Router's compaction id, with the summary,
    /// and then the `usage_update` with the new context use.
    @Test
    func anAutomaticCompactionSendsOneCompletedEntryWithItsSummary() async throws {
        let updates = await Self.project(Self.makeAutomaticResult())

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.count == 1)
        let compaction = try #require(compactions.first)
        #expect(compaction.compactionId.rawValue == Self.automaticCompactionId)
        #expect(compaction.status == .completed)
        #expect(Self.summaryText(of: compaction.summary) == Self.automaticSummary)

        let compactionIndex = try #require(
            updates.firstIndex { !Self.compactionUpdates(in: [$0]).isEmpty })
        let usage = try #require(updates.dropFirst(compactionIndex + 1).compactMap(usageReport(of:)).first)
        #expect(usage.used == Self.tokensAfter)
        #expect(usage.size == Self.tokensBefore)
    }

    /// An automatic compaction that left the context as it was is a failed
    /// entry, and the error is the reason Router gave. The meter does not
    /// move, so no `usage_update` goes out for it.
    @Test
    func anAutomaticShortfallSendsAFailedEntryWithTheReason() async throws {
        let updates = await Self.project(
            CompactionResult(
                id: Self.automaticCompactionId, summary: nil,
                tokensBefore: Self.tokensBefore, tokensAfter: Self.tokensBefore, stagesApplied: [],
                shortfall: .inputFillsSummarizerWindow(
                    inputTokens: Self.shortfallInputTokens, windowTokens: Self.shortfallWindowTokens)))

        let compaction = try #require(Self.compactionUpdates(in: updates).first)
        #expect(compaction.status == .failed)
        let reason = try #require(patchValue(compaction.error))
        #expect(reason.contains(Self.windowShortfallWords))
        #expect(reason.contains("\(Self.shortfallInputTokens)"))
        #expect(updates.compactMap(usageReport(of:)).isEmpty)
    }

    /// An automatic compaction that Router announced sends `in_progress` at
    /// the start, then `completed` with the summary under the same id, then
    /// the `usage_update` with the new context use.
    @Test
    func anAutomaticCompactionSendsInProgressThenCompletedUnderOneId() async throws {
        let updates = await SyntheticPrompt.sentUpdates([Self.makeAutomaticStart(), .compaction(Self.makeAutomaticResult())])

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .completed])
        #expect(compactions.allSatisfy { $0.compactionId.rawValue == Self.automaticCompactionId })
        let completed = try #require(compactions.last)
        #expect(Self.summaryText(of: completed.summary) == Self.automaticSummary)
        let usage = try #require(updates.compactMap(usageReport(of:)).first)
        #expect(usage.used == Self.tokensAfter)
    }

    /// An automatic compaction that failed sends `in_progress`, then `failed`
    /// under the same id, with the error text Router gave. The context did
    /// not change, so no `usage_update` goes out.
    @Test
    func anAutomaticFailureSendsFailedWithTheErrorText() async throws {
        let updates = await SyntheticPrompt.sentUpdates([
            Self.makeAutomaticStart(), Self.makeAutomaticFailure(.failed(Self.automaticFailureText)),
        ])

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .failed])
        #expect(compactions.allSatisfy { $0.compactionId.rawValue == Self.automaticCompactionId })
        let failed = try #require(compactions.last)
        #expect(patchValue(failed.error) == CompactionReporter.failureText(Self.automaticFailureText))
        #expect(updates.compactMap(usageReport(of:)).isEmpty)
    }

    /// An automatic compaction that a cancel stopped sends `in_progress`, then
    /// `cancelled` under the same id, with no error and no `usage_update`.
    @Test
    func anAutomaticCancelSendsCancelled() async throws {
        let updates = await SyntheticPrompt.sentUpdates([Self.makeAutomaticStart(), Self.makeAutomaticFailure(.cancelled)])

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .cancelled])
        #expect(compactions.allSatisfy { $0.compactionId.rawValue == Self.automaticCompactionId })
        let cancelled = try #require(compactions.last)
        #expect(patchValue(cancelled.error) == nil)
        #expect(updates.compactMap(usageReport(of:)).isEmpty)
    }

    // MARK: - Manual compaction (/compact)

    /// `/compact` sends `in_progress` before the fold, then `completed` with
    /// the summary under the same id, then the `usage_update` with the new
    /// context use.
    @Test
    func manualCompactSendsInProgressThenCompletedWithTheSummary() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-manual")
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: "/compact", count: 1)
        // The reporter sends the `usage_update` after the completed entry, so
        // the wait is for that update, and not only for the entry.
        let updates = try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the usage update after the completed compaction entry"
        ) { updates in
            let sent = updates.map(\.update)
            guard let completed = sent.lastIndex(where: { !Self.compactionUpdates(in: [$0]).isEmpty }),
                Self.compactionUpdates(in: [sent[completed]]).first?.status != .inProgress
            else { return false }
            return sent.dropFirst(completed + 1).contains { usageReport(of: $0) != nil }
        }.map(\.update)

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .completed])
        #expect(Set(compactions.map(\.compactionId)).count == 1)
        let completed = try #require(compactions.last)
        let summary = try #require(Self.summaryText(of: completed.summary))
        #expect(!summary.isEmpty)

        let completedIndex = try #require(
            updates.lastIndex { !Self.compactionUpdates(in: [$0]).isEmpty })
        let usage = try #require(updates.dropFirst(completedIndex + 1).compactMap(usageReport(of:)).first)
        #expect(usage.used < usage.size)
        await fixture.close()
    }

    /// A `/compact` that Router could not carry out is a failed entry, and
    /// the error is the shortfall reason.
    @Test
    func manualCompactShortfallSendsFailedWithTheReason() async throws {
        let fixture = try await Self.makeFixture(
            label: "CompactionReportTests-shortfall",
            phraseRepeat: CompactionStubBackend.oversizedPhraseRepeat)
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: "/compact", count: 1)
        let updates = try await Self.waitForTerminalEntry(of: fixture)

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .failed])
        let failed = try #require(compactions.last)
        let reason = try #require(patchValue(failed.error))
        #expect(reason.contains(Self.windowShortfallWords))
        #expect(patchValue(failed.summary) == nil)
        await fixture.close()
    }

    /// A `/compact` whose summarizer throws is a failed entry, and the error
    /// names the failure.
    @Test
    func manualCompactFailureSendsFailedWithTheError() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-failure", shouldFail: true)
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: "/compact", count: 1)
        let updates = try await Self.waitForTerminalEntry(of: fixture)

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .failed])
        let failed = try #require(compactions.last)
        let reason = try #require(patchValue(failed.error))
        #expect(reason.contains("\(CompactionStubError.summarizerUnavailable)"))
        await fixture.close()
    }

    /// A compaction that a cancellation stopped is a cancelled entry: the
    /// `cancelled` update under the id of its `in_progress` update, with no
    /// error and no `usage_update`.
    ///
    /// The compaction is Router work, so the `idle` of the `/compact` prompt
    /// comes only when the compaction ends (elicitation-plan task 2). The
    /// gate holds the compaction, thus the test waits for the end of the
    /// prompt, not for an `idle`.
    @Test
    func aCancelledCompactionSendsCancelled() async throws {
        let gate = SummarizerGate()
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-cancelled", gate: gate)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/compact"))
        await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
        try await gate.waitForArrival(beforeSettleOf: fixture.collector)

        // Only `close` stops a running compaction (`mailbox.md`, section 5).
        _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))
        let updates = try await Self.waitForTerminalEntry(of: fixture)
        await fixture.close()

        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .cancelled])
        #expect(Set(compactions.map(\.compactionId)).count == 1)
        let cancelled = try #require(compactions.last)
        #expect(patchValue(cancelled.error) == nil)
        #expect(updates.compactMap(usageReport(of:)).isEmpty)
    }

    // MARK: - The retained history

    /// A compaction changes only the model context: each message before it
    /// keeps its id and its content in the retained history, and the
    /// compaction is one more entry after them.
    @Test
    func earlierMessagesKeepTheirIdsAndContentAfterACompaction() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-history")
        try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.earlierPrompt, count: 1)
        let before = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.history)
        let earlier = Self.messages(of: before)
        #expect(earlier.first?.text == Self.earlierPrompt)

        try await ScriptedPromptFixture.runPrompt(on: fixture, text: "/compact", count: 2)
        _ = try await Self.waitForTerminalEntry(of: fixture)

        let after = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.history)
        #expect(Array(Self.messages(of: after).prefix(earlier.count)) == earlier)
        let compaction = try #require(Self.compactionEntries(of: after).first)
        #expect(compaction.status == .completed)
        #expect(!compaction.summary.isEmpty)
        let compactionPosition = try #require(
            after.entries.firstIndex { $0.id == .compaction(compaction.compactionId) })
        #expect(compactionPosition >= earlier.count)
        await fixture.close()
    }

    /// A new agent resumes the session from the history file of the earlier
    /// agent, and the replay holds the compaction entry with its final
    /// status and summary, and each earlier message with its id.
    @Test
    func aResumeReplaysTheCompactionEntryAndTheEarlierMessages() async throws {
        let first = try await Self.makeFixture(label: "CompactionReportTests-resume")
        try await ScriptedPromptFixture.runPrompt(on: first, text: Self.earlierPrompt, count: 1)
        try await ScriptedPromptFixture.runPrompt(on: first, text: "/compact", count: 2)
        let liveUpdates = try await Self.waitForTerminalEntry(of: first)
        let earlier = ReplayedMessage.live(in: liveUpdates)
        let liveCompaction = try #require(Self.compactionUpdates(in: liveUpdates).last)

        let replay = try await Self.closeAndResume(first, label: "CompactionReportTests-resume-second")

        #expect(ReplayedMessage.replayed(in: replay) == earlier)
        let replayed = Self.compactionUpdates(in: replay)
        #expect(replayed.count == 1)
        let compaction = try #require(replayed.first)
        #expect(compaction.compactionId == liveCompaction.compactionId)
        #expect(compaction.status == .completed)
        #expect(Self.summaryText(of: compaction.summary) == Self.summaryText(of: liveCompaction.summary))
    }

    /// The updates of an automatic compaction go through the history sink of
    /// the session. Thus a new agent that resumes the session replays one
    /// compaction entry with the final status: `failed` with the error text,
    /// not the earlier `in_progress`.
    @Test
    func aResumeReplaysTheFinalStatusOfAnAutomaticCompaction() async throws {
        let first = try await Self.makeFixture(label: "CompactionReportTests-automatic-resume")
        try await ScriptedPromptFixture.runPrompt(on: first, text: Self.earlierPrompt, count: 1)
        await Self.projectThroughHistory(
            [Self.makeAutomaticStart(), Self.makeAutomaticFailure(.failed(Self.automaticFailureText))],
            of: first)

        let replay = try await Self.closeAndResume(first, label: "CompactionReportTests-automatic-resume-second")

        let replayed = Self.compactionUpdates(in: replay)
        #expect(replayed.count == 1)
        let compaction = try #require(replayed.first)
        #expect(compaction.compactionId.rawValue == Self.automaticCompactionId)
        #expect(compaction.status == .failed)
        #expect(patchValue(compaction.error) == CompactionReporter.failureText(Self.automaticFailureText))
    }
}
