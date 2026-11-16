import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A background tool call stays busy until its run really ends.
///
/// A background tool can return its pending envelope in place of its result. The SDK then records
/// an output for the call, and Router sends `toolStatus(.completed)`. That status only tells that
/// the call returned. The work continues in the background. Thus the call stays `in_progress` on
/// the client, with `_meta.sah.backgroundRun.completionToken`, and readable content in place of the
/// envelope JSON. The settlement of the run later gives the final status on the same tool call id.
///
/// Each test reads the updates through the JSON codec of the transport, and the client state
/// through the merge of the client.
@Suite struct BackgroundRunStatusProjectionTests {
  // MARK: - Constants

  /// The completion token of the run: a ULID, as the envelope requires.
  private static let runToken = "01M7GBDPDZWDQ2WNB76FH80VA5"

  /// The SDK tool-call id that Router joins to ``runToken``.
  private static let sdkCallId = "call-background-1"

  /// The tool of the run.
  private static let toolName = "runCode"

  /// The tool whose calls start a child session, and that the holds bind to.
  private static let agentsToolName = "agents"

  /// The op of the run.
  private static let opName = "run code"

  /// The text that the run gives when it ends.
  private static let resultText = "the background work is done"

  /// The fixed time of each record. The projection does not read it.
  private static let recordTime = Date(timeIntervalSince1970: 0)

  /// The wire value of the `in_progress` status.
  private static let inProgressWireValue = "in_progress"

  /// The wire value of the `completed` status.
  private static let completedWireValue = "completed"

  /// The wire value of the `failed` status.
  private static let failedWireValue = "failed"

  /// The collect sentence of the envelope.
  private static let nextText = "Its result will arrive in this conversation as a message."

  // MARK: - Fixtures

  /// The rendered pending envelope of the run, as the tool returns it: the fields in the order of
  /// `PendingRunEnvelope.rendered`, and no character that JSON escapes.
  private static let renderedEnvelope =
    #"{"pending":true,"completionToken":"\#(runToken)","next":"\#(nextText)"}"#

  /// The open invocation record of the run.
  ///
  /// - Parameter tool: The tool of the run.
  /// - Returns: The record.
  private static func record(tool: String) -> ToolInvocationRecord {
    ToolInvocationRecord(
      tool: tool, op: opName, correlationID: runToken, sessionID: ULID.generate(),
      openedAt: recordTime)
  }

  /// The events of a background call up to its return: the open record, the progress that
  /// carries the envelope, the SDK events of the call that returned the envelope, and the close
  /// record.
  ///
  /// - Parameter tool: The tool of the run.
  /// - Returns: The events.
  private static func returnEvents(tool: String = toolName) -> [SessionEvent] {
    let record = record(tool: tool)
    return [
      .toolInvocation(record, toolCallID: sdkCallId),
      .runProgress(
        OperationEvent(
          tool: tool, op: opName, correlationID: runToken, kind: .progress,
          detail: renderedEnvelope)),
      .toolCall(id: sdkCallId, name: tool, argumentsJSON: "{}"),
      .toolStatus(id: sdkCallId, status: .running, summary: nil, output: nil),
      .toolStatus(
        id: sdkCallId, status: .completed, summary: nil,
        output: [.text(id: "segment-1", content: renderedEnvelope)]),
      .toolInvocation(record.closed(at: recordTime), toolCallID: sdkCallId),
    ]
  }

  /// The terminal event of the run.
  ///
  /// - Parameters:
  ///   - outcome: How the run ended.
  ///   - tool: The tool of the run.
  /// - Returns: The event.
  private static func settlement(
    _ outcome: OperationOutcome, tool: String = toolName
  ) -> SessionEvent {
    .runSettled(
      OperationEvent(
        tool: tool, op: opName, correlationID: runToken, kind: .completed, detail: resultText,
        outcome: outcome))
  }

  /// The events of a background call that returned its envelope, and whose run settles later.
  ///
  /// - Parameter outcome: How the run ended.
  /// - Returns: The events.
  private static func backgroundRunEvents(settlingWith outcome: OperationOutcome) -> [SessionEvent]
  {
    returnEvents() + [settlement(outcome)]
  }

