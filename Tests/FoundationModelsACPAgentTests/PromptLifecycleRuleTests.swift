import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The failure and cancel rules of the ACP v2 prompt lifecycle
/// (https://agentclientprotocol.com/protocol/v2/prompt-lifecycle).
///
/// - A prompt that fails sets each tool call that did not finish to `failed`.
///   Then it ends with an `idle` that has the `error` stop reason and the
///   `error` object `{code, message}`.
/// - A prompt that a cancel or an abort error stops ends with an `idle` that
///   has the `cancelled` stop reason and no `error` object. Each final update
///   comes before that `idle`.
///
/// Each test encodes the sent updates with the JSON codec of the transport
/// and reads the members that cross the wire.
@Suite struct PromptLifecycleRuleTests {
    // MARK: - Constants

    /// The id of the tool call that the scripted prompt opens and does not
    /// finish.
    private static let openCallId = "call-open"

    /// The id of the tool call that the scripted prompt opens and finishes.
    private static let finishedCallId = "call-finished"

    /// The tool name of the scripted tool calls.
    private static let toolName = "read_file"

    /// The arguments JSON of the scripted tool calls.
    private static let argumentsJSON = #"{"path":"notes.txt"}"#

    /// The text of the scripted failure. It is the description of the error,
    /// so the `message` of the wire error object holds it.
    private static let failureText = "the scripted stream failed"

    /// The JSON-RPC code of an internal error, as the wire number carries it.
    private static let internalErrorCode: Double = -32603

    /// The number of updates that the wire sends for the finished tool call:
    /// the creation and the completion.
    private static let finishedCallUpdateCount = 2

    /// The text that the scripted `.action` command streams before it fails.
    private static let actionText = "partial action output"

    /// The errors other than `CancellationError` that abort a prompt.
    private static let abortErrors: [any Error] = [URLError(.cancelled), CocoaError(.userCancelled)]

    // MARK: - Fixtures

    /// An error that no rule of the prompt maps, so the prompt fails.
    private struct ScriptedStreamFailure: Error, CustomStringConvertible {
        /// The text of the failure.
        var description: String { PromptLifecycleRuleTests.failureText }
    }

    /// The events of a prompt that opens two tool calls and finishes one of
    /// them.
    ///
    /// - Returns: The events, in order.
    private static func makeTwoToolCallEvents() -> [SessionEvent] {
        [
            makeSubmissionStarted(),
            .toolCall(id: openCallId, name: toolName, argumentsJSON: argumentsJSON),
            .toolCall(id: finishedCallId, name: toolName, argumentsJSON: argumentsJSON),
            .toolStatus(id: finishedCallId, status: .completed, summary: nil, output: nil),
        ]
    }

    /// The wire objects of `updates`, in send order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The members of each encoded update.
    /// - Throws: The encoding error, or a failed requirement when an update
    ///   does not encode as a JSON object.
    private static func wireObjects(
        of updates: [SessionUpdate]
    ) throws -> [[String: FoundationModelsACP.JSONValue]] {
        try updates.map { try #require(try wireObject(of: $0)) }
    }

    /// The wire objects of the updates of one tool call, in send order.
    ///
    /// - Parameters:
    ///   - toolCallId: The wire id of the tool call.
    ///   - wire: The wire objects of a prompt.
    /// - Returns: The wire objects that name the tool call.
    private static func updates(
        ofToolCall toolCallId: String, in wire: [[String: FoundationModelsACP.JSONValue]]
    ) -> [[String: FoundationModelsACP.JSONValue]] {
        wire.filter { jsonString(of: $0["toolCallId"]) == toolCallId }
    }

    // MARK: - An error

    /// A prompt that fails ends with the `error` stop reason and the `error`
    /// object: the code of an internal error, and the failure as the message.
    @Test func aFailedPromptEndsWithTheErrorStopReasonAndTheErrorObject() async throws {
        let (updates, reason) = await SyntheticPrompt.drive(
            [makeSubmissionStarted(), .textDelta("partial")], throwing: ScriptedStreamFailure())
        let idle = try #require(try Self.wireObjects(of: updates).last)
        let error = try #require(jsonObject(of: idle["error"]), "expected the error object, got \(idle)")

        #expect(reason == .error)
        #expect(jsonString(of: idle["state"]) == "idle")
        #expect(jsonString(of: idle["stopReason"]) == "error")
        #expect(error["code"] == .number(Self.internalErrorCode))
        #expect(jsonString(of: error["message"]) == Self.failureText)
    }

    /// A prompt that fails sets each tool call that did not finish to
    /// `failed`, and sends that update before the `idle`. A tool call that
    /// finished gets no other update.
    @Test func aFailedPromptFailsEachOpenToolCallBeforeTheIdle() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            Self.makeTwoToolCallEvents(), throwing: ScriptedStreamFailure())
        let wire = try Self.wireObjects(of: updates)
        let closing = try #require(wire.dropLast().last)

