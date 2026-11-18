import Testing

/// The tests of `bounded(by:_:)`, the wait helper of the suites that wait for updates.
@Suite struct BoundedWaitTests {
  /// A bound that the test does not reach. Only a cancel of the caller can end the body before
  /// this bound.
  private static let unreachedBound = Duration.seconds(3600)

  /// A cancel of the task that calls `bounded(by:_:)` cancels the body at once. The body does
  /// not wait until the bound.
  @Test(.timeLimit(.minutes(1)))
  func aCancelOfTheCallerCancelsTheBody() async {
    let bodyCancelled = OneShot()
    let caller = Task {
      try await bounded(by: Self.unreachedBound) {
        defer { bodyCancelled.fire(true) }
        try await waitForCancellation()
      }
    }
    caller.cancel()
    let cancelled = await withTaskCancellationHandler {
      await withCheckedContinuation { bodyCancelled.arm($0) }
    } onCancel: {
      bodyCancelled.fire(false)
    }
    #expect(cancelled)
  }
}
