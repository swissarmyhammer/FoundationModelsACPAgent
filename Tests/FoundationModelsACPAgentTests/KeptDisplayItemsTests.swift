import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The display items that a tool call keeps to its end (task ^f9wmtse).
///
/// The files tool of a `runCode` call posts a diff display event for each
/// changed file, and the client appends it to the content of the call. Each
/// later update of the call that is not a display event sends its content as
/// a full replace: the progress, the attachment report, the settlement and
/// the SDK `toolStatus` that completes the call. Each such replace keeps the
/// diff items of the call first, in their order, and puts its own items
/// after them. The terminal item of a shell settlement stays the same way. A
/// replace that adds no item sends no `content` field.
///
/// Each test reads the content that the client shows at the end: the client
/// merges each update, as ``SessionMergeEngine`` does.
@Suite struct KeptDisplayItemsTests {
  // MARK: - Constants

  /// The completion token of the `runCode` run.
  private static let runToken = "01KEPTDISPLAYRUNTOKEN00001"

  /// The SDK tool-call id that Router joins to ``runToken``.
  private static let sdkCallId = "call-run-code-1"

  /// The tool of the SDK call.
  private static let runCodeTool = "runCode"

  /// The tool inside the code that posts the diff.
  private static let filesTool = "files"

  /// The op of the run.
  private static let opName = "run code"

  /// The arguments of the SDK call, as a JSON text.
  private static let argumentsJSON = #"{"code":"files.write()"}"#

  /// The absolute file that the code writes.
  private static let changedPath = "/repo/notes.txt"

  /// The text of the file before the write.
  private static let oldFileText = "alpha\nbeta\n"

  /// The text of the file after the write.
  private static let newFileText = "alpha\ngamma\n"

  /// The text result of the `runCode` call.
  private static let resultText = "wrote /repo/notes.txt"

  /// The text of a progress event of the run.
  private static let progressText = "writing the file"

  /// The text that a tool display part gives.
  private static let displayText = "the tool replaced its content"

  /// The fixed time of each record. The projection does not read it.
  private static let recordTime = Date(timeIntervalSince1970: 0)

  /// The label of a diff item at ``changedPath``.
  private static let diffLabel = "diff \(changedPath)"

  /// The label of the terminal item of ``runToken``.
  private static let terminalLabel = "terminal \(runToken)"

  // MARK: - Fixtures

  /// The open invocation record of the run, joined to ``sdkCallId``.
  private static let openRecord = SessionEvent.toolInvocation(
    ToolInvocationRecord(
      tool: runCodeTool, op: opName, correlationID: runToken, sessionID: ULID.generate(),
      openedAt: recordTime),
    toolCallID: sdkCallId)

  /// The diff display event that the files tool posts in the run.
  private static let diffChunk = display(
    .contentChunk(.diff(path: changedPath, oldText: oldFileText, newText: newFileText)))

  /// A progress event of the run, with no plan.
  private static let progress = SessionEvent.runProgress(
    OperationEvent(
      tool: runCodeTool, op: opName, correlationID: runToken, kind: .progress,
      detail: progressText))

  /// A display event of the run.
  ///
  /// - Parameter kind: What the event tells the client.
  /// - Returns: The event.
  private static func display(_ kind: ToolDisplayEvent.Kind) -> SessionEvent {
    .toolDisplay(
      ToolDisplayEvent(tool: filesTool, op: opName, correlationID: runToken, kind: kind))
  }

  /// The terminal event of the run.
  ///
  /// - Parameter outcome: How the run ended.
  /// - Returns: The event.
  private static func settlement(_ outcome: OperationOutcome) -> SessionEvent {
    .runSettled(
      OperationEvent(
        tool: runCodeTool, op: opName, correlationID: runToken, kind: .completed, detail: "{}",
        outcome: outcome))
  }

  /// The SDK events of the call after its run settled: the announcement,
  /// the running status, and the completed status with `output`.
  ///
  /// - Parameter output: The output segments of the completed call.
  /// - Returns: The events.
  private static func sdkCompletion(output: [SegmentPayload]) -> [SessionEvent] {
    [
      .toolCall(id: sdkCallId, name: runCodeTool, argumentsJSON: argumentsJSON),
      .toolStatus(id: sdkCallId, status: .running, summary: nil, output: nil),
      .toolStatus(id: sdkCallId, status: .completed, summary: nil, output: output),
    ]
  }

  /// The SDK events of a call that completes with ``resultText``.
  private static let textCompletion = sdkCompletion(
    output: [.text(id: "segment-1", content: resultText)])

  /// A label for each content item that the client shows at the end for the
  /// call: `diff <path>` for a diff, `terminal <id>` for a terminal, and the
  /// text for a text item.
  ///
  /// - Parameter updates: The updates that the client merges.
  /// - Returns: The labels, in item order.
  private static func clientLabels(in updates: [SessionUpdate]) -> [String] {
    (updates.clientContent(ofToolCall: sdkCallId) ?? []).map(label(of:))
  }

