/// The bounds of a wait for the transcript search index in a test.
///
/// The index updates run with a low priority, so a full parallel test run can keep them back for
/// many seconds. The search update suites share these bounds, so each suite waits the same time.
public enum IndexPoll {
  /// The most polls of a wait for the index.
  public static let limit = 3600

  /// The milliseconds between two polls of a wait for the index.
  public static let intervalMilliseconds = 25

  /// The time between two polls of a wait for the index.
  public static let interval = Duration.milliseconds(intervalMilliseconds)
}

/// Polls `condition` with the bounds of ``IndexPoll`` until it holds or the limit is reached.
///
/// - Parameter condition: Tells whether the wait is over.
/// - Throws: What the condition throws, or the cancel of the sleep.
public func pollIndexUntil(_ condition: () async throws -> Bool) async throws {
  try await pollUntil(limit: IndexPoll.limit, interval: IndexPoll.interval, condition)
}
