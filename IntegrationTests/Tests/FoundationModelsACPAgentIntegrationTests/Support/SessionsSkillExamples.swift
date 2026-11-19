import Foundation
import RegexBuilder

/// The examples of the built-in `sessions` skill that show text that the stack writes (D200): the
/// header of a message from a session, the two headers of a message from the user with a source
/// session, and the receipt words.
///
/// A test fills each example with the real facts of its scenario (the ids, the title and the
/// folder), and compares the result with the text that the stack wrote. The fill changes only the
/// values. The labels, the order of the lines, the notice and the fences stay as the skill writes
/// them, thus a difference in one of them makes the comparison fail.
struct SessionsSkillExamples {
  /// One code block of the skill.
  struct Example: Sendable {
    /// The lines of the block, with no fence of the block.
    let lines: [String]

    /// The first line of the block in backticks, so a failure message names the example.
    var name: String {
      "`\(lines.first ?? "")`"
    }
  }

  /// A failure to read an example of the skill.
  enum ReadError: Error, CustomStringConvertible {
    /// The skill has no example of the form.
    case missingExample(form: String)

    /// The skill has no list of receipt words after the line with the marker.
    case missingReceiptWords(marker: String)

    /// A line of an example has a form that the test cannot fill.
    case unreadableLine(example: String, line: String)

    /// A fact line of an example names a fact that the scenario does not give.
    case unknownFact(example: String, label: String)

    /// The text of the failure.
    var description: String {
      switch self {
      case .missingExample(let form):
        "The sessions skill has no example that starts with a line of the form `\(form)`."
      case .missingReceiptWords(let marker):
        "The sessions skill has no list of receipt words after `\(marker)`."
      case .unreadableLine(let example, let line):
        "The line `\(line)` of the sessions skill example \(example) has a form that the test cannot fill."
      case .unknownFact(let example, let label):
        "The sessions skill example \(example) has the fact line `\(label)`, which the sender of the test does not have."
      }
    }
  }

  // MARK: - Constants

  /// The form of the first line of the example of a message from a session.
  private static let sessionHeaderForm = "[message from session <id>]"

  /// The form of the first line of the example of a message from the user whose source session
  /// the directory knows.
  private static let knownSourceForm = "From the user, in <title> (<folder>)"

  /// The form of the first line of the example of a message from the user whose source session
  /// the directory does not know.
  private static let unknownSourceForm = "From the user, in the session <id>"

  /// The line of the skill that comes before the list of receipt words.
  private static let receiptWordsMarker = "Read the receipt word:"

  /// The fence character of a Markdown code block.
  private static let fenceCharacter: Character = "`"

  /// The fewest fence characters of a Markdown code block.
  private static let minimumFenceLength = 3

  /// The count of characters of a ULID in its text form.
  private static let ulidLength = 26

  /// A ULID in its text form: ``ulidLength`` characters of the Crockford base 32 alphabet.
  private static var ulidPattern: Regex<Substring> {
    Regex { Repeat(/[0-9A-HJKMNP-TV-Z]/, count: ulidLength) }
  }

  /// The first line of the example of a message from a session. The capture is the session id,
  /// a ULID.
  private static var sessionHeaderPattern: Regex<(Substring, Substring)> {
    Regex {
      "[message from session "
      Capture { ulidPattern }
      "]"
    }
  }

  /// A fact line of the example of a message from a session. The captures are the label and the
  /// value in its quotes.
  private static var factLinePattern: Regex<(Substring, Substring, Substring)> {
    /^([a-z ]+): "(.*)"$/
  }

  /// The header of a message from the user whose source session the directory knows. The
  /// captures are the title and the folder of the source session.
  private static var knownSourcePattern: Regex<(Substring, Substring, Substring)> {
    /^From the user, in (.+) \((.+)\)$/
  }

  /// The header of a message from the user whose source session the directory does not know. The
  /// capture is the id of the source session, a ULID.
  private static var unknownSourcePattern: Regex<(Substring, Substring)> {
    Regex {
      "From the user, in the session "
      Capture { ulidPattern }
    }
  }

  /// An item of a nested list of the body.
  private static var nestedItemPattern: Regex<Substring> {
    /^\s+- .*/
  }

  /// An item of the list of receipt words. The capture is the word.
  private static var receiptWordPattern: Regex<(Substring, Substring)> {
    /^\s+- `([a-z]+)`:/
  }

  // MARK: - The examples

  /// The lines of the body of the skill.
  private let lines: [String]

  /// The code blocks of the body, in order.
  private let examples: [Example]

  /// Reads the code blocks of the body of the skill. Each accessor reads its own example, thus a
  /// test fails only for the example that it compares.
  ///
  /// - Parameter body: The body of the `sessions` skill.
  init(body: String) {
    lines = body.components(separatedBy: "\n")
    examples = Self.codeBlocks(in: lines[...]).map(Example.init(lines:))
  }

