// `PendingQuestionWait` — the wait of a client for the first question that
// the agent asked in one session.
//
// The session model of the client keeps each question that waits for the
// user. A change of that list resumes the wait, so the wait uses no clock and
// no poll. A test that never gets the question stops at the time limit of its
// suite.

import FoundationModelsACPClient
import Observation

/// Waits for the question of an agent at the client end of one session.
@MainActor
enum PendingQuestionWait {
    /// Waits until `session` holds a pending question, and gives the first one.
    ///
    /// - Parameter session: The session model of the client.
    /// - Returns: The first pending question.
    static func first(in session: SessionModel) async -> PendingElicitation {
        while true {
            if let first = session.pendingElicitations.first {
                return first
            }
            // The check above and the observation below run with no
            // suspension between them, so no change of the list is lost.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = session.pendingElicitations
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
