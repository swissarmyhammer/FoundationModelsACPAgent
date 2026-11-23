import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Logging

/// An error of the copy of ``AgentSessionImporter``. `continueExternalSession(_:)` maps each
/// case to an ``ExternalSessionError`` when one fits, and the `sessions` tool shows the text of
/// each other case in the corrective of a failed continue.
enum AgentSessionImportError: Error, Equatable, CustomStringConvertible {
  /// The copy names an agent that the importer does not know.
  case unknownAgent(String)

  /// The index has no root of this agent: the user gave no access to its sessions.
  case sourceUnreadable(agent: String)

  /// The folder of the new session does not exist, or the host cannot read it.
  case folderUnavailable(URL)

  /// The root of the agent holds no session with this id or this path.
  case unknownSource(String)

  /// The copy gives no folder, and the source session with this id gives no folder either.
  case noFolder(String)

  /// The text of the error in a corrective.
  var description: String {
    switch self {
    case .unknownAgent(let agent):
      let known = ImportSourceAgent.allCases.map(\.rawValue).joined(separator: ", ")
      return "the agent \(agent) is not a source of a copy. The sources are: \(known)"
    case .sourceUnreadable(let agent):
      return "there is no access to the sessions of \(agent)"
    case .folderUnavailable(let folder):
      return "the folder \(folder.path) does not exist, or this app has no access to it"
    case .unknownSource(let source):
      return
        "the source \(source) is not a session of the agent. "
        + "Use the id of a session of list external sessions"
    case .noFolder(let source):
      return
        "the session \(source) names no folder. Give the folder of the new session"
    }
  }
}

/// The importer of the sessions of other agents (D209 (d), (e), D212): the host of the external
/// sessions of the `sessions` tool and of the `sessions` endpoint
/// (`AgentSessionImporter+ExternalSessionHost.swift`).
///
/// It holds the index of external sessions (``ExternalSessionIndex``), which the list reads.
/// The continue of an external session is a copy (``copySession(of:folder:name:)``): it finds
/// its source in the index, and reads that one file whole.
///
/// The host gives the roots of the source agents that it can read (`~/.claude`, `~/.codex`) to
/// the index. The host can replace the roots while the agent runs (``replaceRoots(_:)``): a
/// sandboxed app gets the access to a root after the launch. The importer runs no child
/// process (D128) and changes no file of a root.
struct AgentSessionImporter: Sendable {
  /// The index of the external sessions, over the roots of the host.
  let index: ExternalSessionIndex

  /// The session directory, for the new sessions.
  private let directory: any SessionDirectory

  /// The store of the history of each new session.
  private let historyStore: any ImportedHistoryStore

  /// Makes the importer.
  ///
  /// - Parameters:
  ///   - index: The index of the external sessions. A source with no root in the index is in
  ///     the `unreadableSources` of each page of the external sessions.
  ///   - directory: The session directory.
  ///   - historyStore: The store of the history of each new session.
  init(
    index: ExternalSessionIndex, directory: any SessionDirectory,
    historyStore: any ImportedHistoryStore
  ) {
    self.index = index
    self.directory = directory
    self.historyStore = historyStore
  }

  /// Replaces all the roots of the index. A root that is new starts a build of the index. The
  /// index forgets the entries and the index file of each source agent whose root changed or
  /// is gone. A source agent whose root is the same keeps its entries.
  ///
  /// - Parameter newRoots: The root of each source agent that the host can read now. A source
  ///   with no root is in the `unreadableSources` of each page of the external sessions.
  func replaceRoots(_ newRoots: [ImportSourceAgent: URL]) async {
    await index.replaceRoots(newRoots)
  }

