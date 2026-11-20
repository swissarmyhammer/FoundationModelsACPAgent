import FoundationModels
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The model transcript of an imported session (D209, Q83): ``ImportedTranscript`` makes a
/// FoundationModels `Transcript` from the updates of an `ACPImport` reader. Each user message
/// is a prompt, the agent messages of a turn are one response, each tool call is a short text
/// in the response, and the transcript holds no thought and no image.
@Suite struct ImportedTranscriptTests {
  // MARK: - Constants

  /// The text of the user message of each fixture.
  private static let question = "Fix the test."

  /// The id of the tool call of each fixture.
  private static let callID = "call-1"

  /// The title of the tool call of each fixture.
  private static let callTitle = "Bash: swift test"

  /// The size of the output of a tool call that the transcript keeps, in bytes.
  private static let outputLimit = 4096

  // MARK: - Fixtures

  /// A text update of a user message.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - messageID: The id of the message.
  /// - Returns: The update.
  private static func user(_ text: String, messageID: String = "u-1") -> SessionUpdate {
    .userMessageChunk(
      ContentChunk(content: .text(TextContent(text: text)), messageId: MessageId(rawValue: messageID)))
  }

  /// A text update of an agent message.
  ///
  /// - Parameters:
  ///   - text: The text.
  ///   - messageID: The id of the message.
  /// - Returns: The update.
  private static func agent(_ text: String, messageID: String = "a-1") -> SessionUpdate {
    .agentMessageChunk(
      ContentChunk(content: .text(TextContent(text: text)), messageId: MessageId(rawValue: messageID)))
  }

  /// The updates of one tool call that ends: its start, its output and its status.
  ///
  /// - Parameters:
  ///   - output: The text output of the call.
  ///   - status: The end status of the call.
  /// - Returns: The updates.
  private static func toolCall(output: String, status: ToolCallStatus = .completed)
    -> [SessionUpdate]
  {
    let id = ToolCallId(rawValue: callID)
    return [
      .toolCallUpdate(
        ToolCallUpdate(
          toolCallId: id, kind: .value(.execute), status: .value(.pending),
          title: .value(callTitle))),
      .toolCallContentChunk(
        ToolCallContentChunk(
          content: .content(Content(content: .text(TextContent(text: output)))), toolCallId: id)),
      .toolCallUpdate(ToolCallUpdate(toolCallId: id, status: .value(status))),
    ]
  }

  // MARK: - Tests

  @Test("a user message is a prompt, and the agent messages of its turn are one response")
  func aTurnIsAPromptAndAResponse() {
    let transcript = ImportedTranscript.make(
      from: [Self.user(Self.question), Self.agent("I look"), Self.agent(" at it.")])

    #expect(
      ImportedTranscriptReading.texts(of: transcript) == ["prompt: \(Self.question)", "response: I look at it."])
  }

  @Test("two agent messages of one turn are two paragraphs of one response")
  func twoAgentMessagesAreTwoParagraphs() {
    let transcript = ImportedTranscript.make(
      from: [
        Self.user(Self.question), Self.agent("First.", messageID: "a-1"),
        Self.agent("Second.", messageID: "a-2"),
      ])

    #expect(
      ImportedTranscriptReading.texts(of: transcript) == ["prompt: \(Self.question)", "response: First.\n\nSecond."])
  }

  @Test("a tool call is a short text in the response: its title, its status and its output")
  func aToolCallIsAShortText() {
    let transcript = ImportedTranscript.make(
      from: [Self.user(Self.question)] + Self.toolCall(output: "All tests passed."))

    #expect(
      ImportedTranscriptReading.texts(of: transcript) == [
        "prompt: \(Self.question)",
        "response: Tool \(Self.callTitle): completed\nAll tests passed.",
      ])
  }

  @Test("the output of a tool call is cut at 4 KB")
  func theOutputOfAToolCallIsCut() {
    let transcript = ImportedTranscript.make(
      from: [Self.user(Self.question)]
        + Self.toolCall(output: String(repeating: "x", count: Self.outputLimit * 2)))

    let header = "response: Tool \(Self.callTitle): completed\n"
    #expect(
      ImportedTranscriptReading.texts(of: transcript).last
        == header + String(repeating: "x", count: Self.outputLimit))
  }

  @Test("a thought of the agent is not in the transcript")
  func aThoughtIsNotInTheTranscript() {
    let thought = SessionUpdate.agentThoughtChunk(
      ContentChunk(content: .text(TextContent(text: "secret plan")), messageId: MessageId(rawValue: "t-1")))

    let transcript = ImportedTranscript.make(
      from: [Self.user(Self.question), thought, Self.agent("Done.")])

    #expect(ImportedTranscriptReading.texts(of: transcript) == ["prompt: \(Self.question)", "response: Done."])
  }

  @Test("an image is one line with its type")
  func anImageIsOneLineWithItsType() {
    let image = SessionUpdate.userMessageChunk(
      ContentChunk(
        content: .image(ImageContent(data: "AAAA", mimeType: MediaType(rawValue: "image/png"))),
        messageId: MessageId(rawValue: "u-1")))

    let transcript = ImportedTranscript.make(from: [Self.user(Self.question), image])

    #expect(
      ImportedTranscriptReading.texts(of: transcript) == ["prompt: \(Self.question)\n[image: image/png]"])
  }
}
