import Darwin
import Foundation

/// The named pipes (FIFO) of the tests, and the blocking open of their write
/// end.
///
/// The unit tests (a shell read that waits on a pipe) and the integration
/// tests (the chunk gate of a spawned stub model) both make a pipe, and both
/// open its write end the same way. This one home keeps the permissions, the
/// thread placement and the error handling in one place, so the two sides
/// cannot drift apart.
public enum BlockingFIFO {
  /// The permissions of each pipe: read and write for the owner.
  private static let permissions: mode_t = S_IRUSR | S_IWUSR

  /// Makes a named pipe at `path`.
  ///
  /// - Parameter path: The path of the new pipe.
  /// - Throws: The `mkfifo` error, as a `POSIXError`.
  public static func makePipe(at path: URL) throws {
    guard mkfifo(path.path, permissions) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Opens the write end of the pipe at `path`.
  ///
  /// An open with no `O_NONBLOCK` blocks in the kernel until a reader holds
  /// the pipe open. Thus the text never goes into a pipe that no reader
  /// holds, where the close of the last writer would discard it, and the wait
  /// uses no clock and no poll. The open blocks a thread, so it runs on a
  /// thread of its own and not on the cooperative pool.
  ///
  /// A write after the reader ended fails with `EPIPE` and raises no
  /// `SIGPIPE`, which would end the whole test process.
  ///
  /// - Parameter path: The path of the pipe.
  /// - Returns: The write handle. It closes its descriptor when it is
  ///   released.
  /// - Throws: The open error, as a `POSIXError`.
  public static func openWriteEnd(at path: URL) async throws -> FileHandle {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<FileHandle, any Error>) in
      let opener = Thread {
        let descriptor = Darwin.open(path.path, O_WRONLY)
        guard descriptor >= 0 else {
          continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
          return
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        continuation.resume(
          returning: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
      }
      opener.start()
    }
  }
}
