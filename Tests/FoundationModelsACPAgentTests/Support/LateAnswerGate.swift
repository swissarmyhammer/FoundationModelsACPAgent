/// The gate that holds the answer of a silent doctor probe until the test
/// opens it.
///
/// A doctor test proves its timeout by order, not by the clock. The silent
/// probe waits here, and the test opens the gate only after
/// `runHealthChecks()` returned. Thus a doctor that waits for the probe never
/// returns, and the time limit of the test fails it. A bound on the elapsed
/// time also measured how long the cooperative pool took to run each step,
/// and a parallel run on a loaded machine went past that bound (task
/// `^vjaka1g`).
///
/// The wait ignores the cancellation of its task on purpose: a doctor that
/// cancels the probe and then waits for it must also hang, so the proof
/// finds that defect too. The test opens the gate at its end, so no probe
/// stays suspended after the test.
actor LateAnswerGate {
    /// The state of the gate.
    private enum State {
        /// The gate is closed. The payload holds each wait that is suspended.
        case closed(waiters: [CheckedContinuation<Void, Never>])

        /// The gate is open, and each wait returns at once.
        case open
    }

    /// The state of the gate. It starts closed, with no wait.
    private var state = State.closed(waiters: [])

    /// Waits until the gate is open. Returns at once when it is open.
    func wait() async {
        guard case .closed = state else { return }
        await withCheckedContinuation { continuation in
            addWaiter(continuation)
        }
    }

    /// Opens the gate, and resumes each wait that is suspended. A call when
    /// the gate is open does nothing.
    func open() {
        guard case .closed(let waiters) = state else { return }
        state = .open
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Records one wait that is suspended, or resumes it at once when the
    /// gate is open.
    ///
    /// - Parameter continuation: The continuation of the wait.
    private func addWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        guard case .closed(let waiters) = state else {
            continuation.resume()
            return
        }
        state = .closed(waiters: waiters + [continuation])
    }
}
