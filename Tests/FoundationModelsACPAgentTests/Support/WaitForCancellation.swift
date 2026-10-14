/// Waits until the calling task is cancelled, and then throws
/// `CancellationError`.
///
/// A scripted body that must not end by itself (a run that stays pending, a
/// load that stops in its transfer, an embedder that never answers) waits
/// here. The cancel of its task is the only thing that ends the wait, so the
/// wait uses no clock.
///
/// - Throws: `CancellationError`, always, when the task is cancelled.
func waitForCancellation() async throws {
    let cancelled = OneShot()
    _ = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            cancelled.arm(continuation)
            if Task.isCancelled {
                cancelled.fire(true)
            }
        }
    } onCancel: {
        cancelled.fire(true)
    }
    throw CancellationError()
}
