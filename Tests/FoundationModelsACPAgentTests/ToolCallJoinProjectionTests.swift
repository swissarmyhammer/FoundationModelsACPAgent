import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// One tool run is one tool call on the wire (task ^e1yq4gh).
///
/// One tool run has two ids. The SDK `toolCall` and `toolStatus` events carry
/// the `Transcript.ToolCall.id`. The run events (the progress, the display
/// events, the attachment report and the settlement) carry the completion
/// token of the run. Router joins the two ids on the
/// `toolInvocation(record, toolCallID:)` event, and the projection sends each
/// update of the run on the joined SDK id. Thus the client sees one
/// `toolCallId` for each tool run.
///
/// Each test reads the updates through the JSON codec of the transport.
@Suite struct ToolCallJoinProjectionTests {
    // MARK: - Constants

    /// The completion token of the run: the correlation id of each run event.
    private static let runToken = "01JOINRUNTOKEN000000000001"

    /// The SDK tool-call id that Router joins to ``runToken``.
    private static let sdkCallId = "call-shell-1"

    /// The completion token of the second run of the parallel case.
    private static let secondRunToken = "01JOINRUNTOKEN000000000002"

    /// The SDK tool-call id of the second call of the parallel case.
    private static let secondSdkCallId = "call-shell-2"

    /// The tool of each run.
    private static let toolName = "shell"

    /// The op of each run.
    private static let opName = "execute command"

    /// The arguments of each SDK call, as a JSON text.
    private static let argumentsJSON = #"{"command":"ls"}"#

    /// The text of the progress of a run.
    private static let progressText = "listing the folder"

    /// The title that a metadata event of the tool gives the call.
    private static let toolTitle = "Run ls in /repo"

    /// The fixed time of each record. The projection does not read it.
    private static let recordTime = Date(timeIntervalSince1970: 0)

    // MARK: - Fixtures

    /// The open invocation record of a run, with the SDK id that Router joined.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - toolCallID: The joined SDK id, or `nil` when no call joined.
    /// - Returns: The event.
    private static func openRecord(_ token: String, toolCallID: String?) -> SessionEvent {
        .toolInvocation(record(token), toolCallID: toolCallID)
    }

    /// The close invocation record of a run, with the SDK id that Router joined.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - toolCallID: The joined SDK id, or `nil` when no call joined.
    /// - Returns: The event.
    private static func closeRecord(_ token: String, toolCallID: String?) -> SessionEvent {
        .toolInvocation(record(token).closed(at: recordTime), toolCallID: toolCallID)
    }

