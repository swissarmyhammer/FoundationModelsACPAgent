import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter

extension RoutedACPAgent {
  /// Makes the links of the agent runs of one surface to this agent.
  ///
  /// A run marks its session as ended through the session directory when it reaches a real end.
  /// A restored run mails its result to a root session through the same directory. A claimed
  /// `start agent` call of a live root session ends through the session of the table.
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
      callerMail: { message, sender, caller in
        let mail = OutgoingSessionMessage(
          from: .session(sender), to: .session(caller), text: message)
        do {
          let receipts = try await directory.send(mail)
          return receipts.first { $0.outcome != .refused }?.messageID
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
        guard let session = await self?.sessions[SessionId(rawValue: caller.description)]?.session
        else {
          return false
        }
        return await session.completeClaimedRun(key, outcome: outcome, detail: detail)
      })
  }
}
