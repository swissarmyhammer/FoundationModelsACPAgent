import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// A named pipe in a working directory, that a shell read of a test waits on.
///
/// A shell command `cat <name>` waits until a writer writes the pipe and
/// closes it. The test is that writer, thus the test decides when the shell
/// run settles.
enum NamedPipe {
  /// Makes a new working directory that holds one named pipe.
  ///
  /// - Parameters:
  ///   - name: The file name of the pipe.
  ///   - label: The directory label of the calling suite.
  /// - Returns: The directory.
  /// - Throws: When the named pipe cannot be made.
  static func makeDirectory(holding name: String, label: String) throws -> URL {
    let directory = makeResolvedDirectory(label: label)
    let pipe = directory.appendingPathComponent(name)
    try BlockingFIFO.makePipe(at: pipe)
    return directory
  }

  /// Writes `text` into the pipe at `pipe` after a reader opened it, and
  /// then closes the write end. The reader thus reads `text` and then the
  /// end of the stream. The open is ``BlockingFIFO/openWriteEnd(at:)``.
  ///
  /// - Parameters:
  ///   - text: The text to write.
  ///   - pipe: The named pipe.
  /// - Throws: When the open or the write fails.
  static func write(_ text: String, toPipeAt pipe: URL) async throws {
    let handle = try await BlockingFIFO.openWriteEnd(at: pipe)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }
}