  /// The example of a message from another session.
  ///
  /// - Returns: The example.
  /// - Throws: ``ReadError/missingExample(form:)`` when the skill has no such example.
  func sessionMessage() throws -> Example {
    try Self.example(
      in: examples, firstLineMatching: Self.sessionHeaderPattern, form: Self.sessionHeaderForm)
  }

  /// The example of a message from the user whose source session the directory knows.
  ///
  /// - Returns: The example.
  /// - Throws: ``ReadError/missingExample(form:)`` when the skill has no such example.
  func userMessageFromKnownSource() throws -> Example {
    try Self.example(
      in: examples, firstLineMatching: Self.knownSourcePattern, form: Self.knownSourceForm)
  }

  /// The example of a message from the user whose source session the directory does not know.
  ///
  /// - Returns: The example.
  /// - Throws: ``ReadError/missingExample(form:)`` when the skill has no such example.
  func userMessageFromUnknownSource() throws -> Example {
    try Self.example(
      in: examples, firstLineMatching: Self.unknownSourcePattern, form: Self.unknownSourceForm)
  }

  /// The receipt words of the skill, in the order of the skill.
  ///
  /// - Returns: The words.
  /// - Throws: ``ReadError/missingReceiptWords(marker:)`` when the skill has no such list.
  func receiptWords() throws -> [String] {
    try Self.receiptWords(in: lines)
  }

  // MARK: - The texts of the examples

  /// The text of the message in the example of a message from a session: the lines in the inner
  /// fence.
  ///
  /// - Returns: The text.
  /// - Throws: ``ReadError`` when the skill has no such example, or when the example has no inner
  ///   fence.
  func sessionMessageText() throws -> String {
    let sessionMessage = try sessionMessage()
    let fences = sessionMessage.lines.indices.filter {
      Self.fenceLength(of: sessionMessage.lines[$0]) != nil
    }
    guard let open = fences.first, let close = fences.last, open < close else {
      throw ReadError.unreadableLine(
        example: sessionMessage.name, line: sessionMessage.lines.last ?? "")
    }
    return sessionMessage.lines[(open + 1)..<close].joined(separator: "\n")
  }

  /// The text of the message in an example of a message from the user: the lines after the first
  /// blank line.
  ///
  /// - Parameter example: An example of a message from the user.
  /// - Returns: The text.
  /// - Throws: ``ReadError/unreadableLine(example:line:)`` when the example has no blank line.
  static func userMessageText(of example: Example) throws -> String {
    guard let blank = example.lines.firstIndex(where: \.isEmpty) else {
      throw ReadError.unreadableLine(example: example.name, line: example.lines.first ?? "")
    }
    return example.lines[(blank + 1)...].joined(separator: "\n")
  }

  // MARK: - The fill

  /// The example of a message from a session, filled with the facts of the real sender.
  ///
  /// - Parameters:
  ///   - senderID: The session id of the real sender.
  ///   - facts: The value of each fact of the real sender, by the label of its line.
  /// - Returns: The filled example.
  /// - Throws: ``ReadError`` when a line has a form that the test cannot fill, or names a fact
  ///   that `facts` does not give.
  func filledSessionMessage(senderID: String, facts: [String: String]) throws -> String {
    let example = try sessionMessage()
    let header = try Self.filled(
      example.lines.first ?? "", of: example, pattern: Self.sessionHeaderPattern,
      values: [senderID])
    let rest = try example.lines.dropFirst().map { line in
      guard let match = line.wholeMatch(of: Self.factLinePattern) else { return line }
      guard let fact = facts[String(match.output.1)] else {
        throw ReadError.unknownFact(example: example.name, label: String(match.output.1))
      }
      return Self.replacing([match.output.2], in: line, with: [fact])
    }
    return ([header] + rest).joined(separator: "\n")
  }

  /// The example of a message from the user whose source session the directory knows, filled
  /// with the title and the folder of the real source session.
  ///
  /// - Parameters:
  ///   - title: The name of the real source session.
  ///   - folder: The path of the working folder of the real source session.
  /// - Returns: The filled example.
  /// - Throws: ``ReadError`` when the skill has no such example, or when its first line has
  ///   another form.
  func filledUserMessageFromKnownSource(title: String, folder: String) throws -> String {
    try Self.filledFirstLine(
      of: try userMessageFromKnownSource(), pattern: Self.knownSourcePattern,
      values: [title, folder])
  }

  /// The example of a message from the user whose source session the directory does not know,
  /// filled with the id of the real source session.
  ///
  /// - Parameter sourceID: The id of the real source session.
  /// - Returns: The filled example.
  /// - Throws: ``ReadError`` when the skill has no such example, or when its first line has
  ///   another form.
  func filledUserMessageFromUnknownSource(sourceID: String) throws -> String {
    try Self.filledFirstLine(
      of: try userMessageFromUnknownSource(), pattern: Self.unknownSourcePattern,
      values: [sourceID])
  }

  // MARK: - The read

