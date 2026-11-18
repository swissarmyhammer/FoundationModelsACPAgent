import Foundation

/// Runs the wait `body`, and cancels it when it did not end after `bound`. A wait for an update
/// that does not come then fails the test, and the test does not wait forever.
///
/// - Parameters:
///   - bound: The longest time that the wait can take.
///   - body: The wait. A cancel ends it with an error.
/// - Returns: The value of `body`.
/// - Throws: The error of `body`, for example ``ConditionWaitCancelled`` after the bound.
@discardableResult
func bounded<Value: Sendable>(
  by bound: Duration, _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let work = Task { try await body() }
  let limit = Task {
    do {
      try await Task.sleep(for: bound)
      work.cancel()
    } catch {
      // The sleep throws only when the wait ended in time and cancelled the limit.
      return
    }
  }
  defer { limit.cancel() }
  return try await work.value
}
