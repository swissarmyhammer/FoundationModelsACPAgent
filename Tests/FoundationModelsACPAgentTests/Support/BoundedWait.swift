import Foundation

/// The result of one child task of `bounded(by:_:)`.
private enum BoundedWaitOutcome<Value: Sendable>: Sendable {
  /// The body ended with this value.
  case finished(Value)

  /// The bound came, or the caller was cancelled, before the body ended.
  case boundReached
}

/// Runs the wait `body`, and cancels it when it did not end after `bound`. A wait for an update
/// that does not come then fails the test, and the test does not wait forever.
///
/// The body and the timer are child tasks of one task group. Thus a cancel of the caller also
/// cancels the body at once, and the body does not wait until the bound.
///
/// - Parameters:
///   - bound: The longest time that the wait can take.
///   - body: The wait. A cancel ends it with an error.
/// - Returns: The value of `body`.
/// - Throws: The error of `body`, for example ``ConditionWaitCancelled`` after the bound or after
///   a cancel of the caller.
@discardableResult
func bounded<Value: Sendable>(
  by bound: Duration, _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: BoundedWaitOutcome<Value>.self) { group in
    group.addTask { .finished(try await body()) }
    group.addTask {
      // A cancel of the caller ends the sleep early. The body then gets the cancel too, and its
      // own result or error is the result of the wait.
      try? await Task.sleep(for: bound)
      return .boundReached
    }
    defer { group.cancelAll() }
    for try await outcome in group {
      switch outcome {
      case .finished(let value):
        return value
      case .boundReached:
        group.cancelAll()
      }
    }
    preconditionFailure("The body task ends with a value or with an error.")
  }
}
