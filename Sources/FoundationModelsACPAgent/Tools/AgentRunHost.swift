import Foundation
import FoundationModelsAgents

/// What the host gives to the agent runs of one surface, so a run can end for good and a later
/// process can restore a run that did not end.
///
/// A host without these links runs agents as before. Its runs mark no session as ended, and it
/// cannot restore an interrupted run (``AgentEnvironment/sessionEnding``).
public struct AgentRunHost: Sendable {
  /// The recording root of the sessions of the runs. It is the root of the session that owns the
  /// surface, so one session directory finds the root session and its runs.
  public let recordingRoot: URL

  /// Marks the session of a run as ended when the run reaches a real end.
  public let sessionEnding: AgentEnvironment.SessionEnding

  /// Mails the result of a restored run to its caller session, when that session is not a run.
  public let callerMail: AgentEnvironment.CallerMail

  /// Completes a claimed `start agent` call on the caller session.
  public let claimCompletion: AgentEnvironment.ClaimCompletion

  /// Makes the links of one surface.
  ///
  /// - Parameters:
  ///   - recordingRoot: The recording root of the sessions of the runs.
  ///   - sessionEnding: Marks the session of a run as ended.
  ///   - callerMail: Mails the result of a restored run to its caller session.
  ///   - claimCompletion: Completes a claimed call on the caller session.
  public init(
    recordingRoot: URL,
    sessionEnding: @escaping AgentEnvironment.SessionEnding,
    callerMail: @escaping AgentEnvironment.CallerMail,
    claimCompletion: @escaping AgentEnvironment.ClaimCompletion
  ) {
    self.recordingRoot = recordingRoot
    self.sessionEnding = sessionEnding
    self.callerMail = callerMail
    self.claimCompletion = claimCompletion
  }

  /// Gives the links to an environment.
  ///
  /// - Parameter environment: The environment that `AgentEnvironment.make(callerMail:)` made with
  ///   ``callerMail``.
  /// - Returns: The environment whose runs record under ``recordingRoot``, mark their sessions as
  ///   ended and complete the claimed calls.
  func linking(_ environment: AgentEnvironment) -> AgentEnvironment {
    environment
      .withRecordingRoot(recordingRoot)
      .withSessionEnding(sessionEnding)
      .withClaimCompletion(claimCompletion)
  }
}
