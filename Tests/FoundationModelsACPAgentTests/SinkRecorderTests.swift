import FoundationModelsACP
import Testing

/// The waits of ``SinkRecorder``. A wait ends when its condition comes. A
/// wait for a condition that never comes ends when its task is cancelled,
/// and its error names that condition. A `.timeLimit` trait cancels the
/// task of its test, so a test that waits for an update that never comes
/// fails at its time limit, and the run continues.
@Suite struct SinkRecorderTests {
    /// The name of a condition that no test makes true.
    private static let missingCondition = "an update that never comes"

    /// The name of a condition that one update makes true.
    private static let oneUpdateCondition = "one update"

    /// The one update that the tests record.
    private static let idleUpdate = SessionUpdate.stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))

    /// A wait that is suspended for a condition that never comes ends when
    /// the test cancels its task. The wait throws at once, and the error
    /// names the condition.
    @Test(.timeLimit(.minutes(1)))
    func aSuspendedWaitForAConditionThatNeverComesEndsWhenItsTaskIsCancelled() async throws {
        let recorder = SinkRecorder()
        let wait = await Self.startWait(on: recorder, for: Self.missingCondition) { _ in false }

        wait.cancel()

        let error = await #expect(throws: ConditionWaitCancelled.self) {
            try await wait.value
        }
        #expect(error?.condition == Self.missingCondition)
    }

    /// A wait in a task that is already cancelled ends at once, and the
    /// failure message names the condition.
    @Test(.timeLimit(.minutes(1)))
    func aWaitInACancelledTaskEndsAtOnceAndItsMessageNamesTheCondition() async throws {
        let recorder = SinkRecorder()
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recorder.updates(until: Self.missingCondition) { _ in false }
        }

        let error = await #expect(throws: ConditionWaitCancelled.self) {
            try await wait.value
        }
        #expect(error?.description.contains(Self.missingCondition) == true)
    }

    /// A wait that is suspended ends with the recorded updates when the
    /// update that it waits for comes.
    @Test(.timeLimit(.minutes(1)))
    func aSuspendedWaitEndsWithTheUpdatesWhenItsConditionComes() async throws {
        let recorder = SinkRecorder()
        let wait = await Self.startWait(on: recorder, for: Self.oneUpdateCondition) { updates in
            !updates.isEmpty
        }

        await recorder.append(Self.idleUpdate)

        let updates = try await wait.value
        #expect(updates.count == 1)
        #expect(isIdleState(updates.first))
    }

    /// Starts a wait on `recorder`, and returns when the wait checked its
    /// condition the first time. The recorder checks the condition and keeps
    /// the wait in one step, so the wait is then suspended or ended.
    ///
    /// - Parameters:
    ///   - recorder: The recorder to wait on.
    ///   - condition: The name of the condition.
    ///   - isComplete: Tells if the updates are all recorded.
    /// - Returns: The task of the wait.
    private static func startWait(
        on recorder: SinkRecorder,
        for condition: String,
        until isComplete: @escaping SinkRecorder.Completion
    ) async -> Task<[SessionUpdate], any Error> {
        let (checks, checked) = AsyncStream<Void>.makeStream()
        let wait = Task {
            try await recorder.updates(until: condition) { updates in
                checked.yield()
                return isComplete(updates)
            }
        }
        for await _ in checks {
            break
        }
        return wait
    }
}
