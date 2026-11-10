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

/// A signal from inside a scripted pass: the pass writes a named pipe with a
/// ``ScriptedPassStep/writeFile(path:text:)`` step, and the test waits for one
/// byte of it. The wait uses no clock and no poll.
///
/// The signal holds the pipe open for reading and for writing from the start.
/// The read end keeps the byte of the step, which a pipe that no process holds
/// open would lose. The write end keeps a read from an end of file while the
/// step has not written yet.
struct NamedPipeSignal: Sendable {
  /// The open pipe.
  private let handle: FileHandle

  /// Opens the pipe at `pipe`.
  ///
  /// - Parameter pipe: The named pipe that the step writes.
  /// - Throws: The open error.
  init(pipe: URL) throws {
    handle = try FileHandle(forUpdating: pipe)
  }

  /// Waits until the step wrote one byte to the pipe, and takes that byte.
  /// The read blocks a thread, so it runs on a thread of its own and not on
  /// the cooperative pool.
  ///
  /// - Throws: The read error, or ``NamedPipeSignalError/ended`` when the pipe
  ///   ended with no byte.
  func wait() async throws {
    let handle = handle
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let reader = Thread {
        do {
          let byte = try handle.read(upToCount: 1)
          continuation.resume(with: byte?.isEmpty == false ? .success(()) : .failure(NamedPipeSignalError.ended))
        } catch {
          continuation.resume(throwing: error)
        }
      }
      reader.start()
    }
  }
}

/// An error of ``NamedPipeSignal/wait()``.
enum NamedPipeSignalError: Error {
  /// The pipe ended before a byte came.
  case ended
}
