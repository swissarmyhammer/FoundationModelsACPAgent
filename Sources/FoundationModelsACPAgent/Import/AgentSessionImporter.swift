import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import Logging

/// An error of ``AgentSessionImporter`` that the `sessions` tool shows in the corrective of a
/// failed list or a failed import.
enum AgentSessionImportError: Error, Equatable, CustomStringConvertible {
  /// The request names an agent that the importer does not know.
  case unknownAgent(String)

  /// The cursor of the request is not a cursor of the importer.
  case invalidCursor(String)

  /// The root of the agent holds no session with this id or this path.
  case unknownSource(String)

  /// The order gives no folder, and the source session with this id gives no folder either.
  case noFolder(String)

  /// The text of the error in a corrective.
  var description: String {
    switch self {
    case .unknownAgent(let agent):
      let known = ImportSourceAgent.allCases.map(\.rawValue).joined(separator: ", ")
      return "the agent \(agent) is not a source of an import. The sources are: \(known)"
    case .invalidCursor(let cursor):
      return "the cursor \(cursor) is not the cursor of a page. Use the cursor of the last page"
    case .unknownSource(let source):
      return
        "the source \(source) is not a session of the agent. Use the id or the path of a session of list imports"
    case .noFolder(let source):
      return
        "the session \(source) names no folder. Give the folder of the new session"
    }
  }
}

/// The importer of the sessions of other agents (D209 (d), (e), (l)): the `list imports` and
/// `import session` operations of the `sessions` tool and the import fields of the `sessions`
/// endpoint call it.
///
/// The list reads the index of external sessions (``ExternalSessionIndex``, D212): it never
/// reads a session file, and it never waits for the build of the index. It gives the typed
/// sessions in the state `read` only, with no count of the turns. The import is a copy: it
/// finds its source in the index, and reads that one file whole.
///
/// The host gives the roots of the source agents that it can read (`~/.claude`, `~/.codex`) to
/// the index. The host can replace the roots while the agent runs (``replaceRoots(_:)``): a
/// sandboxed app gets the access to a root after the launch. The importer runs no child
/// process (D128) and changes no file of a root.
///
/// The list of the earlier imports of a source comes from ``SessionSummary/importedFrom`` of the
/// sessions of the directory. It is only information: an import of the source makes a new
/// session also when the source has earlier imports (Q85).
struct AgentSessionImporter: SessionImporter {
  /// The index of the external sessions, over the roots of the host.
  let index: ExternalSessionIndex

  /// The session directory, for the earlier imports and for the new sessions.
  private let directory: any SessionDirectory

  /// The store of the history of each new session.
  private let historyStore: any ImportedHistoryStore

  /// Makes the importer.
  ///
  /// - Parameters:
  ///   - index: The index of the external sessions. A source with no root in the index is in
  ///     the `unreadableSources` of each page.
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
  ///   with no root is in the `unreadableSources` of each page.
  func replaceRoots(_ newRoots: [ImportSourceAgent: URL]) async {
    await index.replaceRoots(newRoots)
  }

  /// The typed sessions of the readable source agents that the index has read, the newest
  /// first, with the sessions of the preferred folder first.
  ///
  /// The list reads the index only, and it does not wait for the build of the index. A
  /// request with a folder puts the files of that folder first in the read queue of the
  /// index. A row has no count of the turns (`turnCount` is 0).
  ///
  /// - Parameter request: The agent, the folder, the preferred folder and the page.
  /// - Returns: One page of the list, and each requested agent with no root.
  /// - Throws: ``AgentSessionImportError`` for an unknown agent and for a cursor that is not
  ///   a cursor of the importer, `CancellationError` when the task is cancelled (the files of
  ///   the folder then go back to level 2 of the read queue of the index), and the error of
  ///   the directory.
  func importable(_ request: ImportableSessionsRequest) async throws -> ImportableSessionsPage {
    let agents = try request.agent.map { [try Self.agent(named: $0)] } ?? ImportSourceAgent.allCases
    let earlierImports = try await previousImports()
    let rows = try await index.sessions(of: agents, folder: request.folder, automated: false)
    let ordered = Self.ordered(
      rows, preferring: request.preferredFolder.map(ExternalSessionFolderMatch.init(folder:)))
    guard
      let page = ExternalSessionPaging.page(
        of: ordered, limit: request.limit, cursor: request.cursor)
    else {
      throw AgentSessionImportError.invalidCursor(request.cursor ?? "")
    }
    let sources = await index.sources
    return ImportableSessionsPage(
      sessions: page.rows.map { Self.row(of: $0, earlierImports: earlierImports) },
      nextCursor: page.nextCursor,
      unreadableSources: agents.filter { !sources.contains($0) }.map(\.rawValue))
  }

