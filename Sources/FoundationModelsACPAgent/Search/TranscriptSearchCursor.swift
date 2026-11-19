import Foundation

/// The error of a search of the transcripts.
public enum TranscriptSearchError: Error, Equatable, CustomStringConvertible {
  /// The cursor of the request is not a cursor that a search gave.
  case invalidCursor

  /// The corrective of the error.
  public var description: String {
    switch self {
    case .invalidCursor:
      "The cursor is not a cursor of this search. Start again with no cursor."
    }
  }
}

/// The opaque cursor of the pages of a search of the transcripts: the offset of the first
/// session of the page (or of the first hit of a `session:` page), in a base64 text.
enum TranscriptSearchCursor {
  /// The text before the offset in the decoded cursor.
  private static let prefix = "transcript-search:"

  /// The cursor of an offset.
  ///
  /// - Parameter offset: The offset of the first item of the next page.
  /// - Returns: The cursor.
  static func cursor(of offset: Int) -> String {
    Data("\(prefix)\(offset)".utf8).base64EncodedString()
  }

  /// The offset of a cursor.
  ///
  /// - Parameter cursor: The cursor, or `nil` for the first page.
  /// - Returns: The offset: zero for no cursor.
  /// - Throws: ``TranscriptSearchError/invalidCursor`` for a text that ``cursor(of:)`` did not
  ///   give.
  static func offset(of cursor: String?) throws -> Int {
    guard let cursor else {
      return 0
    }
    guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8),
      text.hasPrefix(prefix), let offset = Int(text.dropFirst(prefix.count)), offset >= 0
    else {
      throw TranscriptSearchError.invalidCursor
    }
    return offset
  }
}
