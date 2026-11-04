import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter

/// One `start agent` call that the journal of a caller holds as open: the Router write-ahead
/// marker of the call (``TranscriptEvent/Kind/toolCallStarted``).
struct RecordedOpenCall: Equatable, Sendable {
  /// The SDK tool call id. The client knows the call by this id.
  let callId: String

  /// The name of the tool.
  let toolName: String

  /// The arguments of the call, as JSON text.
  let argumentsJSON: String
}

/// The part of a journal entry that holds tool calls. The entry type of Router keeps its tool calls
/// internal, so the host reads them through its public `Codable` form.
private struct RecordedToolCalls: Decodable {
  /// One call of the entry.
  struct Call: Decodable {
    /// The SDK tool call id.
    let id: String

    /// The name of the tool.
    let toolName: String

    /// The arguments of the call, as JSON text.
    let argumentsJSON: String

    /// The completion token of the run that the call started, or `nil` for a call with no run.
    let correlationID: String?
  }

  /// The calls of the entry, or `nil` for an entry of another kind.
  let toolCalls: [Call]?
}

/// The open `start agent` calls of a cold-restored tree.
///
/// The cold resume restores the interrupted children idle. The original call of each child is
/// open in the journal of its caller, but the process that made it is gone. Two things of the
/// live process are gone with it. First, the join of the call id to the completion token
/// (``RunCallJoinTable``): without it the completion after the re-drive goes out on the token as
/// its id, and the client keeps the original call open. Second, the history of the caller can lack
/// the call: the retained history is written at the end of a prompt, and a killed process never
/// wrote it. A replay then shows no call at all.
///
/// The restore reads the write-ahead marker of each call from the journal of its caller. It
/// rebuilds the join, and it adds the call, in progress, to the history when the history holds
/// none. It adds the announcement of the child too, linked to the call, because a replay
/// announces a child before it sends any update of the child stream. A call with no final status
/// stays an interrupted call.
extension RoutedACPAgent {
  /// Rebuilds the join and the history of the original call of each restored run. Call it after
  /// the restored sessions are registered, and before the replay.
  ///
  /// - Parameter report: The report of the restore.
  func restoreOpenCalls(of report: RestoreReport) async {
    for run in report.restored {
      guard let caller = run.caller, let token = run.completionToken,
        let entry = sessions[SessionId(rawValue: caller.description)]
      else {
        continue
      }
      let callerId = SessionId(rawValue: caller.description)
      guard let call = openCall(of: token, in: entry.session.recordingDirectory, caller: caller)
      else {
        continue
      }
      let joins = entry.projector.runCallJoins
      joins.record(toolCallID: call.callId, for: RunToken(token))
      // The live open record places this hold: the final status of the call waits for the end of
      // the child, so it comes after the last update of the child.
      joins.holds.hold(token)
      recordOpenCall(call, of: run, in: callerId)
    }
  }

  /// Adds the call to the history of its caller as in progress, linked to its child, unless the
  /// history holds an update of the call already. Adds the announcement of the child, linked to
  /// the call, unless the history holds one.
  ///
  /// - Parameters:
  ///   - call: The recorded call.
  ///   - run: The restored run that the call started.
  ///   - caller: The session that made the call.
  private func recordOpenCall(_ call: RecordedOpenCall, of run: AgentRun, in caller: SessionId) {
    let id = ToolCallId(rawValue: call.callId)
    let known = sessions[caller]?.history.replayUpdates(from: .start).contains {
      if case .toolCallUpdate(let update) = $0 {
        return update.toolCallId == id
      }
      return false
    }
    let child = SessionId(rawValue: run.id.description)
    if sessions[caller]?.history.announced(child) == nil {
      recordAnnouncement(of: run, linkedTo: id, in: caller)
    }
    guard known == false else {
      return
    }
    var update = ToolCallUpdate(toolCallId: id)
    update.name = .value(call.toolName)
    update.title = .value(call.toolName)
    update.status = .value(.inProgress)
    if let input = try? JSONDecoder().decode(
      FoundationModelsACP.JSONValue.self, from: Data(call.argumentsJSON.utf8))
    {
      update.rawInput = .value(input)
    }
    update.meta = .value(
      (try? SAH.AgentRun(sessionId: SessionId(rawValue: run.id.description)).inject(into: nil))
        ?? .object([:]))
    recordInHistory(.toolCallUpdate(update), of: caller)
  }

  /// Adds the announcement of a restored child to the history of its caller. It holds the title
  /// and the link to the call. The state and the capabilities come with the current snapshot, after
  /// the response.
  ///
  /// - Parameters:
  ///   - run: The restored run.
  ///   - call: The wire id of the call that started the run.
  ///   - caller: The session that made the call.
  private func recordAnnouncement(of run: AgentRun, linkedTo call: ToolCallId, in caller: SessionId)
  {
    var announcement = SubagentUpdate(
      sessionId: SessionId(rawValue: run.id.description), title: .value(run.agent.id))
    do {
      announcement.meta = .value(try SAH.AgentRun(toolCallId: call).inject(into: nil))
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The link of a restored child to its call did not encode. The announcement has no link.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: caller))
    }
    recordInHistory(.subagentUpdate(announcement), of: caller)
  }

  /// The open call of a run, from the write-ahead markers of the journal of its caller.
  ///
  /// - Parameters:
  ///   - token: The completion token of the run.
  ///   - directory: The recording directory of the caller.
  ///   - caller: The session that made the call.
  /// - Returns: The call, or `nil` when the journal holds no marker for the token or cannot be
  ///   read. A journal that cannot be read is logged.
  private func openCall(of token: String, in directory: URL, caller: ULID) -> RecordedOpenCall? {
    do {
      for event in try TranscriptEvent.merged(under: directory)
      where event.sessionId == caller && event.kind == .toolCallStarted {
        let calls = try JSONDecoder().decode(
          RecordedToolCalls.self, from: JSONEncoder().encode(event.entry))
        if let call = calls.toolCalls?.first(where: { $0.correlationID == token }) {
          return RecordedOpenCall(
            callId: call.id, toolName: call.toolName, argumentsJSON: call.argumentsJSON)
        }
      }
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).error(
        "The journal of a caller did not read. The original call of a restored run stays unjoined.",
        metadata: ACPAgentTelemetry.errorMetadata(
          error, sessionId: SessionId(rawValue: caller.description)))
    }
    return nil
  }
}