  /// Imports a source session into a new session of the agent (D209, Q83, Q84, Q85).
  ///
  /// The importer finds the source in the index, reads the source file whole, makes the model
  /// transcript of its updates (``ImportedTranscript``), and gives it to the session
  /// directory, which writes the recording of a new root session with the origin `import` and
  /// the provenance of the source. The history store then writes the updates as the retained
  /// history of the new session (``ImportedHistoryStore``). When that write fails, the importer
  /// removes the folder of the new session and gives the error.
  ///
  /// Each import makes a new session, also for a source that an earlier import read (Q85). The
  /// folder of the new session is the folder of the order, else the folder of the source
  /// session. The name is the name of the order, else the title of the source, else
  /// `<agent>-import` (Q84). The directory adds the next free number to a name that a session
  /// of the folder has. The importer only reads the source file: it never changes, moves or
  /// deletes it.
  ///
  /// - Parameter order: The source session, and the folder and the name of the new session.
  /// - Returns: The id and the name of the new session, and the number of records of the source
  ///   that the reader did not read.
  /// - Throws: ``AgentSessionImportError/unknownAgent(_:)`` for an unknown agent,
  ///   `SessionImportError.sourceUnreadable(agent:)` for an agent with no root,
  ///   `SessionImportError.folderUnavailable(_:)` for a folder that does not exist or that the
  ///   host cannot read, ``AgentSessionImportError/unknownSource(_:)`` for a source that the
  ///   root does not hold, ``AgentSessionImportError/noFolder(_:)`` for an order with no folder
  ///   of a source with no folder, and the error of the read, of the directory or of the
  ///   history store.
  func importSession(_ order: SessionImportOrder) async throws -> SessionImportResult {
    let agent = try Self.agent(named: order.agent)
    guard await index.sources.contains(agent) else {
      throw SessionImportError.sourceUnreadable(agent: order.agent)
    }
    try Self.requireFolder(order.folder)
    guard let source = await index.session(matching: order.source, of: agent) else {
      throw AgentSessionImportError.unknownSource(order.source)
    }
    let folder = try Self.folder(of: order, source: source)
    let imported = try agent.session(
      of: Data(contentsOf: source.file, options: .mappedIfSafe), in: source.file)
    let request = Self.request(for: order, source: source, imported: imported, folder: folder)
    let summary = try await directory.importSession(
      request, transcript: ImportedTranscript.make(from: imported.updates))
    try writeHistory(of: imported, for: summary)
    ACPAgentTelemetry.logger(.session).info(
      "The importer made a new session from a session of another agent.",
      metadata: ACPAgentTelemetry.sessionMetadata(SessionId(rawValue: summary.id.description)))
    return SessionImportResult(
      session: summary.id, name: summary.title ?? request.title,
      skippedRecordCount: imported.skippedRecordCount)
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

  /// The import request of an order for the session directory.
  ///
  /// - Parameters:
  ///   - order: The order.
  ///   - source: The source session in the index.
  ///   - imported: The session that the reader read.
  ///   - folder: The folder of the new session.
  /// - Returns: The request: the folder, the name (Q84) and the provenance of the source. The
  ///   source title of the provenance is the title that ``importable(_:)`` shows for the source.
  private static func request(
    for order: SessionImportOrder, source: LocatedExternalSession, imported: ImportedSession,
    folder: URL
  ) -> SessionImportRequest {
    let agent = source.summary.source
    let title =
      [order.name, imported.metadata.title].compactMap { $0 }.first { !$0.isEmpty }
      ?? "\(agent)-import"
    return SessionImportRequest(
      workingDirectory: folder, title: title,
      provenance: SessionImportProvenance(
        agent: agent, sourceID: source.summary.sourceID, sourcePath: source.file.path,
        sourceTitle: source.summary.title, sourceLastDate: imported.metadata.lastDate,
        importedAt: Date(), skippedRecordCount: imported.skippedRecordCount))
  }

  // MARK: - The rows and the page

  /// The earlier imports of each source session, by the agent and the source id, the oldest
  /// first.
  ///
  /// - Returns: The earlier imports.
  /// - Throws: The error of the directory.
  private func previousImports() async throws -> [ImportSourceKey: [SessionPreviousImport]] {
    let summaries = try await directory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    let imports = summaries.compactMap { summary in
      summary.importedFrom.map { provenance in
        (
          key: ImportSourceKey(agent: provenance.agent, sourceID: provenance.sourceID),
          value: SessionPreviousImport(session: summary.id, importedAt: provenance.importedAt)
        )
      }
    }
    return Dictionary(grouping: imports, by: \.key).mapValues {
      $0.map(\.value).sorted { $0.importedAt < $1.importedAt }
    }
  }

  /// The row of one session. The index has no count of the turns, thus `turnCount` is 0.
  ///
  /// - Parameters:
  ///   - session: The session in the index.
  ///   - earlierImports: The earlier imports of each source session.
  /// - Returns: The row.
  private static func row(
    of session: LocatedExternalSession,
    earlierImports: [ImportSourceKey: [SessionPreviousImport]]
  ) -> ImportableSession {
    let summary = session.summary
    return ImportableSession(
      agent: summary.source, sourceID: summary.sourceID, sourcePath: session.file.path,
      title: summary.title, folder: summary.cwd, lastDate: summary.lastDate, turnCount: 0,
      previousImports: earlierImports[
        ImportSourceKey(agent: summary.source, sourceID: summary.sourceID)] ?? [])
  }

  /// The sessions in the order of the list: the sessions of the preferred folder first, then
  /// the order of the index (the newest first).
  ///
  /// - Parameters:
  ///   - sessions: The sessions, the newest first.
  ///   - preferredFolder: The match of the folder whose sessions come first, or `nil`.
  /// - Returns: The ordered sessions.
  private static func ordered(
    _ sessions: [LocatedExternalSession], preferring preferredFolder: ExternalSessionFolderMatch?
  ) -> [LocatedExternalSession] {
    guard let preferredFolder else { return sessions }
    let preferred = sessions.filter { preferredFolder.matches($0.summary) }
    let others = sessions.filter { !preferredFolder.matches($0.summary) }
    return preferred + others
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
  /// read it. No folder passes, because the import then uses the folder of the source
  /// session.
  ///
  /// - Parameter folder: The folder of the new session, or `nil`.
  /// - Throws: `SessionImportError.folderUnavailable(_:)` for a folder that does not exist or
  ///   that the host cannot read.
  private static func requireFolder(_ folder: URL?) throws {
    guard let folder else { return }
    guard PathKind.of(folder) == .directory,
      FileManager.default.isReadableFile(atPath: folder.path)
    else {
      throw SessionImportError.folderUnavailable(folder)
    }
  }

  /// The folder of the new session of an order: the folder of the order, else the folder of
  /// the source session. The folder must exist, and the host must be able to read it.
  ///
  /// - Parameters:
  ///   - order: The order.
  ///   - source: The source session.
  /// - Returns: The folder.
  /// - Throws: ``AgentSessionImportError/noFolder(_:)`` when the order and the source give no
  ///   folder, and `SessionImportError.folderUnavailable(_:)` for a folder that does not exist
  ///   or that the host cannot read.
  private static func folder(of order: SessionImportOrder, source: LocatedExternalSession)
    throws -> URL
  {
    guard let folder = order.folder ?? source.summary.cwd else {
      throw AgentSessionImportError.noFolder(source.summary.sourceID)
    }
    try requireFolder(folder)
    return folder
  }
}

/// A source session by its agent and its id: the key of the earlier imports.
struct ImportSourceKey: Hashable, Sendable {
  /// The source agent, for example `claude-code`.
  ///
  /// The synthesized `Hashable` conformance reads it; periphery sees no reader.
  // periphery:ignore
  let agent: String

  /// The id of the session in the store of the source agent.
  ///
  /// The synthesized `Hashable` conformance reads it; periphery sees no reader.
  // periphery:ignore
  let sourceID: String
}
