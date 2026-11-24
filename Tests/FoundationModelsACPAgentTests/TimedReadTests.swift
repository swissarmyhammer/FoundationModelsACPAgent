import FoundationModelsACPAgentTestSupport
import Testing

/// The tests of ``TimedRead``, the read of a value while a request runs.
@Suite struct TimedReadTests {
  /// A timeout that the test does not reach. Only a cancel can end the read before it.
  private static let unreachedTimeout = Duration.seconds(3600)

  /// The longest time that the test waits for the end of the read.
  private static let readEndWait = Duration.seconds(5)

  /// The error of a step before the request.
  private struct StepFailed: Error {}

  /// A step before the request throws, for example the `beforeRequest` step of a resume. Then
  /// the read gets a cancel at once, and it does not wait until the timeout.
  @Test
  func aThrowingStepBeforeTheRequestCancelsTheRead() async throws {
    let readEnded = OneShot()
    await #expect(throws: StepFailed.self) {
      try await TimedRead.value(
        of: {
          defer { readEnded.fire(true) }
          try? await waitForCancellation()
        }, timeout: Self.unreachedTimeout
      ) {
        throw StepFailed()
      }
    }

    let ended = try await bounded(by: Self.readEndWait) {
      await withTaskCancellationHandler {
        await withCheckedContinuation { readEnded.arm($0) }
      } onCancel: {
        readEnded.fire(false)
      }
    }

    #expect(ended)
  }
}
