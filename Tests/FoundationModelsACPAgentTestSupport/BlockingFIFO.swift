import Darwin
import Foundation

/// The named pipes (FIFO) of the tests, and the open of their write end that
/// waits for a reader.
///
/// The unit tests (a shell read that waits on a pipe) and the integration
/// tests (the chunk gate of a spawned stub model) both make a pipe, and both
/// open its write end the same way. This one home keeps the permissions, the
/// wait for the reader and the error handling in one place, so the two sides
/// cannot drift apart.
public enum BlockingFIFO {
  /// The permissions of each pipe: read and write for the owner.
  private static let permissions: mode_t = S_IRUSR | S_IWUSR

  /// The longest time that ``openWriteEnd(at:waitingAtMost:)`` waits for a
  /// reader when the caller gives no limit. A full parallel test run can
  /// keep a reader back for a long time, so the limit is large. It is finite,
  /// so a reader that never comes makes the test fail and does not stop the
  /// test process for ever.
  public static let defaultReaderWait = Duration.seconds(defaultReaderWaitSeconds)

  /// The number of seconds of ``defaultReaderWait``.
  private static let defaultReaderWaitSeconds = 120

  /// The time between two attempts to open the write end while no reader
  /// holds the pipe.
  private static let openRetryInterval = Duration.milliseconds(openRetryIntervalMilliseconds)

  /// The number of milliseconds of ``openRetryInterval``.
  private static let openRetryIntervalMilliseconds = 10

  /// The `errno` values of an open with `O_NONBLOCK` that tell the caller to
  /// try again: no reader holds the pipe (`ENXIO`), or a signal stopped the
  /// call (`EINTR`).
  private static let retryableOpenErrors: Set<Int32> = [ENXIO, EINTR]

  /// Makes a named pipe at `path`.
  ///
  /// - Parameter path: The path of the new pipe.
  /// - Throws: The `mkfifo` error, as a `POSIXError`.
  public static func makePipe(at path: URL) throws {
    guard mkfifo(path.path, permissions) == 0 else {
      throw currentPOSIXError()
    }
  }

  /// Opens the write end of the pipe at `path` when a reader holds the pipe
  /// open.
  ///
  /// The open waits until a reader holds the pipe. Thus the text never goes
  /// into a pipe that no reader holds, where the close of the last writer
  /// would discard it. A reader that waits in its own open of the read end
  /// already holds the pipe.
  ///
  /// The open itself never blocks a thread: each attempt uses `O_NONBLOCK`,
  /// which fails with `ENXIO` while no reader is there, and the task sleeps
  /// between two attempts. Thus a cancel of the task ends the wait, and the
  /// time `limit` ends it with an error. A reader that never comes thus makes
  /// the test fail, and cannot stop the test process for ever.
  ///
  /// The handle that the open returns has no `O_NONBLOCK`, so a write blocks
  /// while the pipe is full. A write after the reader ended fails with
  /// `EPIPE` and raises no `SIGPIPE`, which would end the whole test process.
  ///
  /// - Parameters:
  ///   - path: The path of the pipe.
  ///   - limit: The longest time to wait for a reader.
  /// - Returns: The write handle. It closes its descriptor when it is
  ///   released.
  /// - Throws: ``BlockingFIFOError/noReader(path:limit:)`` when no reader
  ///   came in the time `limit`, `CancellationError` when the task was
  ///   cancelled, or another open error as a `POSIXError`.
  public static func openWriteEnd(
    at path: URL, waitingAtMost limit: Duration = defaultReaderWait
  ) async throws -> FileHandle {
    try await openWriteEnd(at: path, waitingAtMost: limit, onNoReaderYet: {})
  }

  /// Opens the write end of the pipe at `path` when a reader holds the pipe
  /// open, and calls `onNoReaderYet` after each attempt that found no reader.
  ///
  /// The open is the same as ``openWriteEnd(at:waitingAtMost:)``. A test uses
  /// `onNoReaderYet` to know that the open waits for a reader, for example to
  /// cancel the task only while it waits between two attempts.
  ///
  /// - Parameters:
  ///   - path: The path of the pipe.
  ///   - limit: The longest time to wait for a reader.
  ///   - onNoReaderYet: The hook that the open calls after each attempt that
  ///     found no reader, before it waits for the next attempt.
  /// - Returns: The write handle. It closes its descriptor when it is
  ///   released.
  /// - Throws: ``BlockingFIFOError/noReader(path:limit:)`` when no reader
  ///   came in the time `limit`, `CancellationError` when the task was
  ///   cancelled, or another open error as a `POSIXError`.
  public static func openWriteEnd(
    at path: URL, waitingAtMost limit: Duration, onNoReaderYet: () -> Void
  ) async throws -> FileHandle {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while true {
      try Task.checkCancellation()
      if let handle = try openWriteEndIfAReaderHoldsThePipe(at: path) {
        return handle
      }
      guard clock.now < deadline else {
        throw BlockingFIFOError.noReader(path: path.path, limit: limit)
      }
      onNoReaderYet()
      try await Task.sleep(for: openRetryInterval, clock: clock)
    }
  }

  /// Makes one attempt to open the write end of the pipe at `path`. The
  /// attempt does not wait.
  ///
  /// - Parameter path: The path of the pipe.
  /// - Returns: The write handle, or `nil` when no reader holds the pipe yet.
  /// - Throws: An open error other than the errors in
  ///   ``retryableOpenErrors``, or a `fcntl` error, as a `POSIXError`.
  private static func openWriteEndIfAReaderHoldsThePipe(at path: URL) throws -> FileHandle? {
    let descriptor = Darwin.open(path.path, O_WRONLY | O_NONBLOCK)
    guard descriptor >= 0 else {
      guard retryableOpenErrors.contains(errno) else { throw currentPOSIXError() }
      return nil
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      throw currentPOSIXError()
    }
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    return handle
  }

  /// The error that `errno` names now, as a `POSIXError`.
  ///
  /// - Returns: The error, or `EIO` when `errno` names no known error.
  private static func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

/// An error of ``BlockingFIFO/openWriteEnd(at:waitingAtMost:)``.
public enum BlockingFIFOError: Error, Equatable, CustomStringConvertible {
  /// No reader opened the pipe at `path` in the time `limit`.
  case noReader(path: String, limit: Duration)

  /// A text that tells which pipe had no reader and how long the open
  /// waited.
  public var description: String {
    switch self {
    case .noReader(let path, let limit):
      "no reader opened the named pipe at \(path) in \(limit)"
    }
  }
}