    /// The open invocation record of a run.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The record.
    private static func record(_ token: String) -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: toolName, op: opName, correlationID: token, sessionID: ULID.generate(),
            openedAt: recordTime)
    }

    /// One progress event of a run.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The event.
    private static func progress(_ token: String) -> SessionEvent {
        .runProgress(
            OperationEvent(
                tool: toolName, op: opName, correlationID: token, kind: .progress, detail: progressText))
    }

    /// The terminal event of a run that succeeded.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The event.
    private static func settlement(_ token: String) -> SessionEvent {
        .runSettled(
            OperationEvent(
                tool: toolName, op: opName, correlationID: token, kind: .completed, detail: "{}",
                outcome: .succeeded))
    }

    /// The SDK events of one call: the announcement and the running and the
    /// completed status, in the order of the transcript diff.
    ///
    /// - Parameter id: The SDK tool-call id.
    /// - Returns: The events.
    private static func sdkCall(_ id: String) -> [SessionEvent] {
        [
            .toolCall(id: id, name: toolName, argumentsJSON: argumentsJSON),
            .toolStatus(id: id, status: .running, summary: nil, output: nil),
            .toolStatus(id: id, status: .completed, summary: nil, output: nil),
        ]
    }

    /// The `toolCallId` of each update that has one, in send order. The
    /// value comes from the wire object, so each kind of tool-call update
    /// counts: a `tool_call_update` and a `tool_call_content_chunk`.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The wire tool-call ids.
    /// - Throws: The encoding error of an update.
    private static func wireToolCallIds(in updates: [SessionUpdate]) throws -> [String] {
        try updates.compactMap { jsonString(of: try wireObject(of: $0)?["toolCallId"]) }
    }

    /// The `toolCallId` of each `tool_call_update` that carries `text` as
    /// content, in send order.
    ///
    /// - Parameters:
    ///   - text: The content text to find.
    ///   - updates: The sent updates.
    /// - Returns: The tool-call ids.
    private static func toolCallIds(carrying text: String, in updates: [SessionUpdate]) -> [String] {
        toolCallUpdates(in: updates).filter { texts(in: $0.content).contains(text) }.map(\.toolCallId.rawValue)
    }

    // MARK: - One run, one tool call

    /// Each update of one inline run goes on one `toolCallId`: the progress,
    /// the content chunk, the attachment report, the SDK call and its two
    /// status updates. That id is the SDK id that Router joined.
    @Test func eachUpdateOfOneRunGoesOnTheJoinedSdkId() async throws {
        let report = ToolCallReport(
            tool: Self.toolName, op: Self.opName, correlationID: Self.runToken, sessionID: ULID.generate(),
            attachments: [ToolCallAttachment(schemaName: "note", contentJSON: #"{"note":"kept"}"#)])
        let events: [SessionEvent] =
            [
                Self.openRecord(Self.runToken, toolCallID: Self.sdkCallId),
                Self.progress(Self.runToken),
                .toolDisplay(
                    ToolDisplayEvent(
                        tool: Self.toolName, op: Self.opName, correlationID: Self.runToken,
                        kind: .contentChunk(.text(Self.progressText)))),
                Self.closeRecord(Self.runToken, toolCallID: Self.sdkCallId),
                .toolCallReport(report),
            ] + Self.sdkCall(Self.sdkCallId)

        let ids = try Self.wireToolCallIds(in: await SyntheticPrompt.sentUpdates(events))

        #expect(ids.count == 6)
        #expect(Set(ids) == [Self.sdkCallId])
    }

    /// A background run that settles after the SDK call completed and after
    /// the submission ended updates the same `toolCallId` as the SDK call.
    @Test func aBackgroundRunThatSettlesLaterUpdatesTheSameToolCallId() async throws {
        let events: [SessionEvent] =
            [
                Self.openRecord(Self.runToken, toolCallID: Self.sdkCallId),
                Self.closeRecord(Self.runToken, toolCallID: Self.sdkCallId),
            ] + Self.sdkCall(Self.sdkCallId) + [
                makeSubmissionEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: .nan)),
                Self.settlement(Self.runToken),
            ]

        let updates = await SyntheticPrompt.sentUpdates(events)
        let settlement = try #require(toolCallUpdates(in: updates).last)
        let ids = try Self.wireToolCallIds(in: updates)

        #expect(settlement.status == .value(.completed))
        #expect(settlement.toolCallId.rawValue == Self.sdkCallId)
        #expect(Set(ids) == [Self.sdkCallId])
    }

    /// A run that no SDK call joined keeps its completion token as its
    /// `toolCallId`, as before the join: for example a record that opens
    /// between two answers.
    @Test func aRunThatNoSdkCallJoinedKeepsItsCompletionToken() async throws {
        let ids = try Self.wireToolCallIds(
            in: await SyntheticPrompt.sentUpdates([
                Self.openRecord(Self.runToken, toolCallID: nil),
                Self.progress(Self.runToken),
                Self.settlement(Self.runToken),
            ]))

        #expect(ids == [Self.runToken, Self.runToken])
    }

    // MARK: - The title of the joined call

    /// The SDK `toolCall` event comes after the SDK call returned, thus after
    /// the run events of the call. The tool name of that event does not go
    /// over the title that a metadata event of the tool gave the call.
    @Test func theSdkCallDoesNotWriteItsNameOverAMetadataTitle() async throws {
        let events: [SessionEvent] =
            [
                Self.openRecord(Self.runToken, toolCallID: Self.sdkCallId),
                .toolDisplay(
                    ToolDisplayEvent(
                        tool: Self.toolName, op: Self.opName, correlationID: Self.runToken,
                        kind: .metadata(title: Self.toolTitle, kind: nil, locations: nil, rawInput: nil))),
                Self.progress(Self.runToken),
                Self.closeRecord(Self.runToken, toolCallID: Self.sdkCallId),
                Self.settlement(Self.runToken),
            ] + Self.sdkCall(Self.sdkCallId)

        let updates = await SyntheticPrompt.sentUpdates(events)

        #expect(try updates.lastWireTitle(ofToolCall: Self.sdkCallId) == Self.toolTitle)
    }

    // MARK: - The known limit of the join

    /// Router joins a record to an SDK call by the tool name alone. When one
    /// round calls one tool two times and the SDK runs the calls at the same
    /// time, the open records can arrive in the other order, and each run
    /// gets the SDK id of the other call. The projection does not correct
    /// that: it sends each run on the id that Router gave. Thus the client
    /// still sees one tool call for each run, but the progress of a run can
    /// show on the call that has the arguments of the other run.
    @Test func swappedJoinsOfOneToolInOneRoundKeepTheIdsThatRouterGave() async throws {
        let events: [SessionEvent] =
            [
                Self.openRecord(Self.secondRunToken, toolCallID: Self.sdkCallId),
                Self.openRecord(Self.runToken, toolCallID: Self.secondSdkCallId),
                Self.progress(Self.secondRunToken),
            ] + Self.sdkCall(Self.sdkCallId) + Self.sdkCall(Self.secondSdkCallId)

        let updates = await SyntheticPrompt.sentUpdates(events)
        let ids = try Self.wireToolCallIds(in: updates)

        #expect(Self.toolCallIds(carrying: Self.progressText, in: updates) == [Self.sdkCallId])
        #expect(Set(ids) == [Self.sdkCallId, Self.secondSdkCallId])
    }

    // MARK: - The terminal announce of a shell run (task ^9xk3xf4)

    /// The prompt events of one shell run that Router joined to ``sdkCallId``:
    /// the two records, the SDK call and the settlement.
    private static let joinedShellRunEvents: [SessionEvent] =
        [
            openRecord(runToken, toolCallID: sdkCallId),
            closeRecord(runToken, toolCallID: sdkCallId),
        ] + sdkCall(sdkCallId) + [settlement(runToken)]

    /// The live shell events of the run: one output chunk, then the
    /// completion marker.
    private static let liveShellEvents: [ShellOutputEvent] = [outputChunk(runToken), completionMarker(runToken)]

    /// The completion token of a shell run of an agent run. No projection of
    /// the root prompt sees a record of it.
    private static let agentShellRunToken = "01JOINAGENTSHELLRUN0000003"

    /// The completion token of the root run of the `agents` tool that started
    /// the agent run.
    private static let agentStartToken = "01JOINAGENTSTART0000000004"

    /// The SDK tool-call id that Router of an agent run joined to
    /// ``agentShellRunToken``. No wire update uses it.
    private static let agentSdkCallId = "call-agent-shell-3"

    /// The name of the `agents` tool of the session.
    private static let agentsToolName = "agents"

    /// The op of the `agents` call that starts an agent run.
    private static let agentStartOp = "start agent"

    /// The time between the first chunk of a run and its open record in the
    /// late-record case. It is longer than the one-second wait bound that an
    /// earlier version of the terminal stream had.
    private static let lateOpenRecordDelay: Duration = .milliseconds(1_500)

    /// The settlement of the root run of the `agents` tool: the agent run
    /// ended.
    private static let agentRunSettlement: SessionEvent = .runSettled(
        OperationEvent(
            tool: agentsToolName, op: agentStartOp, correlationID: agentStartToken, kind: .completed,
            detail: "{}", outcome: .succeeded))

    /// One output chunk of a run.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The live shell event.
    private static func outputChunk(_ token: String) -> ShellOutputEvent {
        ShellOutputEvent(commandID: token, kind: .output(stream: .stdout, bytes: Array(progressText.utf8)))
    }

    /// The completion marker of a run.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The live shell event.
    private static func completionMarker(_ token: String) -> ShellOutputEvent {
        ShellOutputEvent(commandID: token, kind: .completed)
    }

    /// The `toolCallId` of each `tool_call_update` that attaches the terminal
    /// of ``runToken``, in send order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The tool-call ids of the terminal announces.
    private static func terminalAnnounceIds(in updates: [SessionUpdate]) -> [String] {
        terminalAnnounceIds(of: runToken, in: updates)
    }

    /// The `toolCallId` of each `tool_call_update` that attaches the terminal
    /// of one run, in send order.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run, which is its terminal id.
    ///   - updates: The sent updates.
    /// - Returns: The tool-call ids of the terminal announces.
    private static func terminalAnnounceIds(of token: String, in updates: [SessionUpdate]) -> [String] {
        toolCallUpdates(in: updates).filter { terminalIds(in: $0.content) == [token] }.map(\.toolCallId.rawValue)
    }

    /// The terminal id of each output chunk, in send order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The terminal ids.
    private static func chunkTerminalIds(in updates: [SessionUpdate]) -> [String] {
        terminalChunks(in: updates).map(\.terminalId.rawValue)
    }

    /// The updates of a live session, as soon as an output chunk of one run
    /// is among them.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - session: The live session.
    /// - Returns: The updates that the session sent until then, in send
    ///   order.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the test is
    ///   cancelled before the chunk comes.
    private static func updatesUntilOutput(of token: String, in session: LiveShellSession) async throws -> [SessionUpdate] {
        try await session.recorder.updates(until: "an output chunk of the run \(token)") { updates in
            chunkTerminalIds(in: updates).contains(token)
        }
    }

    /// A joined shell run with live output gives exactly one `toolCallId` on
    /// the wire: the SDK id. The terminal stream announces the terminal on
    /// that id, and the terminal itself keeps the completion token.
    @Test func aJoinedShellRunWithLiveOutputGivesOnlyTheSdkId() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            Self.joinedShellRunEvents, shellEvents: Self.liveShellEvents, order: .promptFirst)

        #expect(Set(try Self.wireToolCallIds(in: updates)) == [Self.sdkCallId])
        #expect(Self.terminalAnnounceIds(in: updates) == [Self.sdkCallId])
        #expect(terminalChunks(in: updates).map(\.terminalId.rawValue) == [Self.runToken])
    }

    /// A chunk that comes before the prompt handled the open record gives the
    /// same result: the terminal stream waits for the join, and then sends one
    /// announce on the SDK id. It never sends on the completion token.
    @Test func aChunkBeforeTheOpenRecordStillGivesOnlyTheSdkId() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            Self.joinedShellRunEvents, shellEvents: Self.liveShellEvents, order: .terminalFirst)

        #expect(Set(try Self.wireToolCallIds(in: updates)) == [Self.sdkCallId])
        #expect(Self.terminalAnnounceIds(in: updates) == [Self.sdkCallId])
    }

    /// A shell run that no SDK call joined gets its announce on the
    /// completion token, as the run updates of the prompt do.
    @Test func anUnjoinedShellRunAnnouncesOnTheCompletionToken() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            [Self.openRecord(Self.runToken, toolCallID: nil), Self.settlement(Self.runToken)],
            shellEvents: Self.liveShellEvents, order: .promptFirst)

        #expect(Set(try Self.wireToolCallIds(in: updates)) == [Self.runToken])
        #expect(Self.terminalAnnounceIds(in: updates) == [Self.runToken])
    }

    /// A shell run that the prompt never records and never settles, for
    /// example a run of an agent run, does not stop the terminal stream: the
    /// end of the prompt stops the wait, and the announce goes on the
    /// completion token.
    @Test(.timeLimit(.minutes(1)))
    func aRunThatThePromptNeverSeesStillAnnouncesOnTheCompletionToken() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            [], shellEvents: Self.liveShellEvents, order: .terminalFirst)

        #expect(Self.terminalAnnounceIds(in: updates) == [Self.runToken])
        // The run exits once, whether its output went out as a chunk or, when
        // it waited, as the replacement of its exit report.
        #expect(terminalUpdates(in: updates).count == 1)
    }

    /// No time decides the join. An open record that comes long after the
    /// first chunk of its run still gives one wire id: the SDK id, for the
    /// terminal announce and for each update of the run.
    @Test(.timeLimit(.minutes(1)))
    func anOpenRecordLongAfterTheFirstChunkStillGivesOnlyTheSdkId() async throws {
        let session = LiveShellSession()
        session.send(Self.outputChunk(Self.runToken))
        try await Task.sleep(for: Self.lateOpenRecordDelay)
        for event in Self.joinedShellRunEvents {
            session.send(event)
        }
        session.send(Self.completionMarker(Self.runToken))

        let updates = await session.finish()

        #expect(Set(try Self.wireToolCallIds(in: updates)) == [Self.sdkCallId])
        #expect(Self.terminalAnnounceIds(in: updates) == [Self.sdkCallId])
    }

    /// The wait of one run does not stop the terminal stream. The output of
    /// a joined run goes out at once, while a run with no entry waits. When
    /// the entry of the waiting run comes, its announce and its output go out.
    @Test(.timeLimit(.minutes(1)))
    func aJoinedRunFlowsWhileAnUnjoinedRunWaitsForItsEntry() async throws {
        let session = LiveShellSession()
        session.runCallJoins.record(toolCallID: Self.sdkCallId, for: Self.runToken)
        session.send(Self.outputChunk(Self.secondRunToken))
        session.send(Self.outputChunk(Self.runToken))

        let joinedRunUpdates = try await Self.updatesUntilOutput(of: Self.runToken, in: session)
        session.runCallJoins.record(toolCallID: nil, for: Self.secondRunToken)
        let updates = await session.finish()

        #expect(Self.terminalAnnounceIds(in: joinedRunUpdates) == [Self.sdkCallId])
        #expect(Self.chunkTerminalIds(in: joinedRunUpdates) == [Self.runToken])
        #expect(Self.terminalAnnounceIds(of: Self.secondRunToken, in: updates) == [Self.secondRunToken])
        // The waiting run keeps no bytes, so its output never goes out as a
        // chunk.
        #expect(Self.chunkTerminalIds(in: updates) == [Self.runToken])
    }

    /// A shell run of an agent run does not hold up the terminal output of
    /// the root prompt. Its output waits for its entry. The open record of the
    /// run in the event stream of the agent run writes that entry (the run
    /// event observer of the agent environment, task ^zbcrex8), while the
    /// agent run continues. The announce goes on the completion token, also
    /// when Router of the agent run joined the record to an SDK call of the
    /// agent run: the agent run sends no wire update of its tool runs.
    @Test(.timeLimit(.minutes(1)))
    func anAgentShellRunGetsItsEntryFromItsOwnOpenRecord() async throws {
        let session = LiveShellSession()
        session.send(Self.openRecord(Self.runToken, toolCallID: Self.sdkCallId))
        session.send(Self.progress(Self.runToken))
        _ = try await session.recorder.updates(until: "the progress update of the root run") { updates in
            !Self.toolCallIds(carrying: Self.progressText, in: updates).isEmpty
        }
        session.send(Self.outputChunk(Self.agentShellRunToken))
        session.send(Self.outputChunk(Self.runToken))

        let rootUpdates = try await Self.updatesUntilOutput(of: Self.runToken, in: session)
        session.runCallJoins.recordAgentRunEvent(Self.openRecord(Self.agentShellRunToken, toolCallID: Self.agentSdkCallId))
        let agentUpdates = try await session.recorder.updates(until: "the announce of the agent shell run") { updates in
            !Self.terminalAnnounceIds(of: Self.agentShellRunToken, in: updates).isEmpty
        }
        _ = await session.finish()

        #expect(Self.terminalAnnounceIds(in: rootUpdates) == [Self.sdkCallId])
        #expect(Self.chunkTerminalIds(in: rootUpdates) == [Self.runToken])
        #expect(Self.terminalAnnounceIds(of: Self.agentShellRunToken, in: agentUpdates) == [Self.agentShellRunToken])
    }

    /// Only the open record of a tool run of an agent run writes an entry.
    /// A close record, and an event that is not a record, write nothing: the
    /// run still waits for its entry.
    @Test func onlyTheOpenRecordOfAnAgentRunWritesAnEntry() {
        let runCallJoins = RunCallJoinTable()
        runCallJoins.openPrompt()

        runCallJoins.recordAgentRunEvent(Self.closeRecord(Self.agentShellRunToken, toolCallID: nil))
        runCallJoins.recordAgentRunEvent(Self.progress(Self.agentShellRunToken))

        #expect(runCallJoins.announceToolCallId(for: Self.agentShellRunToken) == nil)
    }

    /// A root shell run that starts after an agent run ended keeps its SDK id.
    /// The first chunk of the root run comes before the projection handled
    /// the end of the agent run and the open record of the root run, as when
    /// the projection lags. The end of the agent run writes no entry, so the
    /// open record of the root run writes the SDK id, and the run gives one
    /// wire id.
    @Test(.timeLimit(.minutes(1)))
    func aRootShellRunThatStartsAfterAnAgentRunEndedKeepsItsSdkId() async throws {
        let session = LiveShellSession()
        session.runCallJoins.record(toolCallID: Self.secondSdkCallId, for: Self.secondRunToken)
        session.send(Self.outputChunk(Self.runToken))
        // The chunk of the joined second run goes out only after the terminal
        // stream read the chunk of the root run, which then waits.
        session.send(Self.outputChunk(Self.secondRunToken))
        _ = try await Self.updatesUntilOutput(of: Self.secondRunToken, in: session)
        session.send(Self.agentRunSettlement)
        _ = try await session.recorder.updates(until: "the settlement update of the agent run") { updates in
            toolCallUpdates(in: updates).contains { $0.toolCallId.rawValue == Self.agentStartToken }
        }
        for event in Self.joinedShellRunEvents {
            session.send(event)
        }
        session.send(Self.completionMarker(Self.runToken))

        let updates = await session.finish()

        #expect(Self.terminalAnnounceIds(in: updates) == [Self.sdkCallId])
        #expect(!(try Self.wireToolCallIds(in: updates)).contains(Self.runToken))
    }
}
