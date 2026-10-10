import Foundation
import FoundationModelsACP
import FoundationModelsExtras
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
}
