import Dispatch
import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

/// The delivery of the transcript of a ``ScriptedSessionBackend`` to its
/// update streams, at the same time as a cancel of an update reader (task
/// ^05rmb1p).
///
/// The Router repetition watch reads
/// ``ScriptedSessionBackend/transcriptUpdates()`` while a model call is in
/// operation, and it cancels its reader task when the call ends. A cancel
/// of a reader that waits runs the `onTermination` handler of the stream
/// while the runtime holds the status lock of that reader task. A change of
/// the transcript at the same time resumes that same reader task. The
/// backend must not hold its transcript lock while it resumes the reader,
/// because the `onTermination` handler takes that lock. Before the
/// correction, this order stopped both threads, thus the session actor of
/// an agent run stopped, and `session/close` never answered.
///
/// The test puts each step in its order with hooks and semaphores, not with
/// a clock.
@Suite struct ScriptedTranscriptDeliveryTests {
    /// The prompt of the pass.
    static let promptText = "DELIVERY-PROMPT"

    /// The name of the thread that cancels the reader.
    static let cancellerName = "ScriptedTranscriptDeliveryTests.canceller"

    /// The count of values that the reader reads: the first value of the
    /// stream only. The cancel ends the stream before the held delivery.
    static let valuesBeforeTheCancel = 1

    /// The count of entries after one pass: the instructions, the prompt and
    /// the response.
    static let entriesAfterOnePass = 3

    /// A cancel of a waiting update reader while a pass delivers a
    /// transcript change ends the reader, and the pass ends too.
    @Test
    func aReaderCancelDuringATranscriptDeliveryEndsTheReaderAndThePass() async throws {
        let gates = DeliveryGates()
        let backend = ScriptedSessionBackend(script: [.endPass], tools: [], deliveryHooks: gates.hooks)
        let reader = UpdateReader(updates: backend.transcriptUpdates())
        let reading = Task { await reader.readUntilEnd(signalling: gates.valueRead) }
        await gates.valueRead.waitOutsideThePool()
        await reader.waitUntilSuspended()

        let pass = Task.detached { try await backend.respond(to: Self.promptText, maxTokens: nil) }
        await gates.deliveryHeld.waitOutsideThePool()
        Self.cancelOnThreadOfItsOwn(reading)
        await gates.removalStarted.waitOutsideThePool()
        gates.releaseDelivery.signal()

        let passResult = try #require(await Self.resultUnlessCancelled(of: pass))
        _ = try passResult.get()
        #expect(await Self.resultUnlessCancelled(of: reading) == .success(Self.valuesBeforeTheCancel))
        #expect(gates.removalThreadName == Self.cancellerName)
        #expect(backend.transcriptEntries().count == Self.entriesAfterOnePass)
    }

    /// Waits for the result of `task`, or for the cancel of the waiting
    /// task. A test has no time limit: a task that never ends holds the
    /// test, and a sample of the test process shows where it waits.
    ///
    /// - Parameter task: The task to wait for.
    /// - Returns: The result of `task`, or `nil` when the waiting task is
    ///   cancelled first.
    static func resultUnlessCancelled<Success: Sendable, Failure: Error>(
        of task: Task<Success, Failure>
    ) async -> Result<Success, Failure>? {
        let (results, continuation) = AsyncStream<Result<Success, Failure>>.makeStream()
        Task {
            continuation.yield(await task.result)
            continuation.finish()
        }
        var iterator = results.makeAsyncIterator()
        return await iterator.next()
    }

    /// Cancels `task` on a new thread named ``cancellerName``. The thread is
    /// not a thread of the cooperative pool, thus a cancel that stops does
    /// not take a pool thread.
    ///
    /// - Parameter task: The task to cancel.
    static func cancelOnThreadOfItsOwn(_ task: Task<Int, Never>) {
        let canceller = Thread { task.cancel() }
        canceller.name = cancellerName
        canceller.start()
    }
}

/// The gates that put a cancel of the update reader inside the first
/// transcript delivery of a pass.
private final class DeliveryGates: Sendable {
    /// The state that the hooks change.
    private struct State {
        /// `true` until the first delivery holds.
        var isDeliveryArmed = true

        /// The name of the thread that ran the removal hook, or `nil`
        /// before the removal.
        var removalThreadName: String?
    }

    /// The reader read a value.
    let valueRead = DispatchSemaphore(value: 0)

    /// The first delivery holds, after the change and before the streams
    /// get it.
    let deliveryHeld = DispatchSemaphore(value: 0)

    /// The test lets the held delivery continue.
    let releaseDelivery = DispatchSemaphore(value: 0)

    /// The `onTermination` handler of the reader stream started.
    let removalStarted = DispatchSemaphore(value: 0)

    /// The state, guarded because the hooks run on other threads.
    private let state = Mutex(State())

    /// The name of the thread that ran the removal hook.
    var removalThreadName: String? {
        state.withLock { $0.removalThreadName }
    }

    /// The hooks to give the backend.
    var hooks: TranscriptDeliveryHooks {
        TranscriptDeliveryHooks(
            beforeDelivery: { self.holdFirstDelivery() },
            beforeObserverRemoval: { self.noteRemoval() })
    }

    /// Holds the first delivery until the test signals
    /// ``releaseDelivery``. Each later delivery continues at once.
    private func holdFirstDelivery() {
        let isFirst = state.withLock { state in
            let isFirst = state.isDeliveryArmed
            state.isDeliveryArmed = false
            return isFirst
        }
        if isFirst {
            deliveryHeld.signal()
            releaseDelivery.wait()
        }
    }

    /// Records the thread of the removal, and signals
    /// ``removalStarted``.
    private func noteRemoval() {
        let name = Thread.current.name
        state.withLock { $0.removalThreadName = name }
        removalStarted.signal()
    }
}

/// Reads one stream of transcript updates on a serial queue of its own.
///
/// The test can thus know when the reader waits for the next value: the
/// queue runs a block that the test sends only after the job of the reader
/// suspends in the wait.
private actor UpdateReader {
    /// The queue that runs each job of the reader.
    private let queue = DispatchSerialQueue(label: "ScriptedTranscriptDeliveryTests.reader")

    /// The stream to read.
    private let updates: AsyncStream<[Transcript.Entry]>

    /// The executor of the reader: its own queue.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Makes a reader of `updates`.
    ///
    /// - Parameter updates: The stream to read.
    init(updates: AsyncStream<[Transcript.Entry]>) {
        self.updates = updates
    }

    /// Reads each value until the stream ends.
    ///
    /// - Parameter valueRead: The semaphore to signal for each value.
    /// - Returns: The count of values read.
    func readUntilEnd(signalling valueRead: DispatchSemaphore) async -> Int {
        var count = 0
        for await _ in updates {
            count += 1
            valueRead.signal()
        }
        return count
    }

    /// Waits until the queue of the reader runs no job: the reader waits
    /// in the stream, or it ended.
    nonisolated func waitUntilSuspended() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

extension DispatchSemaphore {
    /// Waits for this semaphore on a global dispatch queue, thus the wait
    /// takes no thread of the cooperative pool.
    fileprivate func waitOutsideThePool() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.wait()
                continuation.resume()
            }
        }
    }
}
