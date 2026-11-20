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
/// The host gives the roots of the source agents that it can read (`~/.claude`, `~/.codex`).
/// The host can replace the roots while the agent runs (``replaceRoots(_:)``): a sandboxed app
/// gets the access to a root after the launch. The importer reads the roots only in a call: it runs no child process (D128), watches
/// nothing, and changes no file of a root. It keeps the metadata of each session file in
/// memory, by path, size and modification date, so a second call reads only the changed files.
///
/// The list of the earlier imports of a source comes from ``SessionSummary/importedFrom`` of the
/// sessions of the directory. It is only information: an import of the source makes a new
/// session also when the source has earlier imports (Q85).
actor AgentSessionImporter: SessionImporter {
  /// The root of each source agent that the host can read. ``replaceRoots(_:)`` changes it.
  private var roots: [ImportSourceAgent: URL]

  /// The session directory, for the earlier imports and for the new sessions.
  private let directory: any SessionDirectory

  /// The store of the history of each new session.
  private let historyStore: any ImportedHistoryStore

  /// The last read of each session file of each agent, by the path of the file.
  private var scans: [ImportSourceAgent: [String: ImportFileScan]] = [:]

  /// Makes the importer.
  ///
  /// - Parameters:
  ///   - roots: The root of each source agent that the host can read. A source with no root is
  ///     in the `unreadableSources` of each page.
  ///   - directory: The session directory.
  init(
    roots: [ImportSourceAgent: URL], directory: any SessionDirectory,
    historyStore: any ImportedHistoryStore
  ) {
    self.roots = roots
    self.directory = directory
    self.historyStore = historyStore
  }

  /// Replaces all the roots. The next call of ``importable(_:)`` or ``importSession(_:)``
  /// reads the new roots. The importer forgets the kept file metadata of each source agent
  /// whose root changed or is gone, so a later call reads each file of that agent again. A
  /// source agent whose root is the same keeps its file metadata.
  ///
  /// - Parameter newRoots: The root of each source agent that the host can read now. A source
  ///   with no root is in the `unreadableSources` of each page.
  func replaceRoots(_ newRoots: [ImportSourceAgent: URL]) {
    scans = scans.filter { agent, _ in newRoots[agent] == roots[agent] }
    roots = newRoots
  }

  /// The sessions of the readable source agents, the newest first, with the sessions of the
  /// preferred folder first.
  ///
  /// - Parameter request: The agent, the folder, the preferred folder and the page.
  /// - Returns: One page of the list, and each requested agent with no root.
  /// - Throws: ``AgentSessionImportError`` for an unknown agent and for a cursor that is not
  ///   a cursor of the importer, and the error of the directory.
  func importable(_ request: ImportableSessionsRequest) async throws -> ImportableSessionsPage {
    let agents = try request.agent.map { [try Self.agent(named: $0)] } ?? ImportSourceAgent.allCases
    let earlierImports = try await previousImports()
    let folderPath = request.folder?.canonicalPath
    let rows = agents.flatMap(sessions(of:))
      .filter { folderPath == nil || $0.cwd?.canonicalPath == folderPath }
    let page = try Self.page(
      of: Self.ordered(rows, preferring: request.preferredFolder), limit: request.limit,
      cursor: request.cursor)
    return ImportableSessionsPage(
      sessions: page.rows.map { Self.row(of: $0, earlierImports: earlierImports) },
      nextCursor: page.nextCursor,
      unreadableSources: agents.filter { roots[$0] == nil }.map(\.rawValue))
  }

  /// Imports a source session into a new session of the agent (D209, Q83, Q84, Q85).
  ///
  /// The importer reads the source file, makes the model transcript of its updates
  /// (``ImportedTranscript``), and gives it to the session directory, which writes the
  /// recording of a new root session with the origin `import` and the provenance of the
  /// source. The history store then writes the updates as the retained history of the new
  /// session (``ImportedHistoryStore``). When that write fails, the importer removes the folder
  /// of the new session and gives the error.
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
    guard roots[agent] != nil else {
      throw SessionImportError.sourceUnreadable(agent: order.agent)
    }
    try Self.requireFolder(order.folder)
    let source = try located(order.source, of: agent)
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

  /// The session file of a source of an agent: the session whose id is `source`, or whose
  /// file has the path `source`.
  ///
  /// - Parameters:
  ///   - source: The id or the file path of the source session.
  ///   - agent: The agent.
  /// - Returns: The session and its file.
  /// - Throws: ``AgentSessionImportError/unknownSource(_:)`` when the root of the agent holds
  ///   no such session.
  private func located(_ source: String, of agent: ImportSourceAgent) throws
    -> LocatedSessionMetadata
  {
    let path = URL(fileURLWithPath: source).standardizedFileURL.path
    guard
      let session = sessions(of: agent).first(where: { session in
        Self.sourceID(of: session) == source || session.file.standardizedFileURL.path == path
      })
    else {
      throw AgentSessionImportError.unknownSource(source)
    }
    return session
  }

  /// The import request of an order for the session directory.
  ///
  /// - Parameters:
  ///   - order: The order.
  ///   - source: The source session and its file.
  ///   - imported: The session that the reader read.
  ///   - folder: The folder of the new session.
  /// - Returns: The request: the folder, the name (Q84) and the provenance of the source.
  private static func request(
    for order: SessionImportOrder, source: LocatedSessionMetadata, imported: ImportedSession,
    folder: URL
  ) -> SessionImportRequest {
    let agent = source.metadata.agent.rawValue
    let title =
      [order.name, imported.metadata.title].compactMap { $0 }.first { !$0.isEmpty }
      ?? "\(agent)-import"
    return SessionImportRequest(
      workingDirectory: folder, title: title,
      provenance: SessionImportProvenance(
        agent: agent, sourceID: sourceID(of: source), sourcePath: source.file.path,
        sourceLastDate: imported.metadata.lastDate, importedAt: Date(),
        skippedRecordCount: imported.skippedRecordCount))
  }

  // MARK: - The scan

  /// The metadata of each session file of an agent: the kept metadata of each file whose
  /// stamp did not change, and a new read of each other file. The importer then keeps the
  /// scans of the files that it found, and forgets the scans of the files that are gone.
  ///
  /// - Parameter agent: The agent.
  /// - Returns: The metadata of each session, with its file. Nothing for an agent with no
  ///   root.
  private func sessions(of agent: ImportSourceAgent) -> [LocatedSessionMetadata] {
    guard let root = roots[agent] else { return [] }
    let kept = scans[agent] ?? [:]
    let found = Self.sessionFiles(of: agent, under: root).compactMap { file in
      Self.stamp(of: file).map { stamp in
        (file: file, scan: Self.scan(file, of: agent, stamp: stamp, kept: kept[file.path]))
      }
    }
    scans[agent] = Dictionary(found.map { ($0.file.path, $0.scan) }) { first, _ in first }
    return found.compactMap { entry in
      entry.scan.metadata.map { LocatedSessionMetadata(file: entry.file, metadata: $0) }
    }
  }

  /// The scan of one session file: the kept scan when the stamp of the file did not change,
  /// else a new read.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - agent: The agent of the file.
  ///   - stamp: The stamp of the file now.
  ///   - kept: The scan of the last call, or `nil` when the file is new.
  /// - Returns: The scan.
  private static func scan(
    _ file: URL, of agent: ImportSourceAgent, stamp: ImportFileStamp, kept: ImportFileScan?
  ) -> ImportFileScan {
    guard let kept, kept.stamp == stamp else {
      return read(file, of: agent, stamp: stamp)
    }
    return kept
  }

  /// Each session file of an agent under its root. A folder of the layout that does not exist
  /// gives no file.
  ///
  /// - Parameters:
  ///   - agent: The agent.
  ///   - root: The root of the agent.
  /// - Returns: The session files.
  private static func sessionFiles(of agent: ImportSourceAgent, under root: URL) -> [URL] {
    let layout = agent.layout
    return layout.folders.flatMap { name in
      let folder = root.appendingPathComponent(name, isDirectory: true)
      let depthOfFolder = folder.standardizedFileURL.pathComponents.count
      return files(under: folder).filter {
        layout.holds($0, atDepth: $0.standardizedFileURL.pathComponents.count - depthOfFolder)
      }
    }
  }

  /// Each regular file under a folder, at each depth, with no hidden file.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The files, or no file when the folder does not exist.
  private static func files(under folder: URL) -> [URL] {
    guard PathKind.of(folder) == .directory else { return [] }
    let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: ImportFileStamp.resourceKeys + [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) { url, error in
      logSkippedFile(
        url, "The importer cannot read a file of an import root. It skips the file.",
        error: error)
      return true
    }
    return (enumerator?.allObjects ?? []).compactMap { $0 as? URL }.filter(isRegularFile)
  }

  /// The stamp of a session file. A file with no stamp gives a warning.
  ///
  /// - Parameter file: The file.
  /// - Returns: The stamp, or `nil` when the file system gives no size or no date.
  static func stamp(of file: URL) -> ImportFileStamp? {
    guard let stamp = ImportFileStamp.makeStamp(of: file) else {
      logSkippedFile(
        file,
        "The importer cannot read the size or the date of a file of an import root. It skips the file.")
      return nil
    }
    return stamp
  }

  /// True when a file is a regular file. A file whose kind the importer cannot read gives a
  /// warning, and is not a regular file.
  ///
  /// - Parameter file: The file.
  /// - Returns: True for a regular file.
  static func isRegularFile(_ file: URL) -> Bool {
    do {
      return try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    } catch {
      logSkippedFile(
        file, "The importer cannot read the kind of a file of an import root. It skips the file.",
        error: error)
      return false
    }
  }

  /// Logs a warning for a file of an import root that the scan skips.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - message: The message of the warning.
  ///   - error: The error of the read, or `nil` when the read gave no error.
  private static func logSkippedFile(
    _ file: URL, _ message: Logger.Message, error: (any Error)? = nil
  ) {
    var metadata: Logger.Metadata = ["path": .string(file.path)]
    metadata["error"] = error.map { .string("\($0)") }
    ACPAgentTelemetry.logger(.session).warning(message, metadata: metadata)
  }

  /// Reads the metadata of one session file. A file that the reader refuses, or that the
  /// importer cannot read, gives a scan with no metadata: the list does not show it.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - agent: The agent of the file.
  ///   - stamp: The stamp of the file.
  /// - Returns: The scan.
  private static func read(_ file: URL, of agent: ImportSourceAgent, stamp: ImportFileStamp)
    -> ImportFileScan
  {
    do {
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      return ImportFileScan(stamp: stamp, metadata: try agent.metadata(of: data, in: file))
    } catch let error as ImportReadError {
      ACPAgentTelemetry.logger(.session).debug(
        "A file of an import root is not a session that the importer can list.",
        metadata: ["path": "\(file.path)", "error": "\(error)"])
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The importer cannot read a session file of an import root. The list does not show it.",
        metadata: ["path": "\(file.path)", "error": "\(error)"])
    }
    return ImportFileScan(stamp: stamp, metadata: nil)
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

  /// The row of one session.
  ///
  /// - Parameters:
  ///   - session: The session and its file.
  ///   - earlierImports: The earlier imports of each source session.
  /// - Returns: The row.
  private static func row(
    of session: LocatedSessionMetadata,
    earlierImports: [ImportSourceKey: [SessionPreviousImport]]
  ) -> ImportableSession {
    let metadata = session.metadata
    let sourceID = sourceID(of: session)
    return ImportableSession(
      agent: metadata.agent.rawValue, sourceID: sourceID, sourcePath: session.file.path,
      title: metadata.title, folder: metadata.cwd, lastDate: metadata.lastDate,
      turnCount: metadata.turnCount,
      previousImports: earlierImports[
        ImportSourceKey(agent: metadata.agent.rawValue, sourceID: sourceID)] ?? [])
  }

  /// The id of a source session: the id that its file gives, else the name of its file with
  /// no extension.
  ///
  /// - Parameter session: The session and its file.
  /// - Returns: The id.
  private static func sourceID(of session: LocatedSessionMetadata) -> String {
    let metadata = session.metadata
    return metadata.sourceID.isEmpty
      ? session.file.deletingPathExtension().lastPathComponent : metadata.sourceID
  }

  /// The sessions in the order of the list: the sessions of the preferred folder first, then
  /// the newest first. A session with no date comes after each session with a date. The path
  /// of the file decides between two sessions of the same date.
  ///
  /// - Parameters:
  ///   - sessions: The sessions.
  ///   - preferredFolder: The folder whose sessions come first, or `nil`.
  /// - Returns: The ordered sessions.
  private static func ordered(
    _ sessions: [LocatedSessionMetadata], preferring preferredFolder: URL?
  ) -> [LocatedSessionMetadata] {
    let preferredPath = preferredFolder?.canonicalPath
    return sessions.map { session in
      (session: session, isPreferred: preferredPath != nil && session.cwd?.canonicalPath == preferredPath)
    }
    .sorted { first, second in
        if first.isPreferred != second.isPreferred { return first.isPreferred }
        return isNewer(first.session, than: second.session)
      }
    .map(\.session)
  }

  /// True when the first session comes before the second session in the order of the dates.
  ///
  /// - Parameters:
  ///   - first: The first session.
  ///   - second: The second session.
  /// - Returns: True when `first` is newer, or has a date when `second` has none, or has the
  ///   same date and the path that comes first.
  private static func isNewer(
    _ first: LocatedSessionMetadata, than second: LocatedSessionMetadata
  ) -> Bool {
    switch (first.metadata.lastDate, second.metadata.lastDate) {
    case (let firstDate?, let secondDate?) where firstDate != secondDate:
      firstDate > secondDate
    case (.some, .none):
      true
    case (.none, .some):
      false
    default:
      first.file.path < second.file.path
    }
  }

  /// One page of the ordered sessions. The cursor of a page is the place of its first session
  /// in the list.
  ///
  /// - Parameters:
  ///   - sessions: The ordered sessions.
  ///   - limit: The most sessions of the page. A page has at least one session when sessions
  ///     follow the cursor.
  ///   - cursor: The cursor of the page, or `nil` for the first page.
  /// - Returns: The sessions of the page, and the cursor of the next page, or `nil` when no
  ///   session follows.
  /// - Throws: ``AgentSessionImportError/invalidCursor(_:)`` for a cursor that is not a place
  ///   in the list.
  private static func page(
    of sessions: [LocatedSessionMetadata], limit: Int, cursor: String?
  ) throws -> (rows: [LocatedSessionMetadata], nextCursor: String?) {
    let start = try cursor.map { cursor in
      guard let place = Int(cursor), sessions.indices.contains(place) || place == sessions.count
      else {
        throw AgentSessionImportError.invalidCursor(cursor)
      }
      return place
    } ?? 0
    let end = start + min(max(limit, 1), sessions.count - start)
    return (Array(sessions[start..<end]), end < sessions.count ? String(end) : nil)
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
  private static func folder(of order: SessionImportOrder, source: LocatedSessionMetadata)
    throws -> URL
  {
    guard let folder = order.folder ?? source.cwd else {
      throw AgentSessionImportError.noFolder(sourceID(of: source))
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
