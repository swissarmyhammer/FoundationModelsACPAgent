import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

extension RoutedACPAgent {
  /// The default rule "this folder is readable now" of the transcript search index of the agent
  /// (``transcriptSearchIndex``): each folder. A host with no sandbox, as the `acp-agent` CLI,
  /// can read each folder. An app in the App Sandbox gives its own rule to the initializer.
  ///
  /// - Parameter folder: A folder.
  /// - Returns: `true`.
  public static func everyFolderIsReadable(_ folder: URL) -> Bool {
    true
  }

  /// The reader of the summary of a session for the transcript search updates: `summary(of:)`
  /// of the session directory.
  ///
  /// - Parameter directory: The session directory of the agent.
  /// - Returns: The reader.
  static func directorySummaryReader(_ directory: RouterSessionDirectory)
    -> TranscriptSearchUpdates.SummaryReader
  {
    { id in try await directory.summary(of: id) }
  }
}

extension RoutedACPAgent {
  /// The retained history of a session of the session table for the transcript search: the
  /// history that ``writeHistory(of:)`` writes. A session that the table does not hold, a
  /// replay-only session and a history with no transcript entry give none.
  ///
  /// - Parameter sessionId: The session.
  /// - Returns: The history, or `nil`.
  func searchableHistory(of sessionId: SessionId) -> SessionMergeEngine? {
    guard let entry = sessions[sessionId], !entry.isReplayOnly, !entry.history.entries.isEmpty
    else {
      return nil
    }
    return entry.history
  }

  /// The sessions whose items a delete removes from the transcript search index: the deleted
  /// session, and each session recorded inside its folder under one of the roots. A folder
  /// whose sessions do not read is logged, and the delete removes the items of the deleted
  /// session only.
  ///
  /// - Parameters:
  ///   - sessionId: The deleted session.
  ///   - folderName: The name of the folder of the session under a recording root.
  ///   - roots: The candidate recording roots of the delete.
  /// - Returns: The sessions.
  static func transcriptSearchSessions(
    deleting sessionId: SessionId, folderName: String, under roots: [URL]
  ) -> Set<SessionId> {
    let nested = roots.flatMap { root in
      let folder = root.appendingPathComponent(folderName, isDirectory: true)
      do {
        return try RecordedSessionFolder.all(under: folder).map(\.sessionId)
      } catch {
        ACPAgentTelemetry.logger(.transcriptSearch).warning(
          "The sessions in a deleted folder cannot be read. The search keeps their items.",
          metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
        return []
      }
    }
    return Set([sessionId] + nested)
  }

  /// Starts the updates of the transcript search index: the read of the events of the session
  /// directory, and the reconcile at launch, in the background with a low priority. The
  /// reconcile reads the working folders of the project store, and the recording root of each
  /// one from its settings.
  ///
  /// - Parameter directory: The session directory of the agent.
  nonisolated func startTranscriptSearchUpdates(reading directory: RouterSessionDirectory) {
    transcriptSearchUpdates.start(reading: directory.events()) { [weak self] sessionId in
      await self?.searchableHistory(of: sessionId)
    }
    let store = settingsStore
    transcriptSearchUpdates.startReconcile(
      folders: {
        try ProjectStore(directory: RegisteredRecordingRoots.projectsDirectory(of: store))
          .projects().map { URL(fileURLWithPath: $0.path, isDirectory: true) }
      },
      recordingRoot: { folder in
        try await LoadedSessionContext.load(workingDirectory: folder, from: store).transcriptRoot
      })
  }
}
