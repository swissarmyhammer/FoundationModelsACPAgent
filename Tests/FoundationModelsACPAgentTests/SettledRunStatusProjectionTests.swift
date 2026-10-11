import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The terminal status of a settled run stays on the client (task ^531r4r0).
///
/// The SDK `toolCall` and `toolStatus` events of a call go on the same wire id
/// as the run events of the call (task ^e1yq4gh). The SDK `toolCall` event
/// comes after the SDK call returned, thus after the settlement of an inline
/// run. The status of a settlement is the true end of the run: a run that
/// settled `failed` or `cancelled` must not end `completed` on the client, and
/// the client must not show `in_progress` for a run that is done. Thus after a
/// settlement, the SDK updates of the call send no `status`.
///
/// Each test reads the updates through the JSON codec of the transport, and
/// the client status through the merge of the client.
@Suite struct SettledRunStatusProjectionTests {
    // MARK: - Constants

    /// The completion token of the run: the correlation id of each run event.
    private static let runToken = "01SETTLEDRUNTOKEN000000001"

    /// The SDK tool-call id that Router joins to ``runToken``.
    private static let sdkCallId = "call-settled-1"

    /// The tool of the run.
    private static let toolName = "shell"

    /// The op of the run.
    private static let opName = "execute command"

    /// The arguments of the SDK call, as a JSON text.
    private static let argumentsJSON = #"{"command":"sleep 99"}"#

    /// The one-line summary that Router gives with the completed status.
    private static let summaryText = "the call returned"

    /// The fixed time of each record. The projection does not read it.
    private static let recordTime = Date(timeIntervalSince1970: 0)

    /// The wire value of the `in_progress` status.
    private static let inProgressWireValue = "in_progress"

    /// The wire value of the `completed` status.
    private static let completedWireValue = "completed"

    /// The wire value of the `failed` status.
    private static let failedWireValue = "failed"

    /// The wire value of the `cancelled` status.
    private static let cancelledWireValue = "cancelled"

    /// The SDK tool-call id of the one tool call of a scripted prompt. The
    /// scripted backend makes the ids by ordinal.
    private static let scriptedCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"

    // MARK: - Fixtures

    /// The open and the close invocation record of the run, joined to
    /// ``sdkCallId``.
    private static let records: [SessionEvent] = [
        .toolInvocation(record, toolCallID: sdkCallId),
        .toolInvocation(record.closed(at: recordTime), toolCallID: sdkCallId),
    ]

    /// The open invocation record of the run.
    private static let record = ToolInvocationRecord(
        tool: toolName, op: opName, correlationID: runToken, sessionID: ULID.generate(), openedAt: recordTime)

    /// The SDK events of the call: the announcement, the running status and
    /// the completed status, in the order of the transcript diff.
    private static let sdkCallEvents: [SessionEvent] = [
        .toolCall(id: sdkCallId, name: toolName, argumentsJSON: argumentsJSON),
        .toolStatus(id: sdkCallId, status: .running, summary: nil, output: nil),
        .toolStatus(id: sdkCallId, status: .completed, summary: summaryText, output: nil),
    ]

    /// The terminal event of the run.
    ///
    /// - Parameter outcome: How the run ended.
    /// - Returns: The event.
    private static func settlement(_ outcome: OperationOutcome) -> SessionEvent {
        .runSettled(
            OperationEvent(
                tool: toolName, op: opName, correlationID: runToken, kind: .completed, detail: "{}",
                outcome: outcome))
    }

    /// The events of an inline run that settles with `outcome` before the SDK
    /// call returns, in the order that a real Router stream gives them.
    ///
    /// - Parameter outcome: How the run ended.
    /// - Returns: The events.
    private static func inlineRunEvents(settlingWith outcome: OperationOutcome) -> [SessionEvent] {
        records + [settlement(outcome)] + sdkCallEvents
    }

