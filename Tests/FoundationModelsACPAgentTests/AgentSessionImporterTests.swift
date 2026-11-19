import ACPImport
import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The scan of the import roots of the host (D209 (d), (e)): ``AgentSessionImporter`` lists the
/// Claude Code and Codex sessions of fixture roots in a temporary folder, the newest first and
/// the sessions of the preferred folder first, and keeps the metadata of each file in memory.
@Suite struct AgentSessionImporterTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "AgentSessionImporterTests"

  /// The source id of the Claude Code session: the name of its file with no extension.
  private static let claudeID = "5a1e0000-0000-4000-8000-000000000001"

  /// The source id of the Codex session: the id of its `session_meta` record.
  private static let codexID = "0199aaaa-0000-7000-8000-00000000c0de"

  /// The source id of the archived Codex session.
  private static let archivedCodexID = "0199bbbb-0000-7000-8000-00000000c0de"

  /// The working folder of the Claude Code session.
  private static let claudeFolder = URL(fileURLWithPath: "/work/app", isDirectory: true)

  /// The working folder of the Codex sessions.
  private static let codexFolder = URL(fileURLWithPath: "/work/cli", isDirectory: true)

  /// The first title of the Claude Code session.
  private static let firstTitle = "Title A"

  /// A second title of the same length as ``firstTitle``.
  private static let sameLengthTitle = "Title B"

  /// A second title of a different length.
  private static let longerTitle = "A longer title"

  /// The most sessions of a page that holds each fixture session.
  private static let wideLimit = 50

  /// The modification date of a file whose bytes change with no change of size or date.
  private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: - Fixtures

  /// The lines of a Claude Code session file with a custom title.
  ///
  /// - Parameter title: The custom title.
  /// - Returns: The bytes of the file.
  private static func claudeFile(title: String) -> Data {
    Data(
      """
      {"type":"user","uuid":"u-1","sessionId":"\(claudeID)","timestamp":"2026-11-01T10:00:01.000Z","cwd":"\(claudeFolder.path)","message":{"role":"user","content":"Fix the test."}}
      {"type":"custom-title","customTitle":"\(title)","sessionId":"\(claudeID)"}

      """.utf8)
  }

  /// The lines of a Codex session file.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - day: The day of the records, `2026-11-<day>`.
  /// - Returns: The bytes of the file.
  private static func codexFile(id: String, day: String) -> Data {
    Data(
      """
      {"timestamp":"2026-11-\(day)T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"2026-11-\(day)T09:00:00.000Z","cwd":"\(codexFolder.path)"}}
      {"timestamp":"2026-11-\(day)T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"List the files."}]}}

      """.utf8)
  }

  /// The roots of one test: a Claude Code root and a Codex root in a new temporary folder.
  private struct Roots {
    /// The Claude Code root (`~/.claude`).
    let claude: URL

    /// The Codex root (`~/.codex`).
    let codex: URL

    /// The file of the Claude Code session.
    var claudeSession: URL {
      claude.appendingPathComponent("projects/-work-app/\(claudeID).jsonl")
    }

    /// Both roots by their agent.
    var all: [ImportSourceAgent: URL] { [.claudeCode: claude, .codex: codex] }

    /// Makes the roots with one Claude Code session (2026-11-01) and one Codex session
    /// (2026-11-02).
    ///
    /// - Returns: The roots.
    /// - Throws: The error of a write.
    static func make() throws -> Roots {
      let base = makeResolvedDirectory(label: label)
      let roots = Roots(
        claude: base.appendingPathComponent(".claude", isDirectory: true),
        codex: base.appendingPathComponent(".codex", isDirectory: true))
      try write(claudeFile(title: firstTitle), to: roots.claudeSession)
      try write(
        codexFile(id: codexID, day: "02"),
        to: roots.codex.appendingPathComponent(
          "sessions/2026/11/02/rollout-2026-11-02T09-00-00-\(codexID).jsonl"))
      return roots
    }

    /// Adds an archived Codex session (2026-11-03).
    ///
    /// - Throws: The error of the write.
    func addArchivedCodexSession() throws {
      try Self.write(
        codexFile(id: archivedCodexID, day: "03"),
        to: codex.appendingPathComponent(
          "archived_sessions/rollout-2026-11-03T09-00-00-\(archivedCodexID).jsonl"))
    }

    /// Writes a file and makes its folder.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - file: The file.
    /// - Throws: The error of the write.
    static func write(_ data: Data, to file: URL) throws {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file)
    }
  }

  /// A request for each agent and each folder.
  ///
  /// - Parameters:
  ///   - preferredFolder: The folder whose sessions come first, or `nil`.
  ///   - agent: The source agent, or `nil` for each agent.
  ///   - folder: The folder of the sessions, or `nil` for each folder.
  ///   - limit: The most sessions of the page.
  ///   - cursor: The cursor of the page, or `nil`.
  /// - Returns: The request.
  private static func request(
    preferredFolder: URL? = nil, agent: String? = nil, folder: URL? = nil,
    limit: Int = wideLimit, cursor: String? = nil
  ) -> ImportableSessionsRequest {
    ImportableSessionsRequest(
      agent: agent, folder: folder, preferredFolder: preferredFolder, limit: limit, cursor: cursor)
  }

  /// An importer over roots, with an empty directory.
  ///
  /// - Parameters:
  ///   - roots: The import roots.
  ///   - directory: The session directory. A new empty directory by default.
  /// - Returns: The importer.
  private static func importer(
    _ roots: [ImportSourceAgent: URL],
    directory: any SessionDirectory = InMemorySessionDirectory()
  ) -> AgentSessionImporter {
    AgentSessionImporter(roots: roots, directory: directory)
  }

  /// The source ids of the first page of an importer.
  ///
  /// - Parameters:
  ///   - importer: The importer.
  ///   - request: The request.
  /// - Returns: The source ids, in the order of the page.
  /// - Throws: The error of the importer.
  private static func sourceIDs(
    of importer: AgentSessionImporter, _ request: ImportableSessionsRequest = request()
  ) async throws -> [String] {
    try await importer.importable(request).sessions.map(\.sourceID)
  }

  /// The title of the Claude Code session in the first page of an importer.
  ///
  /// - Parameter importer: The importer.
  /// - Returns: The title.
  /// - Throws: The error of the importer, or a failed requirement when the page has no Claude
  ///   Code session.
  private static func claudeTitle(of importer: AgentSessionImporter) async throws -> String? {
    let page = try await importer.importable(request())
    return try #require(page.sessions.first { $0.sourceID == claudeID }).title
  }

  /// Writes the bytes of a file and sets its modification date. The date is a whole second, so
  /// the file system keeps it with no loss.
  ///
  /// - Parameters:
  ///   - data: The bytes.
  ///   - file: The file.
  ///   - date: The modification date.
  /// - Throws: The error of the write.
  private static func write(_ data: Data, to file: URL, modified date: Date) throws {
    try data.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
  }

  /// The bytes and the modification date of each file under a folder, by path.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The state of each file.
  /// - Throws: The error of a read.
  private static func fileStates(under folder: URL) throws -> [String: FileState] {
    let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter {
      $0.hasSuffix(".jsonl")
    }
    return try Dictionary(
      uniqueKeysWithValues: files.map { path in
        let file = folder.appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (
          path,
          FileState(
            data: try Data(contentsOf: file), modified: attributes[.modificationDate] as? Date)
        )
      })
  }

  /// The bytes and the modification date of one file.
  private struct FileState: Equatable {
    /// The bytes.
    let data: Data

    /// The modification date.
    let modified: Date?
  }

  /// Imports the Claude Code session into a directory, as an earlier import did.
  ///
  /// - Parameters:
  ///   - directory: The directory.
  ///   - date: The date of the import.
  /// - Returns: The earlier import that the importer must list.
  /// - Throws: The error of the directory.
  private static func recordImport(in directory: InMemorySessionDirectory, at date: Date)
    async throws -> SessionPreviousImport
  {
    let summary = try await directory.importSession(
      SessionImportRequest(
        workingDirectory: claudeFolder, title: firstTitle,
        provenance: SessionImportProvenance(
          agent: ImportSourceAgent.claudeCode.rawValue, sourceID: claudeID, sourcePath: "",
          importedAt: date)),
      transcript: Transcript())
    return SessionPreviousImport(session: summary.id, importedAt: date)
  }

  // MARK: - The order of the list

  @Test("importable lists the sessions of both agents, the newest first")
  func theListIsTheNewestFirst() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(of: Self.importer(roots.all))

    #expect(ids == [Self.codexID, Self.claudeID])
  }

  @Test("the sessions of the preferred folder come first")
  func thePreferredFolderComesFirst() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: Self.importer(roots.all), Self.request(preferredFolder: Self.claudeFolder))

    #expect(ids == [Self.claudeID, Self.codexID])
  }

  @Test("importable lists the archived sessions of Codex")
  func theArchivedCodexSessionsAreListed() async throws {
    let roots = try Roots.make()
    try roots.addArchivedCodexSession()

    let ids = try await Self.sourceIDs(of: Self.importer(roots.all))

    #expect(ids == [Self.archivedCodexID, Self.codexID, Self.claudeID])
  }

  // MARK: - The filters and the pages

  @Test("an agent filter lists only the sessions of that agent")
  func theAgentFilterListsOneAgent() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: Self.importer(roots.all), Self.request(agent: ImportSourceAgent.claudeCode.rawValue))

    #expect(ids == [Self.claudeID])
  }

  @Test("a folder filter lists only the sessions of that folder")
  func theFolderFilterListsOneFolder() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: Self.importer(roots.all), Self.request(folder: Self.codexFolder))

    #expect(ids == [Self.codexID])
  }

  @Test("an unknown agent gives the error of the unknown agent")
  func anUnknownAgentThrows() async throws {
    let roots = try Roots.make()

    await #expect(throws: AgentSessionImportError.unknownAgent("gemini")) {
      try await Self.importer(roots.all).importable(Self.request(agent: "gemini"))
    }
  }

  @Test("the cursor of the first page gives the next sessions")
  func theCursorGivesTheNextPage() async throws {
    let roots = try Roots.make()
    let importer = Self.importer(roots.all)
    let first = try await importer.importable(Self.request(limit: 1))

    let second = try await Self.sourceIDs(
      of: importer, Self.request(limit: 1, cursor: first.nextCursor))

    #expect(first.sessions.map(\.sourceID) + second == [Self.codexID, Self.claudeID])
  }

  @Test("the last page gives no cursor")
  func theLastPageGivesNoCursor() async throws {
    let roots = try Roots.make()

    let page = try await Self.importer(roots.all).importable(Self.request())

    #expect(page.nextCursor == nil)
  }

  // MARK: - The roots

  @Test("a source with no root is in unreadableSources")
  func aSourceWithNoRootIsUnreadable() async throws {
    let roots = try Roots.make()

    let page = try await Self.importer([.claudeCode: roots.claude]).importable(Self.request())

    #expect(page.unreadableSources == [ImportSourceAgent.codex.rawValue])
  }

  @Test("the import roots stay unchanged, bytes and dates")
  func theRootsStayUnchanged() async throws {
    let roots = try Roots.make()
    try roots.addArchivedCodexSession()
    let base = roots.claude.deletingLastPathComponent()
    let before = try Self.fileStates(under: base)

    _ = try await Self.importer(roots.all).importable(Self.request())

    #expect(try Self.fileStates(under: base) == before)
  }

  // MARK: - The metadata cache

  @Test("a changed file is read again")
  func aChangedFileIsReadAgain() async throws {
    let roots = try Roots.make()
    let importer = Self.importer(roots.all)
    _ = try await importer.importable(Self.request())
    try Self.claudeFile(title: Self.longerTitle).write(to: roots.claudeSession)

    let title = try await Self.claudeTitle(of: importer)

    #expect(title == Self.longerTitle)
  }

  @Test("an unchanged file is not read again")
  func anUnchangedFileIsNotReadAgain() async throws {
    let roots = try Roots.make()
    try Self.write(
      Self.claudeFile(title: Self.firstTitle), to: roots.claudeSession, modified: Self.fixedDate)
    let importer = Self.importer(roots.all)
    _ = try await importer.importable(Self.request())
    // The same size and the same date: the importer keeps the metadata of the first read.
    try Self.write(
      Self.claudeFile(title: Self.sameLengthTitle), to: roots.claudeSession,
      modified: Self.fixedDate)

    let title = try await Self.claudeTitle(of: importer)

    #expect(title == Self.firstTitle)
  }

  // MARK: - The earlier imports

  @Test("previousImports lists the earlier copies of a source")
  func previousImportsListsTheEarlierCopies() async throws {
    let roots = try Roots.make()
    let directory = InMemorySessionDirectory(
      launcher: InMemorySessionDirectory.Launcher(
        agentIDs: ["default"], defaultWorkingDirectory: Self.claudeFolder))
    let earlier = try await Self.recordImport(in: directory, at: Date(timeIntervalSince1970: 1))
    let later = try await Self.recordImport(in: directory, at: Date(timeIntervalSince1970: 2))

    let page = try await Self.importer(roots.all, directory: directory).importable(Self.request())

    #expect(page.sessions.first { $0.sourceID == Self.claudeID }?.previousImports == [earlier, later])
  }

  // MARK: - The checks of an import

  @Test("an import from a source with no root gives sourceUnreadable")
  func anImportWithNoRootIsUnreadable() async throws {
    let roots = try Roots.make()
    let order = SessionImportOrder(
      agent: ImportSourceAgent.codex.rawValue, source: Self.codexID, folder: nil, name: nil)

    await #expect(throws: SessionImportError.sourceUnreadable(agent: ImportSourceAgent.codex.rawValue)) {
      try await Self.importer([.claudeCode: roots.claude]).importSession(order)
    }
  }

  @Test("an import into a folder that does not exist gives folderUnavailable")
  func anImportIntoAMissingFolderIsUnavailable() async throws {
    let roots = try Roots.make()
    let missing = roots.claude.deletingLastPathComponent().appendingPathComponent(
      "missing", isDirectory: true)
    let order = SessionImportOrder(
      agent: ImportSourceAgent.claudeCode.rawValue, source: Self.claudeID, folder: missing,
      name: nil)

    await #expect(throws: SessionImportError.folderUnavailable(missing)) {
      try await Self.importer(roots.all).importSession(order)
    }
  }
}
