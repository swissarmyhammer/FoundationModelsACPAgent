import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Logging

/// The store of the retained history of an imported session (D209): the importer gives it the
/// updates of the source after the Router directory wrote the new recording.
///
/// A store that the agent gives writes the history file of the session
/// (``SessionHistoryFile``), so `session/resume` replays the updates of the source and the
/// export gives their Markdown, and it gives the history to the transcript search index.
protocol ImportedHistoryStore: Sendable {
  /// Writes the retained history of an imported session.
  ///
  /// - Parameters:
  ///   - history: The retained history: the updates of the source session.
  ///   - session: The summary of the new session that the directory wrote.
  /// - Throws: The error of the write. The importer then removes the folder of the session
  ///   (``removeFolder(of:)``).
  func writeHistory(_ history: SessionMergeEngine, of session: SessionSummary) throws

  /// Removes the folder of an imported session whose history the store did not write. A
  /// removal that fails is logged.
  ///
  /// - Parameter session: The summary of the new session.
  func removeFolder(of session: SessionSummary)
}

/// The history store of the agent: it writes the history file of an imported session in the
/// transcript directory of the session (`<recording root>/<id>/`), with the same writer as a
/// fork, and gives the history to the transcript search index.
///
/// The recording root of the session is the root of its working folder
/// (``TranscriptRoot/recordingRoot(workingDirectory:name:)``): the root that the launcher of
/// the agent gives the import (``RoutedACPAgent/importTarget(for:)``).
struct AgentImportedHistoryStore: ImportedHistoryStore {
  /// The name of the dotfolder of the agent, which names the recording root of a folder.
  let name: DotfolderName

  /// The updates of the transcript search index of the agent.
  let searchUpdates: TranscriptSearchUpdates

  /// Writes the history file of the session and gives the history to the search index.
  ///
  /// - Parameters:
  ///   - history: The retained history.
  ///   - session: The summary of the new session.
  /// - Throws: The error of the write of the file.
  func writeHistory(_ history: SessionMergeEngine, of session: SessionSummary) throws {
    try SessionHistoryFile.write(history, in: transcriptDirectory(of: session))
    searchUpdates.indexHistory(history, of: SessionId(rawValue: session.id.description))
  }

  /// Removes the transcript directory of the session. A removal that fails is logged.
  ///
  /// - Parameter session: The summary of the new session.
  func removeFolder(of session: SessionSummary) {
    let directory = transcriptDirectory(of: session)
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      var metadata = ACPAgentTelemetry.errorMetadata(
        error, sessionId: SessionId(rawValue: session.id.description))
      metadata["path"] = .string(directory.path)
      ACPAgentTelemetry.logger(.session).error(
        "The folder of an imported session whose history was not written was not removed.",
        metadata: metadata)
    }
  }

  /// The transcript directory of a session: `<recording root>/<id>/`.
  ///
  /// - Parameter session: The summary of the session.
  /// - Returns: The directory.
  private func transcriptDirectory(of session: SessionSummary) -> URL {
    TranscriptRoot.recordingRoot(workingDirectory: session.workingDirectory, name: name)
      .appendingPathComponent(session.id.description, isDirectory: true)
  }
}
