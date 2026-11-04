/// Polls `condition` until it holds or `limit` polls have run.
///
/// The condition is checked first, so a condition that holds at once costs no sleep. The caller
/// reads the state again after the call, and asserts it, because the call does not tell whether
/// the condition held or the limit was reached.
///
/// - Parameters:
///   - limit: The most sleeps between two checks.
///   - interval: The time between two checks.
///   - condition: Tells whether the wait is over.
/// - Throws: What the condition throws, or the cancel of the sleep.
public func pollUntil(
  limit: Int, interval: Duration, _ condition: () async throws -> Bool
) async throws {
  var polls = 0
  while try await !condition(), polls < limit {
    polls += 1
    try await Task.sleep(for: interval)
  }
}