  /// Copies a source session into a new session of the agent (D209, D212, Q83, Q84, Q85): the
  /// copy of `continueExternalSession(_:)`.
  ///
  /// The importer finds the source in the index, reads the source file whole, makes the model
  /// transcript of its updates (``ImportedTranscript``), and gives it to the session
  /// directory, which writes the recording of a new root session with the origin `import` and
  /// the provenance of the source. The history store then writes the updates as the retained
  /// history of the new session (``ImportedHistoryStore``). When that write fails, the importer
  /// removes the folder of the new session and gives the error.
  ///
  /// Each copy makes a new session, also for a source that an earlier copy read (Q85). The
  /// folder of the new session is `folder`, else the folder of the source session. The name is
  /// `name`, else the title of the source, else `<agent>-import` (Q84). The directory adds the
  /// next free number to a name that a session of the folder has. The importer only reads the
  /// source file: it never changes, moves or deletes it.
  ///
  /// - Parameters:
  ///   - session: The source session: its agent, and its id or the path of its file.
  ///   - folder: The folder of the new session, or `nil` for the folder of the source session.
  ///   - name: The name of the new session, or `nil`.
  /// - Returns: The summary of the new session.
  /// - Throws: ``AgentSessionImportError/unknownAgent(_:)`` for an unknown agent,
  ///   ``AgentSessionImportError/sourceUnreadable(agent:)`` for an agent with no root,
  ///   ``AgentSessionImportError/folderUnavailable(_:)`` for a folder that does not exist or
  ///   that the host cannot read, ``AgentSessionImportError/unknownSource(_:)`` for a source
  ///   that the root does not hold, ``AgentSessionImportError/noFolder(_:)`` for a copy with no
  ///   folder of a source with no folder, and the error of the read, of the directory or of the
  ///   history store.
  func copySession(of session: ExternalSessionID, folder: URL?, name: String?) async throws
    -> SessionSummary
  {
    let agent = try Self.agent(named: session.source)
    guard await index.sources.contains(agent) else {
      throw AgentSessionImportError.sourceUnreadable(agent: session.source)
    }
    try Self.requireFolder(folder)
    guard let source = await index.session(matching: session.sourceID, of: agent) else {
      throw AgentSessionImportError.unknownSource(session.sourceID)
    }
    let folder = try Self.folder(folder, source: source)
    let imported = try agent.session(
      from: FileByteSource(forReadingFrom: source.file), fileNamed: source.file.lastPathComponent)
    let request = Self.request(named: name, source: source, imported: imported, folder: folder)
    let summary = try await directory.importSession(
      request, transcript: ImportedTranscript.make(from: imported.updates))
    try writeHistory(of: imported, for: summary)
    ACPAgentTelemetry.logger(.session).info(
      "The importer made a new session from a session of another agent.",
      metadata: ACPAgentTelemetry.sessionMetadata(SessionId(rawValue: summary.id.description)))
    return summary
  }

  /// Writes the updates of the source as the retained history of the new session. When the
  /// write fails, the folder of the new session is removed.
  ///
  /// - Parameters:
  ///   - imported: The session that the reader read.
  ///   - summary: The summary of the new session.
  /// - Throws: The error of the write.
  private func writeHistory(of imported: ImportedSession, for summary: SessionSummary) throws {
    do {
      try historyStore.writeHistory(SessionMergeEngine(replaying: imported.updates), of: summary)
    } catch {
      historyStore.removeFolder(of: summary)
      throw error
    }
  }

  /// The import request of a copy for the session directory.
  ///
  /// - Parameters:
  ///   - name: The name of the new session, or `nil`.
  ///   - source: The source session in the index.
  ///   - imported: The session that the reader read.
  ///   - folder: The folder of the new session.
  /// - Returns: The request: the folder, the name (Q84) and the provenance of the source. The
  ///   source title of the provenance is the title that the index gives for the source.
  private static func request(
    named name: String?, source: LocatedExternalSession, imported: ImportedSession,
    folder: URL
  ) -> SessionImportRequest {
    let agent = source.summary.source
    let title =
      [name, imported.metadata.title].compactMap { $0 }.first { !$0.isEmpty }
      ?? "\(agent)-import"
    return SessionImportRequest(
      workingDirectory: folder, title: title,
      provenance: SessionImportProvenance(
        agent: agent, sourceID: source.summary.sourceID, sourcePath: source.file.path,
        sourceTitle: source.summary.title, sourceLastDate: imported.metadata.lastDate,
        importedAt: Date(), skippedRecordCount: imported.skippedRecordCount))
  }

  // MARK: - The names and the folders

  /// The source agent of a name.
  ///
  /// - Parameter name: The name, for example `claude-code`.
  /// - Returns: The agent.
  /// - Throws: ``AgentSessionImportError/unknownAgent(_:)`` for a name of no agent.
  private static func agent(named name: String) throws -> ImportSourceAgent {
    guard let agent = ImportSourceAgent(rawValue: name) else {
      throw AgentSessionImportError.unknownAgent(name)
    }
    return agent
  }

  /// Checks the folder of a new session: the folder must exist, and the host must be able to
  /// read it. No folder passes, because the copy then uses the folder of the source session.
  ///
  /// - Parameter folder: The folder of the new session, or `nil`.
  /// - Throws: ``AgentSessionImportError/folderUnavailable(_:)`` for a folder that does not
  ///   exist or that the host cannot read.
  private static func requireFolder(_ folder: URL?) throws {
    guard let folder else { return }
    guard PathKind.of(folder) == .directory,
      FileManager.default.isReadableFile(atPath: folder.path)
    else {
      throw AgentSessionImportError.folderUnavailable(folder)
    }
  }

  /// The folder of the new session of a copy: the folder of the copy, else the folder of the
  /// source session. The folder must exist, and the host must be able to read it.
  ///
  /// - Parameters:
  ///   - folder: The folder of the copy, or `nil`.
  ///   - source: The source session.
  /// - Returns: The folder.
  /// - Throws: ``AgentSessionImportError/noFolder(_:)`` when the copy and the source give no
  ///   folder, and ``AgentSessionImportError/folderUnavailable(_:)`` for a folder that does not
  ///   exist or that the host cannot read.
  private static func folder(_ folder: URL?, source: LocatedExternalSession) throws -> URL {
    guard let folder = folder ?? source.summary.cwd else {
      throw AgentSessionImportError.noFolder(source.summary.sourceID)
    }
    try requireFolder(folder)
    return folder
  }
}
