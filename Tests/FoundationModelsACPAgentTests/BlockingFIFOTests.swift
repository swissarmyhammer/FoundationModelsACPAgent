import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// The tests of ``BlockingFIFO/openWriteEnd(at:waitingAtMost:)``, the open of
/// the write end of a named pipe that waits for a reader.
@Suite struct BlockingFIFOTests {
  /// A short wait for a reader. No reader comes in these tests, so the open
  /// must end with an error at this limit.
  private static let shortReaderWait = Duration.milliseconds(200)

  /// A wait for a reader that the test does not reach. Only a cancel or a
  /// reader can end the open before it.
  private static let unreachedReaderWait = Duration.seconds(3600)

  /// The wait for a reader of the cancel test. A cancel ends the open long
  /// before this limit. The limit is finite, so an open that ignores the
  /// cancel ends with ``BlockingFIFOError/noReader(path:limit:)`` and the
  /// test fails, and the test does not wait for ever.
  private static let waitThatTheCancelEnds = Duration.seconds(10)

  /// The file name of the named pipe in its directory.
  private static let pipeName = "pipe"

  /// The text that goes through the pipe.
  private static let text = "go"

  /// Makes a new named pipe in a new directory.
  ///
  /// - Parameter label: The directory label of the calling test.
  /// - Returns: The path of the pipe.
  /// - Throws: When the named pipe cannot be made.
  private static func makePipe(label: String) throws -> URL {
    try NamedPipe.makeDirectory(holding: pipeName, label: "BlockingFIFOTests-\(label)")
      .appendingPathComponent(pipeName)
  }

  /// Opens the read end of the pipe at `pipe`. The open does not wait for a
  /// writer.
  ///
  /// The open uses `O_NONBLOCK`, and then the helper removes it. Thus a read
  /// waits for the data and for the end of the file. A read with
  /// `O_NONBLOCK` fails with `EAGAIN` when a writer holds the pipe and no
  /// data is there yet (^rh5d00n).
  ///
  /// - Parameter pipe: The named pipe.
  /// - Returns: The read handle.
  private static func openReadEnd(at pipe: URL) throws -> FileHandle {
    let descriptor = Darwin.open(pipe.path, O_RDONLY | O_NONBLOCK)
    try #require(descriptor >= 0)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let flags = fcntl(descriptor, F_GETFL)
    try #require(flags >= 0)
    try #require(fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0)
    return handle
  }

  /// With no reader, the open ends at its time limit with the error that
  /// names the pipe and the limit.
  @Test(.timeLimit(.minutes(1)))
  func anOpenWithNoReaderEndsAtItsTimeLimit() async throws {
    let pipe = try Self.makePipe(label: "no-reader")

    await #expect(throws: BlockingFIFOError.noReader(path: pipe.path, limit: Self.shortReaderWait)) {
      _ = try await BlockingFIFO.openWriteEnd(at: pipe, waitingAtMost: Self.shortReaderWait)
    }
  }

  /// A cancel of the task that waits for a reader ends the wait. The test
  /// cancels only after the open made one attempt that found no reader, so
  /// the cancel comes while the open waits between two attempts.
  @Test(.timeLimit(.minutes(1)))
  func aCancelEndsTheWaitForAReader() async throws {
    let pipe = try Self.makePipe(label: "cancel")
    let (missedAttempts, missedAttempt) = AsyncStream<Void>.makeStream()
    let opener = Task {
      try await BlockingFIFO.openWriteEnd(
        at: pipe, waitingAtMost: Self.waitThatTheCancelEnds,
        onNoReaderYet: { missedAttempt.yield() })
    }
    defer { opener.cancel() }
    for await _ in missedAttempts { break }

    opener.cancel()

    await #expect(throws: CancellationError.self) { _ = try await opener.value }
  }

  /// When a reader opens the pipe, the open ends, and the reader reads the
  /// text that the write end writes.
  @Test(.timeLimit(.minutes(1)))
  func theReaderReadsTheTextAfterItOpensThePipe() async throws {
    let pipe = try Self.makePipe(label: "reader")
    let opener = Task {
      try await BlockingFIFO.openWriteEnd(at: pipe, waitingAtMost: Self.unreachedReaderWait)
    }
    defer { opener.cancel() }
    let reader = try Self.openReadEnd(at: pipe)

    let writer = try await opener.value
    try writer.write(contentsOf: Data(Self.text.utf8))
    try writer.close()

    #expect(try reader.readToEnd() == Data(Self.text.utf8))
  }
}
