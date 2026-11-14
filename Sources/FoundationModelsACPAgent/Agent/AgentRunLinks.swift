import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter

extension RoutedACPAgent {
  /// Makes the links of the agent runs of one surface to this agent.
  ///
  /// A run marks its session as ended through the session directory when it reaches a real end.
  /// A restored run, and a firing of a scheduled agent, mail the result to a root session through
  /// the same directory, and the message projector of the root gives the client the views of that
  /// mail (``SubagentMessageProjector/mailed(_:from:to:text:)``). A claimed
  /// `start agent` call of a live root session ends through the session of the table, and the
  /// end returns after the projector of the session sent the final status of the call.
  ///
  /// - Parameter recordingRoot: The recording root of the session that owns the surface.
  /// - Returns: The links.
  nonisolated func makeAgentRunHost(recordingRoot: URL) -> AgentRunHost {
    let directory = sessionDirectory
    return AgentRunHost(
      recordingRoot: recordingRoot,
      sessionEnding: { session, reason in
        _ = try await directory.markEnded(session, reason: reason)
      },
      callerMail: { [weak self] message, sender, caller in
        let mail = OutgoingSessionMessage(
          from: .session(sender), to: .session(caller), text: message)
        do {
          let receipts = try await directory.send(mail)
          let delivered = receipts.first { $0.outcome != .refused }?.messageID
          if let delivered {
            // The client sees the mail as a message between the run and its caller.
            let recipient = SessionId(rawValue: caller.description)
            await self?.sessions[recipient]?.surface.runCallJoins.messages.mailed(
              delivered, from: SessionId(rawValue: sender.description), to: recipient,
              text: message)
          }
          return delivered
        } catch {
          // The links type cannot throw, so the reason of the failure goes to the log.
          ACPAgentTelemetry.logger(.session).warning(
            "The result mail of a restored run did not reach its caller session.",
            metadata: [
              ACPAgentTelemetry.LogMetadataKey.sessionId: "\(caller)",
              ACPAgentTelemetry.LogMetadataKey.errorType: "\(type(of: error))",
              "error.message": "\(error)",
            ])
          return nil
        }
      },
      claimCompletion: { [weak self] caller, key, outcome, detail in
        guard let entry = await self?.sessions[SessionId(rawValue: caller.description)] else {
          return false
        }
        // The completion goes through the Router session and the projector, in tasks of their
        // own. The host goes on after the projector sent the final status of the call, so a
        // later update of the host, for example the current state of a resume, comes after it.
        return await entry.projector.settlements.completing(key.correlationID) {
          await entry.session.completeClaimedRun(key, outcome: outcome, detail: detail)
        }
      })
  }
}
