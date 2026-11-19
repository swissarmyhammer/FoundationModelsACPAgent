import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The folder of one recorded session: its record (`index.md`) and the folder that holds it.
struct RecordedSessionFolder: Sendable {
  /// The record of the session.
  let record: SessionRecord

  /// The folder of the session: `<root>/<id>/`, or `<root>/<source>/<id>/` for a fork.
  let directory: URL

  /// The session id.
  var sessionId: SessionId {
    SessionId(rawValue: record.sessionId.description)
  }

  /// The folder of each session recorded under `directory`, at any depth: each session folder
  /// that holds a record, and then the session folders inside it. A fork records in the folder
  /// of its source, so the walk finds it in the folder of its source.
  ///
  /// - Parameter directory: A recording root, or the folder of a session.
  /// - Returns: The folders, each folder before the folders inside it.
  /// - Throws: The error of `RouterSessionDirectory.recordedSessions(in:)`: the listing of a
  ///   folder that exists, or the read of an `index.md` that does not decode.
  static func all(under directory: URL) throws -> [RecordedSessionFolder] {
    try RouterSessionDirectory.recordedSessions(in: directory).flatMap { record in
      let folder = RecordedSessionFolder(
        record: record,
        directory: directory.appendingPathComponent(
          record.sessionId.ulidString, isDirectory: true))
      return [folder] + (try all(under: folder.directory))
    }
  }
}

/// What the reconcile read for one recorded session.
enum RecordedHistoryRead: Sendable {
  /// The history file read: the content of the session.
  case content(TranscriptSearchIndex.SessionContent)

  /// The session folder holds no history file.
  case noFile

  /// The history file did not read.
  case unreadable

  /// Reads the history file of one recorded session. A file that does not read is logged.
  ///
  /// - Parameter session: The folder of the session.
  /// - Returns: The content of the session, or why it has none.
  static func read(_ session: RecordedSessionFolder) -> RecordedHistoryRead {
    do {
      guard let history = try SessionHistoryFile.read(from: session.directory) else {
        return .noFile
      }
      return .content(
        TranscriptSearchIndex.SessionContent(
          chunks: history.searchChunks, metadata: TranscriptSessionMetadata(record: session.record))
      )
    } catch {
      ACPAgentTelemetry.logger(.transcriptSearch).warning(
        "The history of a session did not read. The transcript search keeps its items.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: session.sessionId))
      return .unreadable
    }
  }
}

extension TranscriptSearchApplier {
  /// Reconciles the index with the history files of one working folder.
  ///
  /// The reconcile reads the record and the `session-history.json` of each session folder of
  /// the recording root, and gives the chunk items and the session item of each session that
  /// has a history file, in one change of the catalog. The registry does no work for an item
  /// that did not change. It then removes the items of each session of the folder that the
  /// index holds and that has no history file. A history file that does not read is logged,
  /// and the items of its session stay. A root that does not read is logged, and each item of
  /// the folder stays.
  ///
  /// - Parameter folder: The working folder and its recording root.
  func reconcile(_ folder: TranscriptSearchFolder) async {
    let recorded: [RecordedSessionFolder]
    do {
      recorded = try RecordedSessionFolder.all(under: folder.recordingRoot)
    } catch {
      ACPAgentTelemetry.logger(.transcriptSearch).warning(
        "The sessions of a recording root cannot be read. The transcript search keeps their items.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
      return
    }
    let reads = recorded.map { (session: $0.sessionId, read: RecordedHistoryRead.read($0)) }
    let contents = Dictionary(
      reads.compactMap { entry -> (SessionId, TranscriptSearchIndex.SessionContent)? in
        guard case .content(let content) = entry.read else {
          return nil
        }
        return (entry.session, content)
      }, uniquingKeysWith: { first, _ in first })
    let unreadable = Set(
      reads.compactMap { entry -> SessionId? in
        guard case .unreadable = entry.read else {
          return nil
        }
        return entry.session
      })
    let folderKey = AgentHome.projectKey(of: folder.folder)
    let removed = await index.indexedSessions().filter { session, metadata in
      AgentHome.projectKey(of: metadata.folder) == folderKey && contents[session] == nil
        && !unreadable.contains(session)
    }
    await index.index(contents, removing: Set(removed.keys))
  }
}
