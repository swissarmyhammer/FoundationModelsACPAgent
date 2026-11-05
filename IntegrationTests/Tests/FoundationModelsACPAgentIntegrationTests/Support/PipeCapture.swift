// `PipeCapture` — the reads of one output pipe of a spawned child.
//
// `CapturedProcessRun`, `SignalledExecutableRun` and `SpawnedACPAgent` each
// read the stdout or the stderr of a child. They read it in the same way, so
// this type holds that read.
//
// A `FileHandle` readability handler reads on a Dispatch queue. A blocking
// read on a task would hold a thread of the cooperative pool for the life of
// the child, and the wait of that task would ignore cancel: the suites of this
// package run at the same time, enough held threads stop every task of the
// test process, and a time limit of Swift Testing can no longer end the test.

import Foundation
import FoundationModelsACPAgentTestSupport

/// The bytes of one output pipe of a child, and the end of that pipe.
final class PipeCapture: Sendable {
  /// The bytes read so far. A wait on it ends when the child wrote the byte
  /// that the caller needs.
  let record = WatchedValue(Data())

  /// The stream that finishes when the pipe reaches its end.
  private let ended: AsyncStream<Never>

  /// The end of ``ended``.
  private let finish: AsyncStream<Never>.Continuation

  /// The read end of the pipe.
  private let handle: FileHandle

  /// Starts the reads of `pipe`.
  ///
  /// - Parameters:
  ///   - pipe: The pipe to read.
  ///   - forward: What each chunk goes to, beside the record.
  ///   - atEnd: What runs when the pipe reaches its end.
  init(
    _ pipe: Pipe,
    forwarding forward: @escaping @Sendable (Data) -> Void = { _ in },
    atEnd: @escaping @Sendable () -> Void = {}
  ) {
    let record = record
    let (ended, finish) = AsyncStream<Never>.makeStream()
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        atEnd()
        finish.finish()
        return
      }
      record.update { $0.append(chunk) }
      forward(chunk)
    }
    self.ended = ended
    self.finish = finish
    self.handle = handle
  }

  /// The bytes read so far.
  var data: Data { record.value }

  /// The bytes read so far, as text.
  var text: String { String(decoding: data, as: UTF8.self) }

  /// Waits until the pipe reaches its end. One task at a time may wait.
  ///
  /// The wait ends also when the waiting task is cancelled, or when ``stop()``
  /// ran. The caller that needs to tell the cases apart checks the cancel of
  /// its task after the wait.
  func untilEnd() async {
    for await _ in ended {}
  }

  /// Ends the reads now, for a pipe that a process other than the child holds
  /// open. The bytes that the pipe still holds are not read.
  func stop() {
    handle.readabilityHandler = nil
    finish.finish()
  }
}
