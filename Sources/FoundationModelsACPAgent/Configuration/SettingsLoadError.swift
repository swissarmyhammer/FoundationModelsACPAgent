import Foundation
import FoundationModelsExtras

/// The error of the last read of the `config.yaml` of one level, after the
/// file changed from outside and its new text did not read, render or parse
/// (ACPA-17).
///
/// The error holds no text of the file, because the file can hold a secret
/// value. A parse error gives the message of the parser with no line of the
/// parsed text (``parserMessage(_:hidingLinesOf:)``). A render error and a
/// read error give a fixed message, because the message of the template
/// engine can hold a part of the text or a rendered value.
public struct SettingsLoadError: Equatable, Sendable {
  /// The message of a text whose templates do not render.
  static let renderMessage = "The templates of the file do not render."

  /// The message of a file that the store cannot read as UTF-8 text.
  static let readMessage = "The file cannot be read as UTF-8 text."

  /// The mark of the column of a parse error, which the parser writes under
  /// its copy of the line of the error.
  private static let caret: Character = "^"

  /// The level of the file.
  public let level: SettingsLevel

  /// The path of the `config.yaml` of the level.
  public let path: String

  /// The 1-based line of the error, or `nil` when the error has no line.
  public let line: Int?

  /// The reason of the error.
  public let message: String

  /// Makes a load error.
  ///
  /// - Parameters:
  ///   - level: The level of the file.
  ///   - path: The path of the `config.yaml` of the level.
  ///   - line: The 1-based line of the error, or `nil`.
  ///   - message: The reason of the error.
  public init(level: SettingsLevel, path: String, line: Int?, message: String) {
    self.level = level
    self.path = path
    self.line = line
    self.message = message
  }

  /// Makes the load error of an error of a read of the file of a level.
  ///
  /// - Parameters:
  ///   - level: The level of the file.
  ///   - path: The path of the `config.yaml` of the level.
  ///   - error: The error of the read: a `LayeredYAMLDocumentError` of the
  ///     render or of the parse, or the error of the read of the file.
  init(level: SettingsLevel, path: String, error: any Error) {
    switch error as? LayeredYAMLDocumentError {
    case .malformed(_, let line, let message)?:
      self.init(level: level, path: path, line: line, message: message)
    case .renderingFailed?:
      self.init(level: level, path: path, line: nil, message: Self.renderMessage)
    case .fileNotReadable?, nil:
      self.init(level: level, path: path, line: nil, message: Self.readMessage)
    }
  }

  /// The message of a parser with no line of the parsed text.
  ///
  /// The message of the YAML parser ends with a copy of the line of the
  /// error and a line with a `^` under the column. This function removes
  /// each line of the message that is a line of `text`, each line of `^`
  /// only, and each empty line. It joins the lines that stay with a space.
  ///
  /// - Parameters:
  ///   - message: The message of the parser.
  ///   - text: The text that the parser read.
  /// - Returns: The message with no line of `text`.
  static func parserMessage(_ message: String, hidingLinesOf text: String) -> String {
    let hiddenLines = Set(trimmedLines(of: text))
    return trimmedLines(of: message)
      .filter { line in
        !line.isEmpty && !hiddenLines.contains(line) && !line.allSatisfy { $0 == caret }
      }
      .joined(separator: " ")
  }

  /// The lines of a text, each one with no white space at its ends.
  ///
  /// - Parameter text: The text.
  /// - Returns: The trimmed lines.
  private static func trimmedLines(of text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