  /// The label of one content item.
  ///
  /// - Parameter item: The content item.
  /// - Returns: The label.
  private static func label(of item: ToolCallContent) -> String {
    switch item {
    case .diff(let diff):
      let paths = diff.changes.map { change -> String in
        guard case .modify(let modified) = change.operation else { return "not a modify" }
        return modified.path.rawValue
      }
      return "diff " + paths.joined(separator: " ")
    case .terminal(let terminal):
      return "terminal \(terminal.terminalId.rawValue)"
    default:
      return texts(in: .value([item])).joined()
    }
  }

  // MARK: - The completion

  /// A `runCode` call that writes a file ends with the diff item of the
  /// file, then the text result.
  @Test func aRunCodeCallThatWritesAFileEndsWithTheDiffThenTheText() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.diffChunk, Self.settlement(.succeeded)] + Self.textCompletion)

    #expect(Self.clientLabels(in: updates) == [Self.diffLabel, Self.resultText])
  }

  /// The replay of the session history gives the same final content: the
  /// diff item stays, then the text result.
  @Test func theReplayKeepsTheDiffThenTheText() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.diffChunk, Self.settlement(.succeeded)] + Self.textCompletion)
    let replay = SessionMergeEngine(replaying: updates).replayUpdates(from: .start)

    #expect(Self.clientLabels(in: replay) == [Self.diffLabel, Self.resultText])
  }

  /// A call with no display item ends as before: the text result alone.
  @Test func aCallWithNoDisplayItemEndsWithTheTextAlone() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.settlement(.succeeded)] + Self.textCompletion)

    #expect(Self.clientLabels(in: updates) == [Self.resultText])
  }

  /// A completion that adds no item sends no `content` field, so the client
  /// keeps the diff item.
  @Test func aCompletionThatAddsNoItemKeepsTheDiff() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.diffChunk, Self.settlement(.succeeded)]
        + Self.sdkCompletion(output: []))

    #expect(Self.clientLabels(in: updates) == [Self.diffLabel])
  }

  // MARK: - The other replaces of the call

  /// A progress event after a diff keeps the diff item, then its text.
  @Test func aProgressAfterADiffKeepsTheDiffThenTheProgressText() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.diffChunk, Self.progress])

    #expect(Self.clientLabels(in: updates) == [Self.diffLabel, Self.progressText])
  }

  /// The note of a settlement after a diff comes after the diff item.
  @Test func aSettlementNoteAfterADiffComesAfterTheDiff() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.diffChunk, Self.settlement(.timedOut)])

    #expect(Self.clientLabels(in: updates) == [Self.diffLabel, "the run timed out"])
  }

  /// The attachment report after a diff keeps the diff item, then the
  /// documents of the report.
  @Test func anAttachmentReportAfterADiffKeepsTheDiffThenTheDocuments() async {
    let document = #"{"note":"kept"}"#
    let report = SessionEvent.toolCallReport(
      ToolCallReport(
        tool: Self.runCodeTool, op: Self.opName, correlationID: Self.runToken,
        sessionID: ULID.generate(),
        attachments: [ToolCallAttachment(schemaName: "note", contentJSON: document)]))
    let updates = await SyntheticPrompt.sentUpdates([Self.openRecord, Self.diffChunk, report])

    #expect(Self.clientLabels(in: updates) == [Self.diffLabel, document])
  }

  /// A content replace of the tool replaces the diff items too: the tool
  /// asked for that content, so the completion keeps no earlier diff.
  @Test func aContentReplaceOfTheToolDropsTheEarlierDiff() async {
    let updates = await SyntheticPrompt.sentUpdates(
      [
        Self.openRecord, Self.diffChunk, Self.display(.contentReplace([.text(Self.displayText)])),
        Self.settlement(.succeeded),
      ] + Self.textCompletion)

    #expect(Self.clientLabels(in: updates) == [Self.resultText])
  }

  // MARK: - The terminal

  /// The terminal item of a shell settlement stays when the SDK completion
  /// comes after it: the terminal item, then the text result.
  @Test func theTerminalOfAShellSettlementStaysAfterTheCompletion() async {
    let bytes = Array("done".utf8)
    let stored = ShellRawOutput(
      bytes: bytes, binaryDetected: false, truncated: false, storedByteCount: bytes.count)
    let snapshot = ShellOutputSnapshot(stdout: stored, stderr: stored)
    let updates = await SyntheticPrompt.sentUpdates(
      [Self.openRecord, Self.settlement(.succeeded)] + Self.textCompletion,
      shellSnapshot: { commandID in commandID == Self.runToken ? snapshot : nil })

    #expect(Self.clientLabels(in: updates) == [Self.terminalLabel, Self.resultText])
  }
}
