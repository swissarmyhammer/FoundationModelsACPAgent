import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - The error of a wait that ended on a failure event

/// The error of a wait that ended on a failure event before its condition
/// came (test rule T1).
///
/// Each wait of a test also ends on the event that tells that the
/// condition cannot come now: the stream ended, the session closed, or the
/// run settled. Then the wait throws this error, and the test fails at
/// once. It does not wait until its task is cancelled.
struct WaitEndedOnFailure: Error, CustomStringConvertible {
    /// The name of the condition that did not come.
    let condition: String

    /// The name of the failure event that ended the wait.
    let event: String

    /// The failure message. It names the condition and the event.
    var description: String {
        "the wait for \(condition) ended at \(event) before the condition came"
    }
}

// MARK: - The shared wait for a pending elicitation

/// The read and the wait for the elicitations that a session sent to the
/// client and that the client did not answer yet.
///
/// Each suite that tests an elicitation round trip uses this one wait. The
/// wait observes the session model (``ObservedValue``), thus each change of
/// the model checks the fact again, and the wait uses no clock and no poll.
///
/// Each wait also ends on a failure event (test rule T1): the close of the
/// session, and for the wait for a new elicitation, the settle of the run.
/// Then the wait throws ``WaitEndedOnFailure``.
enum ElicitationWait {
    /// The elicitations that `session` did not answer yet.
    ///
    /// - Parameter session: The session model that received the
    ///   elicitations.
    /// - Returns: The pending elicitations of the session, in arrival order.
    static func pendingElicitations(in session: SessionModel) async -> [PendingElicitation] {
        await session.pendingElicitations
    }

    /// Waits until `session` holds no pending elicitation: each client
    /// request ended, with an answer or with a cancel of the agent.
    ///
    /// The wait also ends when the session closes. When the session closed
    /// and an elicitation is still pending, the wait throws.
    ///
    /// - Parameter session: The session model that received the
    ///   elicitations.
    /// - Throws: ``WaitEndedOnFailure`` when the session closed with an
    ///   elicitation still pending, and ``ConditionWaitCancelled`` when the
    ///   test is cancelled first.
    static func waitUntilNoPendingElicitation(in session: SessionModel) async throws {
        let sessionId = session.sessionId
        let condition = "each elicitation of \(sessionId.rawValue) ends at the client"
        try await ObservedValue.wait(for: condition) {
            session.pendingElicitations.isEmpty || session.isClosed
        }
        if await !session.pendingElicitations.isEmpty {
            throw WaitEndedOnFailure(condition: condition, event: "the session closed")
        }
    }

    /// Waits until `session` holds a pending elicitation, and gives the
    /// first one.
    ///
    /// The wait also ends on two failure events (test rule T1):
    ///
    /// - The session closes.
    /// - The run settles: the session model shows the idle state after it
    ///   showed work. A state of `nil` or a state that is not idle at the
    ///   first read counts as work. An idle state at the first read is the
    ///   end of an earlier run, so it does not end the wait.
    ///
    /// When the elicitation and a failure event both came, the elicitation
    /// wins.
    ///
    /// - Parameters:
    ///   - session: The session model that receives the elicitations.
    ///   - sourceLocation: The line a failed read is reported at.
    /// - Returns: The first pending elicitation of the session.
    /// - Throws: ``WaitEndedOnFailure`` when the session closed or the run
    ///   settled first, and ``ConditionWaitCancelled`` when the test is
    ///   cancelled first.
    static func firstPendingElicitation(
        in session: SessionModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> PendingElicitation {
        let sessionId = session.sessionId
        let condition = "an elicitation of \(sessionId.rawValue) reaches the client"
        let settle = await RunSettleWatch()
        try await ObservedValue.wait(for: condition) {
            !session.pendingElicitations.isEmpty || session.isClosed || settle.settled(session.agentState)
        }
        if let first = await pendingElicitations(in: session).first {
            return first
        }
        let event = await session.isClosed ? "the session closed" : "the run settled"
        throw WaitEndedOnFailure(condition: condition, event: event)
    }
}

/// Finds the settle of a run in the reads of the state of a session model:
/// an idle state after a state of work.
@MainActor
final class RunSettleWatch {
    /// Whether a read already came.
    private var readOnce = false

    /// Whether a read showed work: a state of `nil`, or a state that is not
    /// idle.
    private var sawWork = false

    /// Makes a watch with no read.
    init() {}

    /// Reads one state of the session model.
    ///
    /// - Parameter state: The state of the agent that the model shows now.
    /// - Returns: `true` when `state` is idle and an earlier read, or this
    ///   read as the first one, showed work.
    func settled(_ state: StateUpdate?) -> Bool {
        let isIdle: Bool
        if case .idle = state {
            isIdle = true
        } else {
            isIdle = false
        }
        if !readOnce {
            readOnce = true
            sawWork = !isIdle
            return false
        }
        if !isIdle {
            sawWork = true
            return false
        }
        return sawWork
    }
}