    // MARK: - An inline run that settled

    /// An inline run that settles `timedOut`, then the SDK `toolCall` and
    /// `toolStatus` events: the one status on the wire is the `failed` status
    /// of the settlement. Thus the client ends `failed`, and no `in_progress`
    /// comes after the settlement.
    @Test func anInlineRunThatSettledFailedEndsFailedOnTheClient() async throws {
        let updates = await SyntheticPrompt.sentUpdates(Self.inlineRunEvents(settlingWith: .timedOut))

        #expect(try updates.wireStatuses(ofToolCall: Self.sdkCallId) == [Self.failedWireValue])
        #expect(updates.clientStatus(ofToolCall: Self.sdkCallId) == .failed)
    }

    /// An inline run that settles `cancelled`, then the SDK `toolCall` and
    /// `toolStatus` events: the client ends `cancelled`, and no `in_progress`
    /// comes after the settlement.
    @Test func anInlineRunThatSettledCancelledEndsCancelledOnTheClient() async throws {
        let updates = await SyntheticPrompt.sentUpdates(Self.inlineRunEvents(settlingWith: .cancelled))

        #expect(try updates.wireStatuses(ofToolCall: Self.sdkCallId) == [Self.cancelledWireValue])
        #expect(updates.clientStatus(ofToolCall: Self.sdkCallId) == .cancelled)
    }

    /// After a settlement, the SDK updates still send their other fields: the
    /// `toolCall` event sends the name and the raw input, and the completed
    /// `toolStatus` event sends the summary. The running `toolStatus` event
    /// has no field but its status, so it sends nothing.
    @Test func theSdkUpdatesAfterASettlementKeepTheirOtherFieldsAndDropAnEmptyUpdate() async throws {
        let updates = await SyntheticPrompt.sentUpdates(Self.inlineRunEvents(settlingWith: .failed))
        let calls = toolCallUpdates(in: updates).filter { $0.toolCallId.rawValue == Self.sdkCallId }

        #expect(calls.count == 3)
        let announcement = try #require(calls.dropFirst().first)
        #expect(announcement.name == .value(Self.toolName))
        #expect(announcement.rawInput != .unchanged)
        #expect(texts(in: try #require(calls.last).content) == [Self.summaryText])
    }

    // MARK: - A call that no run settled