        #expect(jsonString(of: closing["sessionUpdate"]) == "tool_call_update")
        #expect(jsonString(of: closing["toolCallId"]) == Self.openCallId)
        #expect(jsonString(of: closing["status"]) == "failed")
        #expect(jsonString(of: wire.last?["stopReason"]) == "error")
        #expect(Self.updates(ofToolCall: Self.finishedCallId, in: wire).count == Self.finishedCallUpdateCount)
    }

    /// A failed `.action` command prompt ends with the `error` stop reason
    /// and the `error` object, after the text that the action streamed.
    @Test func aFailedActionCommandEndsWithTheErrorStopReasonAndTheErrorObject() async throws {
        let recorder = SinkRecorder()
        let send: SessionUpdateSink = { update in await recorder.append(update) }
        let execution = ActionCommandExecution(
            promptState: PromptStateOwner(send: send),
            send: send,
            action: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(Self.actionText)
                    continuation.finish(throwing: ScriptedStreamFailure())
                }
            },
            invocation: SlashCommand.Invocation(
                arguments: "", workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))

        await execution.run()
        let wire = try Self.wireObjects(of: await recorder.updates)
        let idle = try #require(wire.last)
        let error = try #require(jsonObject(of: idle["error"]), "expected the error object, got \(idle)")

        #expect(jsonString(of: wire.dropLast().last?["sessionUpdate"]) == "agent_message_chunk")
        #expect(jsonString(of: idle["stopReason"]) == "error")
        #expect(error["code"] == .number(Self.internalErrorCode))
        #expect(jsonString(of: error["message"]) == Self.failureText)
    }

    // MARK: - A cancel

    /// A cancel sets each tool call that did not finish to `cancelled`, and
    /// sends that final update before the `idle`. The `idle` has the
    /// `cancelled` stop reason and no `error` object.
    @Test func aCancelledPromptSendsEachFinalUpdateBeforeTheCancelledIdle() async throws {
        let updates = await SyntheticPrompt.sentUpdates(
            Self.makeTwoToolCallEvents(), throwing: CancellationError())
        let wire = try Self.wireObjects(of: updates)
        let closing = try #require(wire.dropLast().last)
        let idle = try #require(wire.last)

        #expect(jsonString(of: closing["toolCallId"]) == Self.openCallId)
        #expect(jsonString(of: closing["status"]) == "cancelled")
        #expect(jsonString(of: idle["stopReason"]) == "cancelled")
        #expect(idle["error"] == nil)
        #expect(Self.updates(ofToolCall: Self.finishedCallId, in: wire).count == Self.finishedCallUpdateCount)
    }

    /// An abort error other than `CancellationError` ends the prompt as a
    /// cancel: an `idle` with the `cancelled` stop reason and no `error`
    /// object, never an error.
    @Test(arguments: Self.abortErrors)
    func anAbortErrorEndsThePromptCancelled(abort: any Error) async throws {
        let (updates, reason) = await SyntheticPrompt.drive([makeSubmissionStarted()], throwing: abort)
        let idle = try #require(try Self.wireObjects(of: updates).last)

        #expect(reason == .cancelled)
        #expect(jsonString(of: idle["stopReason"]) == "cancelled")
        #expect(idle["error"] == nil)
    }
}
