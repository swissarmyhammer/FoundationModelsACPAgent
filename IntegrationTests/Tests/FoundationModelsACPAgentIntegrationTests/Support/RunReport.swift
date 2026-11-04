import Foundation

/// A line for the reader of a test run, written to standard error.
///
/// A live-model suite measures a result (a rate, a duration) that the reader
/// wants to see whether the bar passes or fails, and a support type reports
/// an unexpected condition the same way. The line goes to standard error as
/// one write, in the same way for each caller, and never through `print`.
enum RunReport {
  /// Writes one report line, with a line break, to standard error.
  ///
  /// - Parameter line: The text of the line, with no line break.
  static func write(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}
