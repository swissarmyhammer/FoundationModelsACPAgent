import ACPMarkdown
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter

// The export of a session as Markdown (D202).
//
// The `export session` operation of the `sessions` tool and the `export` field of the `sessions`
// endpoint need the Markdown of a session. The agent makes it from the retained history of the
// session: the same updates that `session/resume` replays. The renderer of FoundationModelsACP
// makes the text. Thus the agent and the UI give the same document for the same session.

/// The error of an export of a session that has no history in this server.
///
/// A session whose updates did not go through this server has no history here. A session that an
/// earlier build recorded has no history file either. The `sessions` tool and endpoint put the
/// text of this error in their corrective.
enum SessionTranscriptExportError: Error, CustomStringConvertible {
  /// The server has no retained history of the session.
  case noHistory

  /// The corrective: the UI can export the session from what it shows.
  var description: String {
    "This server has no history of the session. Use Export as Markdown… in the app."
  }
}

/// The exporter of the transcripts of the sessions of an agent (D202). The agent gives one to the
/// `sessions` tool of each session (``ToolCatalog/makeSessionsTool(context:)``), and the tool gives
/// it to the one `sessions` endpoint of the session directory.
///
/// The exporter holds the agent weakly. The endpoint of the directory holds the exporter, and the
/// agent holds the directory. When the agent is gone, each export throws
/// ``SessionTranscriptExportError/noHistory``.
final class AgentTranscriptExporter: SessionTranscriptExporter, @unchecked Sendable {
  /// The agent whose sessions the exporter renders. Weak, to break the cycle agent → directory →
  /// endpoint → exporter → agent. It is set one time, in the initializer, and never changes.
  private weak var agent: RoutedACPAgent?

  /// Makes the exporter of `agent`.
  ///
  /// - Parameter agent: The agent.
  init(agent: RoutedACPAgent) {
    self.agent = agent
  }

  /// The Markdown of the transcript of a session
  /// (``RoutedACPAgent/transcriptMarkdown(of:includeThoughts:)``).
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - includeThoughts: True to include the thoughts of the agent.
  /// - Returns: The Markdown document.
  /// - Throws: ``SessionTranscriptExportError/noHistory`` when the agent is gone or has no history
  ///   of the session, or the error of a read of the history.
  func markdown(of session: ULID, includeThoughts: Bool) async throws -> String {
    guard let agent else {
      throw SessionTranscriptExportError.noHistory
    }
    return try await agent.transcriptMarkdown(of: session, includeThoughts: includeThoughts)
  }
}

extension RoutedACPAgent {
  /// The Markdown of the transcript of a session, from its retained history.
  ///
  /// The text is the render of the transcript updates that a `session/resume` replays
  /// (``SessionMergeEngine/replayedTranscriptUpdates``). The title is the title of the session in
  /// the session directory, and the heading of the turns of the agent is the name of the agent of
  /// the session. The labels are English. The same history and the same options always give the
  /// same text.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - includeThoughts: True to include the thoughts of the agent.
  /// - Returns: The Markdown document.
  /// - Throws: ``SessionTranscriptExportError/noHistory`` when this server has no history of the
  ///   session, or the error of a read of the directory, the configuration or the history file.
  func transcriptMarkdown(of id: ULID, includeThoughts: Bool) async throws -> String {
    let summary = try await sessionDirectory.summary(of: id)
    guard let history = try await exportedHistory(of: id, summary: summary) else {
      throw SessionTranscriptExportError.noHistory
    }
    let options = SessionMarkdown.Options(
      includeThoughts: includeThoughts, title: summary?.title, agentName: summary?.agentName,
      labels: .english)
    return SessionMarkdown.render(updates: history.replayedTranscriptUpdates, options: options)
  }

  /// The retained history of a session for an export.
  ///
  /// It is the history in the table when this process holds the session. Else it is the history
  /// that a cold `session/resume` restores: the history file in the transcript directory of the
  /// session, with the plans that the Router journal recorded
  /// (``resumedHistory(kept:directory:rootId:sessionId:)``).
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - summary: The summary of the session in the directory, or `nil` when the directory does
  ///     not know the session.
  /// - Returns: The history, or `nil` when the session is not in the table and has no history file.
  /// - Throws: The error of the resolution of the configuration or of the read of the file.
  private func exportedHistory(of id: ULID, summary: SessionSummary?) async throws
    -> SessionMergeEngine?
  {
    let sessionId = SessionId(rawValue: id.description)
    if let entry = sessions[sessionId] {
      return entry.history
    }
    guard let summary else {
      return nil
    }
    let context = try await loadSessionContext(workingDirectory: summary.workingDirectory)
    let directory = context.transcriptRoot.appendingPathComponent(
      id.description, isDirectory: true)
    guard let recorded = try SessionHistoryFile.read(from: directory) else {
      return nil
    }
    return resumedHistory(kept: recorded, directory: directory, rootId: id, sessionId: sessionId)
  }
}
