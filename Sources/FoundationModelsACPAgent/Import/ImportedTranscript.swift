import FoundationModels
import FoundationModelsACP

/// The model transcript of an imported session (D209, Q83): the FoundationModels `Transcript`
/// that the Router directory writes as the recording of the new session.
///
/// The transcript comes from the updates of an `ACPImport` reader:
///
/// - Each user message is one prompt. The text chunks of one message join with no separator.
/// - The agent messages and the tool calls after a prompt are one response. Each agent message
///   and each tool call is one paragraph of the response.
/// - A tool call is a short text: `Tool <title>: <status>`, then its text output on the next
///   lines, cut at ``outputLimit`` bytes.
/// - A thought of the agent is not in the transcript.
/// - An image is one line with its type: `[image: <type>]`.
/// - The other updates (plans, compactions, the state of the session) are not in the
///   transcript.
///
/// The transcript has no instructions entry. The restore of the new session gives the
/// instructions of its agent, and Router then puts them first in the model transcript.
enum ImportedTranscript {
  /// The most bytes of the text output of a tool call that the transcript keeps.
  static let outputLimit = 4096

  /// The text between two paragraphs of a response.
  static let paragraphSeparator = "\n\n"

  /// Makes the transcript of the updates of a reader.
  ///
  /// - Parameter updates: The updates of the source session, in the order of the file.
  /// - Returns: The transcript: a prompt for each user message, and a response for the agent
  ///   messages and the tool calls of each turn.
  static func make(from updates: [SessionUpdate]) -> Transcript {
    var builder = ImportedTranscriptBuilder()
    for update in updates {
      builder.add(update)
    }
    return Transcript(entries: builder.finishedEntries())
  }

  /// The text of an image: one line with its type.
  ///
  /// - Parameter image: The image.
  /// - Returns: The line, for example `[image: image/png]`.
  static func line(of image: ImageContent) -> String {
    "[image: \(image.mimeType.rawValue)]"
  }

  /// The text of a content block in the transcript: the text of a text block, the line of an
  /// image, and nothing for each other block.
  ///
  /// - Parameter block: The content block.
  /// - Returns: The text, or `nil` for a block that the transcript does not hold.
  static func text(of block: ContentBlock) -> String? {
    switch block {
    case .text(let text):
      text.text
    case .image(let image):
      line(of: image)
    case .audio, .resourceLink, .resource, .unknown:
      nil
    }
  }

  /// The start of a text, cut at ``outputLimit`` bytes of UTF-8 on the edge of a character.
  ///
  /// - Parameter text: The text.
  /// - Returns: The text when it is short enough, else its longest start that holds at most
  ///   ``outputLimit`` bytes.
  static func cut(_ text: String) -> String {
    guard text.utf8.count > outputLimit else { return text }
    var kept = ""
    var size = 0
    for character in text {
      size += character.utf8.count
      guard size <= outputLimit else { break }
      kept.append(character)
    }
    return kept
  }
}

/// The state of ``ImportedTranscript/make(from:)`` while it reads the updates.
private struct ImportedTranscriptBuilder {
  /// One paragraph of the response of the open turn.
  private enum Paragraph {
    /// The text of one agent message.
    case message(id: String, text: String)

    /// One tool call, by its id.
    case toolCall(id: String)
  }

  /// One tool call of the open turn.
  private struct ToolCall {
    /// The title of the call.
    var title = ""

    /// The status of the call, as it crosses the wire.
    var status = ToolCallStatus.pending.wireValue

    /// The text of the output of the call, one part for each content block.
    var output: [String] = []

    /// The short text of the call in the response.
    var text: String {
      let header = "Tool \(title): \(status)"
      let body = ImportedTranscript.cut(output.joined(separator: "\n"))
      return body.isEmpty ? header : header + "\n" + body
    }
  }

  /// The finished entries of the transcript, in order.
  private var entries: [Transcript.Entry] = []

  /// The id and the text of the user message that the open prompt holds, or `nil` when no
  /// prompt is open.
  private var prompt: (id: String, text: String)?

  /// The paragraphs of the response of the open turn, in order.
  private var paragraphs: [Paragraph] = []

  /// The tool calls of the open turn, by their id.
  private var toolCalls: [String: ToolCall] = [:]

  /// Reads one update.
  ///
  /// - Parameter update: The update.
  mutating func add(_ update: SessionUpdate) {
    switch update {
    case .userMessageChunk(let chunk):
      addUser(chunk)
    case .agentMessageChunk(let chunk):
      addAgent(chunk)
    case .toolCallUpdate(let call):
      addToolCall(call)
    case .toolCallContentChunk(let chunk):
      addToolOutput(chunk)
    case .agentThoughtChunk, .agentThought, .userMessage, .agentMessage, .stateUpdate,
      .terminalUpdate, .terminalOutputChunk, .planUpdate, .availableCommandsUpdate,
      .configOptionUpdate, .sessionInfoUpdate, .usageUpdate, .notice, .compactionUpdate,
      .compactionSummaryChunk, .subagentUpdate, .sessionMessage, .sessionMessageChunk, .unknown:
      // The model transcript holds no thought (Q83), and no plan, compaction or state of the
      // session. The readers of `ACPImport` give each message as chunks, never as a whole
      // message.
      break
    }
  }

