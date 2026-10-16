import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

/// The waits of ``SinkRecorder``. A wait ends when its condition comes. A
/// wait for a condition that never comes ends when its task is cancelled,
/// and its error names that condition. A test has no time limit, so a wait
/// for an update that never comes ends only when its task is cancelled.
@Suite struct SinkRecorderTests {
    /// The name of a condition that no test makes true.
    private static let missingCondition = "an update that never comes"

    /// The name of a condition that one update makes true.
    private static let oneUpdateCondition = "one update"

    /// The one update that the tests record.
    private static let idleUpdate = SessionUpdate.stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))

    /// A wait that is kept and suspended for a condition that never comes
    /// ends when the test cancels its task. The cancellation handler removes
    /// the kept wait and resumes it, and the error names the condition.
    @Test
    func aSuspendedWaitForAConditionThatNeverComesEndsWhenItsTaskIsCancelled() async throws {
        let recorder = SinkRecorder()
        let wait = try await Self.startWait(on: recorder, for: Self.missingCondition) { _ in false }
        #expect(await recorder.keptWaitCount == 1)

        wait.cancel()

        let error = await #expect(throws: ConditionWaitCancelled.self) {
            try await wait.value
        }
        #expect(error?.condition == Self.missingCondition)
        #expect(await recorder.keptWaitCount == 0)
    }

    /// A wait in a task that is already cancelled ends at once, and the
    /// failure message names the condition.
    @Test
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
    @Test
    func aSuspendedWaitEndsWithTheUpdatesWhenItsConditionComes() async throws {
        let recorder = SinkRecorder()
        let wait = try await Self.startWait(on: recorder, for: Self.oneUpdateCondition) { updates in
            !updates.isEmpty
        }

        await recorder.append(Self.idleUpdate)

        let updates = try await wait.value
        #expect(updates.count == 1)
        #expect(isIdleState(updates.first))
    }

    /// Starts a wait on `recorder` for a condition that is false now, and
    /// returns only when the recorder keeps the wait: its kept wait count is
    /// one. The wait is then suspended, and only a change that makes the
    /// condition true or the cancellation of its task resumes it.
    ///
    /// The recorder tells when it keeps the wait (an event), so this uses
    /// no clock and no poll.
    ///
    /// - Parameters:
    ///   - recorder: The recorder to wait on. It keeps no other wait.
    ///   - condition: The name of the condition.
    ///   - isComplete: Tells if the updates are all recorded. It is false
    ///     for the updates of now.
    /// - Returns: The task of the kept wait.
    private static func startWait(
        on recorder: SinkRecorder,
        for condition: String,
        until isComplete: @escaping SinkRecorder.Completion
    ) async throws -> Task<[SessionUpdate], any Error> {
        let wait = Task {
            try await recorder.updates(until: condition, isComplete)
        }
        do {
            try await recorder.waitUntilKept(atLeast: 1)
        } catch {
            // The wait for the kept wait ended first, so stop the kept wait.
            wait.cancel()
            throw error
        }
        return wait
    }
}
