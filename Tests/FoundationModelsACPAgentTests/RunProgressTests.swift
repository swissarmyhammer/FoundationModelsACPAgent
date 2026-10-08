import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The progress of a run on the wire (task ^jwx92y8): a tool sends an update
/// during its call through `ToolContext.progress(_:plan:)`, Router sends it
/// live as `SessionEvent.runProgress`, and the agent sends it to the client.
///
/// - A progress event with a plan goes as one `plan_update` that holds the
///   full list of the plan.
/// - A progress event with no plan goes as a `tool_call_update` that holds
///   its text, on the tool call of the run.
/// - `session/resume` with `replayFrom: start` replays the last plan of each
///   plan id that the session recorded, and no plan of another session.
@Suite struct RunProgressTests {
    // MARK: - Constants

    /// The text line of the plan progress, which the model also gets.
    private static let planLine = "3 of 7 done"

    /// The text of the progress with no plan.
    private static let textLine = "812 lines"

    /// The id of the plan of the tests.
    private static let planId = "plan-1"

    /// The id of a second plan, which the session of another test makes.
    private static let otherPlanId = "plan-2"

    /// The tool name that Router stamps on each event of a code-mode run:
    /// a `tools.*` call posts under the tool of the outer run.
    private static let codeModeToolName = "runCode"

    /// The op of the outer code-mode run.
    private static let codeModeOpName = "run code"

    /// The completion token of the outer code-mode run: the correlation id
    /// of each event of its nested calls, and its tool call id.
    private static let outerRunToken = "01OUTERRUNCODETOKEN0000000"

    /// The name of the scripted tool that reports its progress.
    private static let reportingToolName = "report_progress"

    /// The text the model streams after the tool call.
    private static let replyText = "the tool reported"

    // MARK: - Fixtures

    /// The four entries of a plan, one for each status and each priority.
    ///
    /// - Parameter firstStatus: The status of the first entry.
    /// - Returns: The entries.
    private static func planEntries(firstStatus: PlanSnapshot.Status = .completed) -> [PlanSnapshot.Entry] {
        [
            PlanSnapshot.Entry(content: "read the spec", priority: .high, status: firstStatus),
            PlanSnapshot.Entry(content: "write the code", priority: .medium, status: .inProgress),
            PlanSnapshot.Entry(content: "write the docs", priority: .low, status: .pending),
            PlanSnapshot.Entry(content: "port to Linux", priority: .low, status: .cancelled),
        ]
    }

    /// The wire entries that ``planEntries(firstStatus:)`` must map to.
    ///
    /// - Parameter firstStatus: The wire status of the first entry.
    /// - Returns: The wire entries.
    private static func wireEntries(firstStatus: PlanEntryStatus = .completed) -> [PlanEntry] {
        [
            PlanEntry(content: "read the spec", priority: .high, status: firstStatus),
            PlanEntry(content: "write the code", priority: .medium, status: .inProgress),
            PlanEntry(content: "write the docs", priority: .low, status: .pending),
            PlanEntry(content: "port to Linux", priority: .low, status: .cancelled),
        ]
    }

    /// The wire plan update that holds `entries` for `planId`.
    ///
    /// - Parameters:
    ///   - entries: The full list of the plan.
    ///   - planId: The id of the plan.
    /// - Returns: The update.
    private static func wirePlan(_ entries: [PlanEntry], planId: String = planId) -> PlanUpdate {
        PlanUpdate(plan: .items(PlanItems(entries: entries, planId: PlanId(rawValue: planId))))
    }

    /// A progress event of the outer code-mode run.
    ///
    /// - Parameters:
    ///   - detail: The text line of the event.
    ///   - plan: The plan of the event, or `nil`.
    /// - Returns: The event.
    private static func codeModeProgress(_ detail: String, plan: PlanSnapshot? = nil) -> OperationEvent {
        OperationEvent(
            tool: codeModeToolName, op: codeModeOpName, correlationID: outerRunToken, kind: .progress,
            detail: detail, plan: plan)
    }

    /// The plan updates in the sequence, in order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The plan updates.
    private static func planUpdates(in updates: [SessionUpdate]) -> [PlanUpdate] {
        updates.compactMap { update in
            if case .planUpdate(let plan) = update { return plan }
            return nil
        }
    }

    /// Drives one synthetic prompt of `events` and gives the sent updates.
    ///
    /// - Parameter events: The events of the prompt.
    /// - Returns: The updates and the stop reason.
    private static func drive(_ events: [SessionEvent]) async -> (updates: [SessionUpdate], reason: StopReason) {
        let (execution, recorder) = makeSinkedExecution()
        let reason = await execution.drive(events: makeEventStream(events))
        return (await recorder.updates, reason)
    }

    // MARK: - The scripted tool

    /// The completion tokens that the scripted tool saw, in call order.
    actor TokenLog {
        /// The tokens, in call order.
        private(set) var tokens: [String] = []

        /// Appends one token.
        ///
        /// - Parameter token: The completion token of a call.
        func append(_ token: String) {
            tokens.append(token)
        }
    }