    /// A call with no settlement keeps the current behavior: the SDK updates
    /// send their statuses, and the client ends with the status of the last
    /// `toolStatus` event.
    @Test func aCallWithNoSettlementEndsWithTheStatusOfToolStatus() async throws {
        let updates = await SyntheticPrompt.sentUpdates(Self.records + Self.sdkCallEvents)

        #expect(
            try updates.wireStatuses(ofToolCall: Self.sdkCallId) == [
                Self.inProgressWireValue, Self.inProgressWireValue, Self.completedWireValue,
            ])
        #expect(updates.clientStatus(ofToolCall: Self.sdkCallId) == .completed)
    }

    // MARK: - The real order of a Router stream

    /// A real Router stream of an inline run that times out. Extras ends the
    /// run as `timedOut` inside the settle period. The order on the wire is:
    /// the progress of the run, the settlement (`failed`), the text of the
    /// model, then the SDK `toolCall` and the two `toolStatus` events, which
    /// Router sends when the transcript diff of the pass goes out. Router
    /// derives `completed` for the call, because the call has an output. The
    /// client ends `failed`, and no `in_progress` comes after the settlement.
    @Test(.timeLimit(.minutes(1)))
    func aRealInlineRunThatTimesOutEndsFailedOnTheClient() async throws {
        let updates = try await RoutedPrompt.sentUpdates(
            script: Self.callScript(StallingTool.toolName), tools: [StallingTool()],
            label: "SettledRunStatusProjectionTests-inline")

        let statuses = try updates.wireStatuses(ofToolCall: Self.scriptedCallId)
        #expect(Array(statuses.drop { $0 != Self.failedWireValue }) == [Self.failedWireValue])
        #expect(updates.clientStatus(ofToolCall: Self.scriptedCallId) == .failed)
    }

    /// A real Router stream of a background run that fails after the call
    /// answered with its pending envelope. The order on the wire is: the
    /// progress of the run, the text of the model, the SDK `toolCall` and the
    /// two `toolStatus` events (the last one `completed`), and then the
    /// settlement (`failed`). The settlement comes last, so the client ends
    /// `failed`.
    @Test(.timeLimit(.minutes(1)))
    func aRealBackgroundRunThatFailsLaterEndsFailedOnTheClient() async throws {
        let updates = try await RoutedPrompt.sentUpdates(
            prompt: Self.callerPrompt, script: Self.callScript(LateFailingTool.toolName),
            tools: [LateFailingTool()], label: "SettledRunStatusProjectionTests-background")

        let statuses = try updates.wireStatuses(ofToolCall: Self.scriptedCallId)
        #expect(Array(statuses.suffix(2)) == [Self.completedWireValue, Self.failedWireValue])
        #expect(updates.clientStatus(ofToolCall: Self.scriptedCallId) == .failed)
    }

    /// The prompt of a real stream test. The script calls the tool only for
    /// a prompt that holds this text, so an answer that the mail of a
    /// background run starts does not call the tool again.
    private static let callerPrompt = RoutedPrompt.defaultPrompt

    /// The script of a prompt that calls `tool` one time and then ends. Only
    /// the caller prompt calls the tool (``callerPrompt``).
    ///
    /// - Parameter tool: The name of the tool that the model calls.
    /// - Returns: The script.
    private static func callScript(_ tool: String) -> [ScriptedPassStep] {
        [
            .onPrompt(containing: callerPrompt, play: [.toolCall(name: tool, argumentsJSON: "{}")]),
            .textDelta(summaryText),
            .endPass,
        ]
    }

    // MARK: - The scripted tools

    /// The failure of a scripted tool.
    enum ScriptedToolError: Error {
        /// The tool failed on purpose.
        case failedOnPurpose
    }

    /// A background tool whose run makes no progress, so its mount ends the
    /// run as `timedOut` inside the settle period: an inline run that fails.
    struct StallingTool: FoundationModels.Tool, BackgroundTool {
        /// The wire arguments; the tool reads nothing from them.
        @Generable
        struct Arguments {}

        /// The name of the tool.
        static let toolName = "stall"

        /// The time with no progress, in seconds, after which the mount ends
        /// the run. It is much shorter than the default settle period.
        private static let timeoutSeconds: TimeInterval = 0.2

        /// The time that the body waits. The mount cancels the body long
        /// before this time ends.
        private static let stall: Duration = .seconds(30)

        let name = Self.toolName

        let description = "a scripted tool that makes no progress"

        var mount: ToolMount? { ToolMount(mode: .background, timeout: Self.timeoutSeconds) }

        func call(arguments: Arguments) async throws -> String {
            try await Task.sleep(for: Self.stall)
            return Self.toolName
        }
    }

    /// A background tool that answers with its pending envelope at once, and
    /// whose run fails a short time later: a background run that settles
    /// after the SDK call returned.
    struct LateFailingTool: FoundationModels.Tool, BackgroundTool {
        /// The wire arguments; the tool reads nothing from them.
        @Generable
        struct Arguments {}

        /// The name of the tool.
        static let toolName = "fail_later"

        /// The time that the run works before it fails.
        private static let work: Duration = .milliseconds(300)

        let name = Self.toolName

        let description = "a scripted tool that fails after its call answered"

        var mount: ToolMount? { ToolMount(mode: .background) }

        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: Arguments) async throws -> String {
            try await Task.sleep(for: Self.work)
            throw ScriptedToolError.failedOnPurpose
        }
    }
}
