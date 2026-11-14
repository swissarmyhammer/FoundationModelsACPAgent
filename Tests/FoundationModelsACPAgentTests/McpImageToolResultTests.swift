import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import MCP
import Testing

@testable import FoundationModelsACPAgent

/// The image blocks of an MCP tool result go to the client in the tool call
/// content (task ^2m83vkk).
///
/// The model reads an MCP tool result as text, and that text holds only a
/// placeholder for an image. Under an ambient `ToolContext`, an MCP verb thus
/// also posts the ordered blocks of a result that has a block that is not
/// text, as one display chunk (`MCPToolContent.display`). Inside `runCode`, the
/// chunk comes under the run of the `runCode` call, as a file diff does. The
/// agent sends each block as one content item of the call, an image as an
/// image item with its data and its mime type. The call keeps these items to
/// its end, because the text result of the call cannot carry an image.
///
/// A text-only result posts no chunk, so its call ends as before.
///
/// Each test reads the content that the client shows at the end: the client
/// merges each update, as ``SessionMergeEngine`` does.
@Suite struct McpImageToolResultTests {
  // MARK: - Constants

  /// The completion token of the `runCode` run.
  private static let runToken = "01MCPIMAGERUNTOKEN00000001"

  /// The SDK tool-call id that Router joins to ``runToken``.
  private static let sdkCallId = "call-run-code-mcp-image"

  /// The tool of the SDK call.
  private static let runCodeTool = "runCode"

  /// The MCP verb inside the code that posts the chunk.
  private static let mcpTool = "screenshot"

  /// The op of the run.
  private static let opName = "run code"

  /// The arguments of the SDK call, as a JSON text.
  private static let argumentsJSON = #"{"code":"mcp.screenshot()"}"#

  /// The text block of the MCP result.
  private static let captionText = "the screen of the simulator"

  /// The base64 data of the first image block.
  private static let firstImageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="

  /// The base64 data of the second image block.
  private static let secondImageData = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQ=="

  /// The mime type of the first image block.
  private static let pngType = "image/png"

  /// The mime type of the second image block.
  private static let jpegType = "image/jpeg"

  /// The text result of the `runCode` call.
  private static let resultText = "took one screenshot"

  /// The fixed time of each record. The projection does not read it.
  private static let recordTime = Date(timeIntervalSince1970: 0)

  // MARK: - Fixtures

  /// The open invocation record of the run, joined to ``sdkCallId``.
  private static let openRecord = SessionEvent.toolInvocation(
    ToolInvocationRecord(
      tool: runCodeTool, op: opName, correlationID: runToken, sessionID: ULID.generate(),
      openedAt: recordTime),
    toolCallID: sdkCallId)

  /// The terminal event of the run, a success.
  private static let settlement = SessionEvent.runSettled(
    OperationEvent(
      tool: runCodeTool, op: opName, correlationID: runToken, kind: .completed, detail: "{}",
      outcome: .succeeded))

  /// The SDK events of the call after its run settled: the announcement,
  /// the running status, and the completed status with ``resultText``.
  private static let completion: [SessionEvent] = [
    .toolCall(id: sdkCallId, name: runCodeTool, argumentsJSON: argumentsJSON),
    .toolStatus(id: sdkCallId, status: .running, summary: nil, output: nil),
    .toolStatus(
      id: sdkCallId, status: .completed, summary: nil,
      output: [.text(id: "segment-1", content: resultText)]),
  ]

  /// The display chunk that an MCP verb posts for a result, in the form
  /// that `MCPTool` posts it.
  ///
  /// - Parameter blocks: The content blocks of the result, in order.
  /// - Returns: The display event of the run.
  private static func mcpChunk(_ blocks: [MCP.Tool.Content]) -> SessionEvent {
    let content = MCPToolContent(content: blocks, isError: false)
    return .toolDisplay(
      ToolDisplayEvent(
        tool: mcpTool, op: opName, correlationID: runToken,
        kind: .contentChunk(content.display)))
  }

  /// The events of one `runCode` call that posts `events` in its run, then
  /// settles and completes with ``resultText``.
  ///
  /// - Parameter events: The events that the run posts.
  /// - Returns: The events of the prompt.
  private static func call(posting events: [SessionEvent]) -> [SessionEvent] {
    [openRecord] + events + [settlement] + completion
  }

  /// The events of a call whose MCP result has a text block and an image
  /// block.
  private static let textAndImageCall = call(posting: [
    mcpChunk([
      .text(text: captionText, annotations: nil, _meta: nil),
      .image(data: firstImageData, mimeType: pngType, annotations: nil, _meta: nil),
    ])
  ])

  /// The labels of the content that the client shows at the end for
  /// ``textAndImageCall``: the text item, the image item, then the text
  /// result.
  private static let textAndImageLabels = [
    captionText, imageLabel(pngType, firstImageData), resultText,
  ]

  /// A label for each content item that the client shows at the end for the
  /// call: `image <mime type> <data>` for an image, and the text for a text
  /// item.
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
    if case .content(let wrapped) = item, case .image(let image) = wrapped.content {
      return imageLabel(image.mimeType.rawValue, image.data)
    }
    return texts(in: .value([item])).joined()
  }

  /// The label of an image item.
  ///
  /// - Parameters:
  ///   - mimeType: The mime type of the image.
  ///   - data: The base64 data of the image.
  /// - Returns: The label.
  private static func imageLabel(_ mimeType: String, _ data: String) -> String {
    "image \(mimeType) \(data)"
  }

  // MARK: - The live update

  /// A result with a text block and an image block ends with the text item
  /// and the image item of the result, then the text result of the call.
  @Test func aTextAndAnImageEndAsTheirItemsThenTheResultText() async {
    let updates = await SyntheticPrompt.sentUpdates(Self.textAndImageCall)

    #expect(Self.clientLabels(in: updates) == Self.textAndImageLabels)
  }

  /// A result with two images gives two image items, in the order of the
  /// result.
  @Test func twoImagesEndAsTwoImageItemsInOrder() async {
    let updates = await SyntheticPrompt.sentUpdates(
      Self.call(posting: [
        Self.mcpChunk([
          .image(data: Self.firstImageData, mimeType: Self.pngType, annotations: nil, _meta: nil),
          .image(data: Self.secondImageData, mimeType: Self.jpegType, annotations: nil, _meta: nil),
        ])
      ]))

    #expect(
      Self.clientLabels(in: updates) == [
        Self.imageLabel(Self.pngType, Self.firstImageData),
        Self.imageLabel(Self.jpegType, Self.secondImageData), Self.resultText,
      ])
  }

  /// A text-only result posts no chunk, so the call ends as before: the text
  /// result alone.
  @Test func aTextOnlyResultEndsWithTheResultTextAlone() async {
    let updates = await SyntheticPrompt.sentUpdates(Self.call(posting: []))

    #expect(Self.clientLabels(in: updates) == [Self.resultText])
  }

  // MARK: - The replay

  /// The replay of the session history gives the same final content as the
  /// live updates.
  @Test func theReplayGivesTheSameContentAsTheLiveUpdates() async {
    let updates = await SyntheticPrompt.sentUpdates(Self.textAndImageCall)
    let replay = SessionMergeEngine(replaying: updates).replayUpdates(from: .start)

    #expect(Self.clientLabels(in: replay) == Self.textAndImageLabels)
  }
}