  /// The entries of the transcript, with the open turn closed.
  ///
  /// - Returns: The entries.
  mutating func finishedEntries() -> [Transcript.Entry] {
    closePrompt()
    closeResponse()
    return entries
  }

  /// Reads a chunk of a user message. A chunk of a new message closes the open turn.
  ///
  /// - Parameter chunk: The chunk.
  private mutating func addUser(_ chunk: ContentChunk) {
    guard let text = ImportedTranscript.text(of: chunk.content) else { return }
    let id = chunk.messageId.rawValue
    guard let open = prompt, open.id == id else {
      closePrompt()
      closeResponse()
      prompt = (id, text)
      return
    }
    prompt = (id, Self.joined(open.text, text, isLine: Self.isImage(chunk.content)))
  }

  /// Reads a chunk of an agent message: the text adds to the paragraph of its message.
  ///
  /// - Parameter chunk: The chunk.
  private mutating func addAgent(_ chunk: ContentChunk) {
    guard let text = ImportedTranscript.text(of: chunk.content) else { return }
    closePrompt()
    let id = chunk.messageId.rawValue
    if case .message(let openID, let openText) = paragraphs.last, openID == id {
      paragraphs[paragraphs.count - 1] = .message(
        id: id, text: Self.joined(openText, text, isLine: Self.isImage(chunk.content)))
      return
    }
    paragraphs.append(.message(id: id, text: text))
  }

  /// Reads a change of a tool call: a new call is a paragraph of the response, and a known
  /// call takes its new title and its new status.
  ///
  /// - Parameter update: The change.
  private mutating func addToolCall(_ update: ToolCallUpdate) {
    closePrompt()
    let id = update.toolCallId.rawValue
    var call = openCall(id)
    if case .value(let title) = update.title { call.title = title }
    if case .value(let status) = update.status { call.status = status.wireValue }
    toolCalls[id] = call
  }

  /// Reads output of a tool call: the text of a content block adds to the output of the call.
  ///
  /// - Parameter chunk: The output.
  private mutating func addToolOutput(_ chunk: ToolCallContentChunk) {
    guard case .content(let content) = chunk.content,
      let text = ImportedTranscript.text(of: content.content)
    else { return }
    closePrompt()
    let id = chunk.toolCallId.rawValue
    var call = openCall(id)
    call.output.append(text)
    toolCalls[id] = call
  }

  /// The tool call with an id in the open turn. A new call starts a paragraph.
  ///
  /// - Parameter id: The id of the call.
  /// - Returns: The call.
  private mutating func openCall(_ id: String) -> ToolCall {
    if let call = toolCalls[id] { return call }
    paragraphs.append(.toolCall(id: id))
    return ToolCall()
  }

  /// Puts the open prompt in the entries.
  private mutating func closePrompt() {
    guard let open = prompt else { return }
    entries.append(.prompt(Transcript.Prompt(segments: [Self.segment(open.text)])))
    prompt = nil
  }

  /// Puts the response of the open turn in the entries, when the turn has a paragraph.
  private mutating func closeResponse() {
    defer {
      paragraphs = []
      toolCalls = [:]
    }
    let texts = paragraphs.map { paragraph in
      switch paragraph {
      case .message(_, let text): text
      case .toolCall(let id): toolCalls[id]?.text ?? ""
      }
    }
    guard !texts.isEmpty else { return }
    entries.append(
      .response(
        Transcript.Response(
          segments: [Self.segment(texts.joined(separator: ImportedTranscript.paragraphSeparator))])))
  }

  /// One text segment.
  ///
  /// - Parameter text: The text.
  /// - Returns: The segment.
  private static func segment(_ text: String) -> Transcript.Segment {
    .text(Transcript.TextSegment(content: text))
  }

  /// True when a content block is an image, whose text is a line of its own.
  ///
  /// - Parameter block: The block.
  /// - Returns: True for an image.
  private static func isImage(_ block: ContentBlock) -> Bool {
    guard case .image = block else { return false }
    return true
  }

  /// Two texts of one message, joined. A line of its own starts on a new line.
  ///
  /// - Parameters:
  ///   - first: The text before.
  ///   - second: The text after.
  ///   - isLine: True when `second` is a line of its own.
  /// - Returns: The joined text.
  private static func joined(_ first: String, _ second: String, isLine: Bool) -> String {
    guard isLine, !first.isEmpty, !first.hasSuffix("\n") else { return first + second }
    return first + "\n" + second
  }
}
