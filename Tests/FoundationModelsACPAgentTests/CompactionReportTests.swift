import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The compaction report (plan.md §8.5, task ^e8hafh0): each Router compaction
/// shows as one `compaction_update` entry, keyed by one `compactionId`, and a
/// compaction changes only the model context. The ACP history keeps every
/// earlier message with its id, and a resume replays the compaction entry
/// from the retained history.
///
/// The automatic proofs drive the projection with a synthetic `compaction`
/// event. The manual proofs drive `/compact` over the wire against the seeded
/// ``CompactionStubBackend``, so Router runs a real fold.
struct CompactionReportTests {
    // MARK: - The scripted values

    /// The id of the synthetic automatic compaction.
    private static let automaticCompactionId = "01J9ZCOMPACTION0000000000A"

    /// The summary of the synthetic automatic compaction.
    private static let automaticSummary = "The model read three files and fixed one test."

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
    private static func compactionUpdates(in updates: [SessionUpdate]) -> [Unstable.CompactionUpdate] {
        updates.compactMap { update in
            guard case .compactionUpdate(let compaction)? = try? Unstable.SessionUpdate(update) else {
                return nil
            }
            return compaction
        }
    }

    /// The text of each text block in a summary.
    ///
    /// - Parameter summary: The summary patch.
    /// - Returns: The joined text, or `nil` when the patch carries no value.
    private static func summaryText(of summary: PatchField<[ContentBlock]>) -> String? {
        patchValue(summary).map(joinedText(of:))
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
        let (execution, recorder) = makeSinkedExecution()
        _ = await execution.drive(events: makeEventStream([.compaction(result)]))
        return await recorder.updates
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
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(
        label: String,
        shouldFail: Bool = false,
        phraseRepeat: Int = CompactionStubBackend.seedPhraseRepeat,
        workingDirectory: URL? = nil
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(
            loader: CompactionStubBackend.makeLoader(shouldFail: shouldFail, phraseRepeat: phraseRepeat),
            label: label,
            workingDirectory: workingDirectory)
    }

    /// Prompts `text` over the wire and waits for the prompt to end.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - fixture: The wired fixture.
    ///   - count: The number of prompts that end with this one.
    /// - Returns: The prompt response and the raw updates collected so far.
    /// - Throws: Whatever the prompt or the waits throw.
    @discardableResult
    private static func runPrompt(
        _ text: String, on fixture: ScriptedPromptFixture, count: Int
    ) async throws -> (response: PromptResponse, updates: [SessionUpdate]) {
        let response = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: text))
        let notifications = try await ScriptedPromptFixture.waitForIdle(fixture.collector, count: count)
        try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        return (response, notifications.map(\.update))
    }

    // MARK: - Automatic compaction (Router's compaction event)

    /// An automatic compaction that applied a summary sends one completed
    /// `compaction_update` keyed by Router's compaction id, with the summary,
    /// and then the `usage_update` with the new context use.
    @Test(.timeLimit(.minutes(1)))
    func anAutomaticCompactionSendsOneCompletedEntryWithItsSummary() async throws {
        let updates = await Self.project(
            CompactionResult(
                id: Self.automaticCompactionId, summary: Self.automaticSummary,
                tokensBefore: Self.tokensBefore, tokensAfter: Self.tokensAfter,
                stagesApplied: [Summarization.stageName]))

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
    @Test(.timeLimit(.minutes(1)))
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

    // MARK: - Manual compaction (/compact)

    /// `/compact` sends `in_progress` before the fold, then `completed` with
    /// the summary under the same id, then the `usage_update` with the new
    /// context use.
    @Test(.timeLimit(.minutes(1)))
    func manualCompactSendsInProgressThenCompletedWithTheSummary() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-manual")
        let (_, updates) = try await Self.runPrompt("/compact", on: fixture, count: 1)

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
    @Test(.timeLimit(.minutes(1)))
    func manualCompactShortfallSendsFailedWithTheReason() async throws {
        let fixture = try await Self.makeFixture(
            label: "CompactionReportTests-shortfall",
            phraseRepeat: CompactionStubBackend.oversizedPhraseRepeat)
        let (_, updates) = try await Self.runPrompt("/compact", on: fixture, count: 1)

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
    @Test(.timeLimit(.minutes(1)))
    func manualCompactFailureSendsFailedWithTheError() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-failure", shouldFail: true)
        let (_, updates) = try await Self.runPrompt("/compact", on: fixture, count: 1)

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
    @Test(.timeLimit(.minutes(1)))
    func aCancelledCompactionSendsCancelled() async throws {
        let recorder = SinkRecorder()
        let reporter = CompactionReporter(
            sessionId: SessionId(rawValue: syntheticSessionIdValue),
            send: { update in await recorder.append(update) })
        let compactionId = CompactionReporter.makeCompactionId()

        await reporter.reportStart(of: compactionId)
        await reporter.reportEnd(of: compactionId, throwing: CancellationError())

        let updates = await recorder.updates
        let compactions = Self.compactionUpdates(in: updates)
        #expect(compactions.map(\.status) == [.inProgress, .cancelled])
        #expect(compactions.allSatisfy { $0.compactionId == compactionId })
        let cancelled = try #require(compactions.last)
        #expect(patchValue(cancelled.error) == nil)
        #expect(updates.compactMap(usageReport(of:)).isEmpty)
    }

    // MARK: - The retained history

    /// A compaction changes only the model context: each message before it
    /// keeps its id and its content in the retained history, and the
    /// compaction is one more entry after them.
    @Test(.timeLimit(.minutes(1)))
    func earlierMessagesKeepTheirIdsAndContentAfterACompaction() async throws {
        let fixture = try await Self.makeFixture(label: "CompactionReportTests-history")
        try await Self.runPrompt(Self.earlierPrompt, on: fixture, count: 1)
        let before = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.history)
        let earlier = Self.messages(of: before)
        #expect(earlier.first?.text == Self.earlierPrompt)

        try await Self.runPrompt("/compact", on: fixture, count: 2)

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
    @Test(.timeLimit(.minutes(1)))
    func aResumeReplaysTheCompactionEntryAndTheEarlierMessages() async throws {
        let first = try await Self.makeFixture(label: "CompactionReportTests-resume")
        try await Self.runPrompt(Self.earlierPrompt, on: first, count: 1)
        let (_, liveUpdates) = try await Self.runPrompt("/compact", on: first, count: 2)
        let earlier = ReplayedMessage.live(in: liveUpdates)
        let liveCompaction = try #require(Self.compactionUpdates(in: liveUpdates).last)
        _ = try await first.harness.connection.closeSession(CloseSessionRequest(sessionId: first.sessionId))
        await first.close()

        let second = try await Self.makeFixture(
            label: "CompactionReportTests-resume-second", workingDirectory: first.cwd)
        let countBefore = await second.collector.updates.count
        _ = try await second.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: first.cwd.path), sessionId: first.sessionId,
                replayFrom: .start(ReplayFromStart())))
        let replay = Array(await second.collector.updates.dropFirst(countBefore)).map(\.update)

        #expect(ReplayedMessage.replayed(in: replay) == earlier)
        let replayed = Self.compactionUpdates(in: replay)
        #expect(replayed.count == 1)
        let compaction = try #require(replayed.first)
        #expect(compaction.compactionId == liveCompaction.compactionId)
        #expect(compaction.status == .completed)
        #expect(Self.summaryText(of: compaction.summary) == Self.summaryText(of: liveCompaction.summary))
        await second.close()
    }
}