    /// The failure of the scripted tool when Router bound no tool context
    /// around its call.
    enum ReportingToolError: Error {
        /// No `ToolContext` was bound around the call.
        case noToolContext
    }

    /// A scripted tool that reports its progress one time through the tool
    /// context of its call, and records the completion token of the call.
    struct ProgressReportingTool: FoundationModels.Tool {
        /// The wire arguments; the tool reads nothing from them.
        @Generable
        struct Arguments {}

        let name = RunProgressTests.reportingToolName

        let description = "a scripted tool that reports its progress"

        /// The text line of the progress.
        let detail: String

        /// The plan of the progress, or `nil`.
        let plan: PlanSnapshot?

        /// The log of the completion token of each call.
        let tokens: TokenLog

        func call(arguments: Arguments) async throws -> String {
            guard let context = ToolContext.current else {
                throw ReportingToolError.noToolContext
            }
            await tokens.append(context.completionToken)
            await context.progress(detail, plan: plan)
            return detail
        }
    }

    /// Runs one prompt over a real routed session whose scripted model
    /// calls `tool` one time, and gives each update the prompt sent.
    ///
    /// - Parameters:
    ///   - tool: The tool the model calls.
    ///   - label: The directory label of the calling test.
    /// - Returns: The sent updates.
    /// - Throws: Whatever the profile or the session throws.
    private static func runPrompt(calling tool: ProgressReportingTool, label: String) async throws -> [SessionUpdate] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = makeScriptedModelLoader(script: [
            .toolCall(name: reportingToolName, argumentsJSON: "{}"),
            .textDelta(replyText),
            .endPass,
        ])
        let profile = try await makeStubProfile(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true), loader: loader)
        let session = profile.standard.makeBudgetedSession(
            instructions: "Call the tool.",
            workingDirectory: directory,
            recordingRoot: directory.appendingPathComponent("recordings", isDirectory: true),
            tools: [tool],
            compaction: CompactionConfiguration(),
            repetition: RepetitionConfiguration())
        let (execution, recorder) = makeSinkedExecution()
        await execution.run(session: session)
        await session.close()
        return await recorder.updates
    }

    // MARK: - A plan goes as one plan update

    /// A scripted tool calls `progress("3 of 7 done", plan:)`. The client
    /// gets one `plan_update` with the same entries, priorities, statuses
    /// and plan id.
    @Test(.timeLimit(.minutes(1)))
    func aToolPlanGoesToTheClientAsOnePlanUpdate() async throws {
        let tool = ProgressReportingTool(
            detail: Self.planLine, plan: PlanSnapshot(id: Self.planId, entries: Self.planEntries()),
            tokens: TokenLog())

        let updates = try await Self.runPrompt(calling: tool, label: "RunProgressTests-plan")

        #expect(Self.planUpdates(in: updates) == [Self.wirePlan(Self.wireEntries())])
    }

    /// A plan event sends no text of its own: the text line is for the
    /// model, and the plan is the update the client gets.
    @Test func aPlanEventSendsNoToolCallUpdate() async {
        let plan = PlanSnapshot(id: Self.planId, entries: Self.planEntries())

        let (updates, _) = await Self.drive([.runProgress(Self.codeModeProgress(Self.planLine, plan: plan))])

        #expect(toolCallUpdates(in: updates).isEmpty)
        #expect(Self.planUpdates(in: updates).count == 1)
    }

    /// Two plan updates with the same id: the client gets two full lists,
    /// and the second list replaces the first list.
    @Test func twoPlansWithTheSameIdSendTwoFullListsAndTheSecondReplacesTheFirst() async {
        let first = PlanSnapshot(id: Self.planId, entries: Self.planEntries(firstStatus: .inProgress))
        let second = PlanSnapshot(id: Self.planId, entries: Self.planEntries(firstStatus: .completed))

        let (updates, _) = await Self.drive([
            .runProgress(Self.codeModeProgress(Self.planLine, plan: first)),
            .runProgress(Self.codeModeProgress(Self.planLine, plan: second)),
        ])

        let expectedSecond = Self.wirePlan(Self.wireEntries(firstStatus: .completed))
        #expect(
            Self.planUpdates(in: updates) == [
                Self.wirePlan(Self.wireEntries(firstStatus: .inProgress)), expectedSecond,
            ])
        let merged = SessionMergeEngine(replaying: updates)
        #expect(merged.entry(withID: .plan(PlanId(rawValue: Self.planId)))?.kind == .plan(expectedSecond))
    }

    /// A plan and no output: the plan tells about a run, not about the
    /// generation of the model, so a prompt that generated nothing still
    /// ends with the honest `_no_output` stop reason.
    @Test func aPlanDoesNotChangeTheStopReasonOfAPromptThatGeneratedNothing() async {
        let plan = PlanSnapshot(id: Self.planId, entries: Self.planEntries())

        let (_, reason) = await Self.drive([
            .runProgress(Self.codeModeProgress(Self.planLine, plan: plan)),
            makeSubmissionEnded(TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: .nan)),
        ])

        #expect(reason == .unknown(PromptExecution.noOutputStopReasonValue))
    }

    // MARK: - A text progress goes as tool call content

    /// A scripted tool calls `progress("812 lines")` with no plan. The
    /// client gets a `tool_call_update` with that text, on the tool call id
    /// of the run: the completion token of the call.
    @Test(.timeLimit(.minutes(1)))
    func aToolTextProgressGoesToTheToolCallOfTheRun() async throws {
        let tokens = TokenLog()
        let tool = ProgressReportingTool(detail: Self.textLine, plan: nil, tokens: tokens)

        let updates = try await Self.runPrompt(calling: tool, label: "RunProgressTests-text")

        let token = try #require(await tokens.tokens.first)
        let progress = toolCallUpdates(in: updates).filter { texts(in: $0.content) == [Self.textLine] }
        #expect(progress.map(\.toolCallId) == [ToolCallId(rawValue: token)])
        #expect(Self.planUpdates(in: updates).isEmpty)
    }

    /// In code mode, a `tools.*` call posts under the tool name and the
    /// token of the outer run. The text goes to the tool call of the outer
    /// run, which its settlement updates too.
    @Test func aCodeModeTextProgressGoesToTheToolCallOfTheOuterRun() async throws {
        let settlement = OperationEvent(
            tool: Self.codeModeToolName, op: Self.codeModeOpName, correlationID: Self.outerRunToken,
            kind: .completed, detail: "{}", outcome: .succeeded)

        let (updates, _) = await Self.drive([
            .runProgress(Self.codeModeProgress(Self.textLine)), .runSettled(settlement),
        ])

        let calls = toolCallUpdates(in: updates)
        let progress = try #require(calls.first)
        #expect(texts(in: progress.content) == [Self.textLine])
        #expect(progress.status == .value(.inProgress))
        #expect(Set(calls.map(\.toolCallId)) == [ToolCallId(rawValue: Self.outerRunToken)])
    }

    // MARK: - The replay of the last plan (session/resume)

    /// A session that sent plans replays the last plan of each plan id on
    /// `session/resume` with `replayFrom: start`. The session was recorded
    /// outside the agent, so it has no retained history: the plans come
    /// from the Router journal, which writes each plan event at once.
    @Test(.timeLimit(.minutes(1)))
    func aResumeReplaysTheLastPlanOfEachPlanId() async throws {
        let resume = try await ResumeSessionFixture.make(label: "RunProgressTests-replay")
        let first = PlanSnapshot(id: Self.planId, entries: Self.planEntries(firstStatus: .inProgress))
        let last = PlanSnapshot(id: Self.planId, entries: Self.planEntries(firstStatus: .completed))
        let other = PlanSnapshot(id: Self.otherPlanId, entries: Self.planEntries(firstStatus: .pending))
        let recordedId = try await resume.recordSessionOutsideTheAgent(
            prompts: ["make a plan"],
            posting: [first, last, other].map { Self.codeModeProgress(Self.planLine, plan: $0) })

        let replay = try await Self.replay(of: recordedId, in: resume)

        #expect(
            Self.planUpdates(in: replay) == [
                Self.wirePlan(Self.wireEntries(firstStatus: .completed)),
                Self.wirePlan(Self.wireEntries(firstStatus: .pending), planId: Self.otherPlanId),
            ])
        await resume.fixture.close()
    }

    /// The client never gets a plan of a session that did not make it: a
    /// second session in the same recording root sent a plan, and the
    /// replay of the first session holds no plan.
    @Test(.timeLimit(.minutes(1)))
    func aResumeReplaysNoPlanOfAnotherSession() async throws {
        let resume = try await ResumeSessionFixture.make(label: "RunProgressTests-other-session")
        let quietId = try await resume.recordSessionOutsideTheAgent(prompts: ["no plan here"])
        _ = try await resume.recordSessionOutsideTheAgent(
            prompts: ["make a plan"],
            posting: [
                Self.codeModeProgress(
                    Self.planLine, plan: PlanSnapshot(id: Self.planId, entries: Self.planEntries()))
            ])

        let replay = try await Self.replay(of: quietId, in: resume)

        #expect(Self.planUpdates(in: replay).isEmpty)
        await resume.fixture.close()
    }

    /// Resumes `sessionId` with `replayFrom: start` and gives the updates of
    /// the replay.
    ///
    /// - Parameters:
    ///   - sessionId: The recorded session to resume.
    ///   - resume: The wired resume fixture.
    /// - Returns: The replayed updates.
    /// - Throws: Whatever the resume throws.
    private static func replay(
        of sessionId: SessionId, in resume: ResumeSessionFixture
    ) async throws -> [SessionUpdate] {
        let countBefore = await resume.fixture.collector.updates.count
        _ = try await resume.fixture.harness.connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: resume.fixture.cwd.path), sessionId: sessionId,
                replayFrom: .start(ReplayFromStart())))
        return Array(await resume.fixture.collector.updates.dropFirst(countBefore)).map(\.update)
    }
}
