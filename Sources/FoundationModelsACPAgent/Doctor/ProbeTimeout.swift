import Foundation

/// The deadline every outward call of a `doctor` component runs under
/// (cli-plan.md §5.12).
///
/// A probe reaches a subprocess, a network endpoint or the Hugging Face
/// Hub, and each one can stop answering. `doctor` must still finish and
/// still print its table, so each call races the probe against a timer and
/// gives the caller's own late answer when the timer wins.
///
/// The type is generic over the answer, because two components use it:
/// ``ToolsDoctor`` over ``ProbeOutcome``, and ``ProfileDoctor`` over
/// ``ModelLookup``. Each one states its own late answer.
///
/// **The probe runs in an unstructured task on purpose.** A structured
/// child would have to be awaited at the end of its scope, so a probe that
/// ignores cancellation would hold the whole run. The unstructured task is
/// cancelled and then left behind, which is what keeps the run from
/// hanging.
enum ProbeTimeout {
    /// Runs `probe` under a deadline.
    ///
    /// - Parameters:
    ///   - seconds: How long the probe may take.
    ///   - timedOut: The answer of a probe that does not answer in time.
    ///   - probe: The call to run.
    /// - Returns: What the probe gave, or `timedOut`.
    static func run<Answer: Sendable>(
        seconds: Double, timedOut: Answer, probe: @escaping @Sendable () async -> Answer
    ) async -> Answer {
        let answer = FirstAnswer<Answer>()
        let probeTask = Task { await answer.settle(probe()) }
        let timerTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await answer.settle(timedOut)
        }
        let outcome = await answer.value()
        probeTask.cancel()
        timerTask.cancel()
        return outcome
    }
}

/// The first of two answers, and the one waiter that reads it.
///
/// The probe and the timer both settle this box. The first one wins and
/// every later one is dropped, so the waiter is resumed exactly one time.
private actor FirstAnswer<Answer: Sendable> {
    /// The answer that won, once one has.
    private var outcome: Answer?

    /// The waiter that ``value()`` suspended, when it suspended.
    private var waiter: CheckedContinuation<Answer, Never>?

    /// Records `answer` when nothing is recorded yet, and resumes the
    /// waiter.
    ///
    /// - Parameter answer: The answer to record.
    func settle(_ answer: Answer) {
        guard outcome == nil else {
            return
        }
        outcome = answer
        waiter?.resume(returning: answer)
        waiter = nil
    }

    /// The answer that won, waiting for it when there is none yet.
    ///
    /// - Returns: The first answer.
    func value() async -> Answer {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}
