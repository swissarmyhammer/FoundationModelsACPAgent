import Dispatch

/// The place where a session runs a synchronous file read that can wait for
/// a long time: off the cooperative thread pool of Swift concurrency (task
/// ^6yt2dpb).
///
/// A coordinated read (`NSFileCoordinator`) waits until each file presenter
/// of the item and each sync engine with a claim on it lets the read go. On a
/// thread of the cooperative pool, that wait holds the thread. The pool has
/// one thread for each core, thus some slow reads stop each other task of the
/// process. A read on the concurrent queue of this type holds a thread of
/// that queue only.
///
/// The session open path reads two times in this manner: the root `AGENT.md`
/// of the working directory (``read(_:)``), and the load of the agent
/// registry (``withReadExecutor(_:)``), whose build reads each agent file in
/// FoundationModelsAgents.
///
/// A read on the queue does not see the cancel of the task that waits for
/// it, as a read on the thread of the task did not see it: the read runs to
/// its end, and the task then gets its value.
enum BlockingFileReads {
  /// The label of the queue.
  private static let queueLabel = "FoundationModelsACPAgent.BlockingFileReads"

  /// The concurrent queue of the reads.
  private static let queue = DispatchQueue(label: queueLabel, attributes: .concurrent)

  /// The task executor over ``queue``, for an async call whose synchronous
  /// part reads.
  private static let executor = BlockingFileReadExecutor(queue: queue)

  /// Runs the synchronous `read` on the queue of the reads, and gives its
  /// value to the task that waits.
  ///
  /// - Parameter read: The read.
  /// - Returns: What `read` gave.
  static func read<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: read()) }
    }
  }

  /// Runs the async `operation` with the queue of the reads as its preferred
  /// task executor. The synchronous part of each nonisolated async call of
  /// `operation`, for example the build of `AgentRegistry.load()`, then runs
  /// on that queue. A task that `operation` starts with `Task { }` does not
  /// take the preference.
  ///
  /// - Parameter operation: The async work that reads.
  /// - Returns: What `operation` gave.
  /// - Throws: What `operation` throws.
  static func withReadExecutor<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withTaskExecutorPreference(executor, operation: operation)
  }
}

/// A task executor that runs each job on one dispatch queue.
final class BlockingFileReadExecutor: TaskExecutor {
  /// The queue that runs the jobs.
  private let queue: DispatchQueue

  /// Makes an executor over `queue`.
  ///
  /// - Parameter queue: The queue that runs the jobs.
  init(queue: DispatchQueue) {
    self.queue = queue
  }

  /// Runs `job` on the queue, with this executor as the task executor of the
  /// job.
  ///
  /// - Parameter job: The job.
  func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    queue.async { unownedJob.runSynchronously(on: executor) }
  }
}
