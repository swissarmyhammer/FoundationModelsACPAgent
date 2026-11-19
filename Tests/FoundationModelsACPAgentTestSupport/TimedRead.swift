/// The read of a value, for example the trace of a wire, while a request runs. The one place
/// that starts the task of such a read, bounds it with a clock, and cancels it.
public enum TimedRead {
  /// Runs `read` in its own task while `request` runs, and ends the read at `timeout` when it
  /// did not end before. The read gets a cancel on each exit path, also when `request` throws.
  /// So no read stays after the call.
  ///
  /// - Parameters:
  ///   - read: The read. A cancel of its task must end it.
  ///   - timeout: The longest time that the read waits. The clock starts before `request`.
  ///   - request: The steps that make what the read reads, for example a resume call.
  /// - Returns: The value of `read`.
  /// - Throws: The error of `request`. The read gets a cancel then.
  public static func value<Value: Sendable>(
    of read: @escaping @Sendable () async -> Value,
    timeout: Duration,
    whileRunning request: () async throws -> Void
  ) async throws -> Value {
    let reader = Task { await read() }
    defer { reader.cancel() }
    let limit = Task {
      try? await Task.sleep(for: timeout)
      reader.cancel()
    }
    defer { limit.cancel() }
    try await request()
    return await reader.value
  }
}