  /// The code blocks of `lines`, in order. A block starts at a line of three or more fence
  /// characters, and ends at a line of only fence characters that is not shorter.
  ///
  /// - Parameter lines: The lines of the body.
  /// - Returns: The lines of each block, with no fence of the block.
  private static func codeBlocks(in lines: ArraySlice<String>) -> [[String]] {
    guard let open = lines.firstIndex(where: { fenceLength(of: $0) != nil }),
      let length = fenceLength(of: lines[open]),
      let close = lines[(open + 1)...].firstIndex(where: { isClosingFence($0, length: length) })
    else {
      return []
    }
    return [Array(lines[(open + 1)..<close])] + codeBlocks(in: lines[(close + 1)...])
  }

  /// The count of fence characters at the start of `line`.
  ///
  /// - Parameter line: A line of the body.
  /// - Returns: The count, or `nil` when the line does not start a code block.
  private static func fenceLength(of line: String) -> Int? {
    let count = line.prefix { $0 == fenceCharacter }.count
    return count >= minimumFenceLength ? count : nil
  }

  /// Tells whether `line` closes a code block that opened with `length` fence characters.
  ///
  /// - Parameters:
  ///   - line: A line of the body.
  ///   - length: The count of fence characters of the line that opened the block.
  /// - Returns: `true` when the line is only fence characters, and not fewer than `length`.
  private static func isClosingFence(_ line: String, length: Int) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= length && trimmed.allSatisfy { $0 == fenceCharacter }
  }

  /// The first example whose first line matches `pattern`.
  ///
  /// - Parameters:
  ///   - examples: The code blocks of the skill.
  ///   - pattern: The form of the first line.
  ///   - form: The form of the first line in words, for the failure message.
  /// - Returns: The example.
  /// - Throws: ``ReadError/missingExample(form:)`` when no example matches.
  private static func example<Output>(
    in examples: [Example], firstLineMatching pattern: Regex<Output>, form: String
  ) throws -> Example {
    let found = examples.first { example in
      example.lines.first.map { $0.wholeMatch(of: pattern) != nil } ?? false
    }
    guard let found else {
      throw ReadError.missingExample(form: form)
    }
    return found
  }

  /// The receipt words: the backtick word of each item of the list after
  /// ``receiptWordsMarker``.
  ///
  /// - Parameter lines: The lines of the body.
  /// - Returns: The words, in order.
  /// - Throws: ``ReadError/missingReceiptWords(marker:)`` when the body has no such list.
  private static func receiptWords(in lines: [String]) throws -> [String] {
    guard let marker = lines.firstIndex(where: { $0.contains(receiptWordsMarker) }) else {
      throw ReadError.missingReceiptWords(marker: receiptWordsMarker)
    }
    let words = lines[(marker + 1)...]
      .prefix { $0.wholeMatch(of: nestedItemPattern) != nil }
      .compactMap { $0.firstMatch(of: receiptWordPattern).map { String($0.output.1) } }
    guard !words.isEmpty else {
      throw ReadError.missingReceiptWords(marker: receiptWordsMarker)
    }
    return words
  }

  /// `example` with its first line filled, and its other lines as the skill writes them.
  ///
  /// - Parameters:
  ///   - example: The example.
  ///   - pattern: The form of the first line. Each capture is a value to fill.
  ///   - values: The real values, one for each capture, in order.
  /// - Returns: The filled example.
  /// - Throws: ``ReadError/unreadableLine(example:line:)`` when the first line has another form.
  private static func filledFirstLine<Output>(
    of example: Example, pattern: Regex<Output>, values: [String]
  ) throws -> String {
    let first = try filled(example.lines.first ?? "", of: example, pattern: pattern, values: values)
    return ([first] + example.lines.dropFirst()).joined(separator: "\n")
  }

  /// `line` with each capture of `pattern` replaced by its real value.
  ///
  /// - Parameters:
  ///   - line: A line of `example`.
  ///   - example: The example, for the failure message.
  ///   - pattern: The form of the line. Each capture is a value to fill.
  ///   - values: The real values, one for each capture, in order.
  /// - Returns: The filled line.
  /// - Throws: ``ReadError/unreadableLine(example:line:)`` when the line has another form.
  private static func filled<Output>(
    _ line: String, of example: Example, pattern: Regex<Output>, values: [String]
  ) throws -> String {
    guard let match = line.wholeMatch(of: pattern) else {
      throw ReadError.unreadableLine(example: example.name, line: line)
    }
    let captures = AnyRegexOutput(match).dropFirst().compactMap(\.substring)
    return replacing(captures, in: line, with: values)
  }

  /// `line` with each range replaced by its value. The last range is replaced first, so the
  /// ranges before it stay correct.
  ///
  /// - Parameters:
  ///   - parts: The parts of `line` to replace, in order.
  ///   - line: The line.
  ///   - values: The new text of each part, in order.
  /// - Returns: The changed line.
  private static func replacing(_ parts: [Substring], in line: String, with values: [String])
    -> String
  {
    zip(parts, values).reversed().reduce(line) { text, pair in
      text.replacingCharacters(in: pair.0.startIndex..<pair.0.endIndex, with: pair.1)
    }
  }
}