  /// The completion tokens in `_meta.sah.backgroundRun` of each update of the call, in send order.
  ///
  /// - Parameter updates: The sent updates.
  /// - Returns: The tokens.
  /// - Throws: The encoding error of an update.
  private static func backgroundRunTokens(in updates: [SessionUpdate]) throws -> [String] {
    try updates.compactMap { try wireObject(of: $0) }
      .filter { jsonString(of: $0["toolCallId"]) == sdkCallId }
      .compactMap { object in
        guard case .object(let meta)? = object["_meta"],
          case .object(let sah)? = meta[SAH.metaKey],
          case .object(let run)? = sah["backgroundRun"]
        else {
          return nil
        }
        return jsonString(of: run["completionToken"])
      }
  }

  /// The texts of each content replace of the call, in send order.
  ///
  /// - Parameter updates: The sent updates.
  /// - Returns: The texts.
  private static func contentTexts(in updates: [SessionUpdate]) -> [String] {
    toolCallUpdates(in: updates)
      .filter { $0.toolCallId.rawValue == sdkCallId }
      .flatMap { texts(in: $0.content) }
  }

  // MARK: - The return of the envelope

  /// The call returns its envelope, and the run settles later: the call stays `in_progress`
  /// until the settlement, and then it ends `completed` on the same id.
  @Test func aCallThatReturnedItsEnvelopeStaysInProgressUntilItsRunSettles() async throws {
    let updates = await SyntheticPrompt.sentUpdates(
      Self.backgroundRunEvents(settlingWith: .succeeded))

    #expect(
      try updates.wireStatuses(ofToolCall: Self.sdkCallId) == [
        Self.inProgressWireValue, Self.inProgressWireValue, Self.inProgressWireValue,
        Self.inProgressWireValue, Self.completedWireValue,
      ])
  }

  /// The update at the return of the envelope carries the completion token of the run in
  /// `_meta.sah.backgroundRun.completionToken`.
  @Test func theReturnOfTheEnvelopeCarriesTheCompletionTokenInMeta() async throws {
    let updates = await SyntheticPrompt.sentUpdates(Self.returnEvents())

    #expect(try Self.backgroundRunTokens(in: updates) == [Self.runToken])
  }

  /// No update of the call shows the envelope JSON as its content.
  @Test func noUpdateOfTheCallShowsTheEnvelopeJson() async throws {
    let updates = await SyntheticPrompt.sentUpdates(Self.returnEvents())

    #expect(!Self.contentTexts(in: updates).contains(Self.renderedEnvelope))
  }

  /// The client shows readable text while the run continues.
  @Test func theClientShowsReadableTextWhileTheRunContinues() async throws {
    let updates = await SyntheticPrompt.sentUpdates(Self.returnEvents())

    #expect(
      texts(in: .value(updates.clientContent(ofToolCall: Self.sdkCallId) ?? [])) == [
        ACPEventTranslator.backgroundRunText
      ])
  }

  /// The settlement of a detached run replaces the content with the result text of the run.
  @Test func theSettlementOfADetachedRunShowsTheResultText() async throws {
    let updates = await SyntheticPrompt.sentUpdates(
      Self.backgroundRunEvents(settlingWith: .succeeded))

    #expect(
      texts(in: .value(updates.clientContent(ofToolCall: Self.sdkCallId) ?? [])) == [
        Self.resultText
      ])
  }

  /// The SDK records the `String` output of a tool as a structured segment: a JSON string literal
  /// whose value is the rendered envelope. That return also keeps the call `in_progress`, with the
  /// marker.
  @Test func anEnvelopeInAStructuredSegmentAlsoKeepsTheCallInProgress() async throws {
    let literal = try JSONEncoder().encode(Self.renderedEnvelope)
    let structured = try #require(String(data: literal, encoding: .utf8))
    var events = Self.returnEvents()
    events[4] = .toolStatus(
      id: Self.sdkCallId, status: .completed, summary: nil,
      output: [.structure(id: "segment-1", schemaName: "String", contentJSON: structured)])
    let updates = await SyntheticPrompt.sentUpdates(events)

    #expect(try Self.backgroundRunTokens(in: updates) == [Self.runToken])
  }

  /// A detached run that fails ends `failed` on the client, and no `completed` goes out.
  @Test func aDetachedRunThatFailsEndsFailedWithNoCompletedStatus() async throws {
    let updates = await SyntheticPrompt.sentUpdates(Self.backgroundRunEvents(settlingWith: .failed))

    #expect(
      try updates.wireStatuses(ofToolCall: Self.sdkCallId).filter {
        $0 != Self.inProgressWireValue
      } == [Self.failedWireValue])
  }

  // MARK: - The inline case

  /// A run that settles before its call returned the envelope gives exactly one `completed`,
  /// and the late envelope changes neither the status nor the content.
  @Test func aRunThatSettledBeforeTheEnvelopeReturnedEndsWithOneCompletedStatus() async throws {
    let events = Array(Self.returnEvents().prefix(2)) + [Self.settlement(.succeeded)]
      + Array(Self.returnEvents().dropFirst(2))
    let updates = await SyntheticPrompt.sentUpdates(events)

    #expect(
      try updates.wireStatuses(ofToolCall: Self.sdkCallId).filter {
        $0 != Self.inProgressWireValue
      } == [Self.completedWireValue])
  }

  /// A run that settles before its call returned the envelope keeps the result text of the
  /// settlement as its content.
  @Test func aRunThatSettledBeforeTheEnvelopeReturnedKeepsItsResultText() async throws {
    let events = Array(Self.returnEvents().prefix(2)) + [Self.settlement(.succeeded)]
      + Array(Self.returnEvents().dropFirst(2))
    let updates = await SyntheticPrompt.sentUpdates(events)

    #expect(
      texts(in: .value(updates.clientContent(ofToolCall: Self.sdkCallId) ?? [])) == [
        Self.resultText
      ])
  }

  // MARK: - The end of a prompt

  /// A prompt that fails while a detached run continues does not close the call of the run. The
  /// settlement of the run gives its status later.
  @Test func aFailedPromptDoesNotCloseTheCallOfADetachedRun() async throws {
    let updates = await SyntheticPrompt.sentUpdates(
      Self.returnEvents(), throwing: SyntheticFailure.failedOnPurpose)

    #expect(try !updates.wireStatuses(ofToolCall: Self.sdkCallId).contains(Self.failedWireValue))
  }

  /// The end of the projection closes the call of a detached run that did not settle: no
  /// settlement can come after the end, so the call must not stay `in_progress`.
  @Test func theEndOfTheProjectionCancelsTheCallOfAnOpenDetachedRun() async throws {
    let updates = await SyntheticPrompt.sentUpdates(Self.returnEvents())

    #expect(updates.clientStatus(ofToolCall: Self.sdkCallId) == .cancelled)
  }

  /// The error that ends a synthetic stream on purpose.
  enum SyntheticFailure: Error {
    /// The stream failed on purpose.
    case failedOnPurpose
  }

  // MARK: - The agents hold

  /// An `agents` call that returned its envelope gives exactly one final status: the status of
  /// its settlement, through the hold.
  @Test func anAgentsCallThatReturnedItsEnvelopeGivesExactlyOneFinalStatus() async throws {
    let (execution, recorder) = makeSinkedExecution()
    execution.runCallJoins.holds.bind(toolName: Self.agentsToolName) { _ in }
    await execution.drive(
      events: makeEventStream(
        Self.returnEvents(tool: Self.agentsToolName)
          + [Self.settlement(.succeeded, tool: Self.agentsToolName)]))
    let updates = await recorder.updates

    #expect(
      try updates.wireStatuses(ofToolCall: Self.sdkCallId).filter {
        $0 != Self.inProgressWireValue
      } == [Self.completedWireValue])
  }

  /// An `agents` call carries no `_meta.sah.backgroundRun`. ACP patches `_meta` by top-level
  /// key, so the marker would erase the link of the call to its child in `_meta.sah.agentRun`.
  @Test func anAgentsCallCarriesNoBackgroundRunMeta() async throws {
    let (execution, recorder) = makeSinkedExecution()
    execution.runCallJoins.holds.bind(toolName: Self.agentsToolName) { _ in }
    await execution.drive(events: makeEventStream(Self.returnEvents(tool: Self.agentsToolName)))
    let updates = await recorder.updates

    #expect(try Self.backgroundRunTokens(in: updates).isEmpty)
  }
}
