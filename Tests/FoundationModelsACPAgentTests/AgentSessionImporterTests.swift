import ACPImport
import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Logging
import Synchronization
import TelemetryTestSupport
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The list and the import of the sessions of other agents (D209 (d), (e)):
/// ``AgentSessionImporter`` lists the typed Claude Code and Codex sessions that the index of
/// external sessions (``ExternalSessionIndex``, D212) read from fixture roots in a temporary
/// folder, the newest first and the sessions of the preferred folder first.
///
/// The list never waits for the index, thus each test of the list waits until the index is
/// idle before it lists. The index of these tests has no watch, so a change of a file reaches
/// the index through a find that a list starts, at most one time in 30 s of the manual clock.
@Suite(.removesTemporaryFolders) struct AgentSessionImporterTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "AgentSessionImporterTests"

  /// The source id of the Claude Code session: the name of its file with no extension.
  private static let claudeID = "5a1e0000-0000-4000-8000-000000000001"

  /// The source id of the Codex session: the id of its `session_meta` record.
  private static let codexID = "0199aaaa-0000-7000-8000-00000000c0de"

  /// The source id of the automated Claude Code session.
  private static let automatedID = "5a1e0000-0000-4000-8000-0000000000a7"

  /// The `entrypoint` of a session that a program started.
  private static let automatedEntrypoint = "sdk-cli"

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

  /// The date of the earlier of two imports of a source.
  private static let earlierImportDate = Date(timeIntervalSince1970: 1)

  /// The date of the later of two imports of a source, after ``earlierImportDate``.
  private static let laterImportDate = earlierImportDate.addingTimeInterval(1)

  /// The modification date of a file whose bytes change with no change of size or date: the
  /// start of 1970, a whole second, which the file system keeps with no loss.
  private static let fixedDate = Date(timeIntervalSince1970: 0)

  // MARK: - Fixtures

  /// The bytes of the Claude Code session file with a custom title.
  ///
  /// - Parameter title: The custom title.
  /// - Returns: The bytes of the file.
  private static func claudeFile(title: String) -> Data {
    ImportSessionFiles.claudeCode(id: claudeID, folder: claudeFolder, title: title)
  }

  /// The roots of one test: a Claude Code root and a Codex root in a new temporary folder.
  private struct Roots {
    /// The Claude Code root (`~/.claude`).
    let claude: URL

    /// The Codex root (`~/.codex`).
    let codex: URL

    /// The file of the Claude Code session.
    var claudeSession: URL {
      ImportSessionFiles.claudeCodeFile(of: claudeID, folder: claudeFolder, in: claude)
    }

    /// Both roots by their agent.
    var all: [ImportSourceAgent: URL] { [.claudeCode: claude, .codex: codex] }

    /// Makes the roots with one Claude Code session (2026-11-01) and one Codex session
    /// (2026-11-02).
    ///
    /// - Returns: The roots.
    /// - Throws: The error of a write.
    static func make() throws -> Roots {
      let base = TemporaryFolders.make(label: label)
      let roots = Roots(
        claude: base.appendingPathComponent(".claude", isDirectory: true),
        codex: base.appendingPathComponent(".codex", isDirectory: true))
      try ImportSessionFiles.writeClaudeCode(
        id: claudeID, folder: claudeFolder, title: firstTitle, in: roots.claude)
      try ImportSessionFiles.writeCodex(
        id: codexID, day: "02", folder: codexFolder, in: roots.codex)
      return roots
    }

    /// Adds an archived Codex session (2026-11-03).
    ///
    /// - Throws: The error of the write.
    func addArchivedCodexSession() throws {
      try ImportSessionFiles.writeCodex(
        id: archivedCodexID, day: "03", folder: codexFolder, isArchived: true, in: codex)
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

  /// An importer over roots, with an empty directory, after the index read the roots.
  ///
  /// - Parameters:
  ///   - roots: The import roots.
  ///   - directory: The session directory. A new empty directory by default.
  ///   - clock: The clock of the index. A new manual clock by default.
  /// - Returns: The importer.
  private static func importer(
    _ roots: [ImportSourceAgent: URL],
    directory: any SessionDirectory = InMemorySessionDirectory(),
    clock: ManualExternalSessionClock = ManualExternalSessionClock()
  ) async -> AgentSessionImporter {
    let importer = AgentSessionImporter(
      index: ExternalSessionIndex(
        fileSystem: UnwatchedLocalFileSystem(), indexFolder: nil, clock: clock),
      directory: directory, historyStore: RecordingHistoryStore())
    await importer.replaceRoots(roots)
    await importer.index.waitUntilIdle()
    return importer
  }

  /// Lists one time, so the index starts a find of each root after 30 s of the clock, and
  /// waits until the index read the changes.
  ///
  /// - Parameters:
  ///   - importer: The importer.
  ///   - clock: The clock of its index.
  /// - Throws: The error of the importer.
  private static func listAfterTheFindInterval(
    _ importer: AgentSessionImporter, clock: ManualExternalSessionClock
  ) async throws {
    clock.advance(by: ExternalSessionIndex.findInterval)
    _ = try await importer.importable(request())
    await importer.index.waitUntilIdle()
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

    let ids = try await Self.sourceIDs(of: await Self.importer(roots.all))

    #expect(ids == [Self.codexID, Self.claudeID])
  }

  /// iCloud Drive sets the macOS hidden flag on each item under a dot folder,
  /// such as `.claude` and `.codex`. The scan skips dotfiles by name, so it
  /// still finds each session.
  @Test("importable lists the sessions whose files have the macOS hidden flag")
  func filesWithTheHiddenFlagAreListed() async throws {
    let roots = try Roots.make()
    for root in [roots.claude, roots.codex] {
      try Self.setHiddenFlag(onEachItemUnder: root)
    }

    let ids = try await Self.sourceIDs(of: await Self.importer(roots.all))

    #expect(ids == [Self.codexID, Self.claudeID])
  }

  /// Sets the macOS hidden flag on each item under `root`, at each depth.
  ///
  /// - Parameter root: An import root.
  /// - Throws: The error of a write of the flag.
  private static func setHiddenFlag(onEachItemUnder root: URL) throws {
    var values = URLResourceValues()
    values.isHidden = true
    let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while var item = items?.nextObject() as? URL {
      try item.setResourceValues(values)
      #expect(try item.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
    }
  }

  @Test("the sessions of the preferred folder come first")
  func thePreferredFolderComesFirst() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: await Self.importer(roots.all), Self.request(preferredFolder: Self.claudeFolder))

    #expect(ids == [Self.claudeID, Self.codexID])
  }

  @Test("importable lists the archived sessions of Codex")
  func theArchivedCodexSessionsAreListed() async throws {
    let roots = try Roots.make()
    try roots.addArchivedCodexSession()

    let ids = try await Self.sourceIDs(of: await Self.importer(roots.all))

    #expect(ids == [Self.archivedCodexID, Self.codexID, Self.claudeID])
  }

  // MARK: - The filters and the pages

  @Test("importable lists no automated session")
  func theListHasNoAutomatedSession() async throws {
    let roots = try Roots.make()
    try ImportSessionFiles.writeClaudeCode(
      id: Self.automatedID, folder: Self.claudeFolder, entrypoint: Self.automatedEntrypoint,
      in: roots.claude)

    let ids = try await Self.sourceIDs(of: await Self.importer(roots.all))

    #expect(ids == [Self.codexID, Self.claudeID])
  }

  @Test("a row of importable has no count of the turns")
  func aRowHasNoCountOfTheTurns() async throws {
    let roots = try Roots.make()

    let page = try await Self.importer(roots.all).importable(Self.request())

    #expect(page.sessions.map(\.turnCount) == [0, 0])
  }

  @Test("an agent filter lists only the sessions of that agent")
  func theAgentFilterListsOneAgent() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: await Self.importer(roots.all), Self.request(agent: ImportSourceAgent.claudeCode.rawValue))

    #expect(ids == [Self.claudeID])
  }

  @Test("a folder filter lists only the sessions of that folder")
  func theFolderFilterListsOneFolder() async throws {
    let roots = try Roots.make()

    let ids = try await Self.sourceIDs(
      of: await Self.importer(roots.all), Self.request(folder: Self.codexFolder))

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
    let importer = await Self.importer(roots.all)
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
    let clock = ManualExternalSessionClock()
    let importer = await Self.importer(roots.all, clock: clock)
    try Self.claudeFile(title: Self.longerTitle).write(to: roots.claudeSession)
    try await Self.listAfterTheFindInterval(importer, clock: clock)

    let title = try await Self.claudeTitle(of: importer)

    #expect(title == Self.longerTitle)
  }

  @Test("an unchanged file is not read again")
  func anUnchangedFileIsNotReadAgain() async throws {
    let roots = try Roots.make()
    try Self.write(
      Self.claudeFile(title: Self.firstTitle), to: roots.claudeSession, modified: Self.fixedDate)
    let clock = ManualExternalSessionClock()
    let importer = await Self.importer(roots.all, clock: clock)
    // The same size and the same date: the index keeps the metadata of the first read.
    try Self.write(
      Self.claudeFile(title: Self.sameLengthTitle), to: roots.claudeSession,
      modified: Self.fixedDate)
    try await Self.listAfterTheFindInterval(importer, clock: clock)

    let title = try await Self.claudeTitle(of: importer)

    #expect(title == Self.firstTitle)
  }

  // MARK: - The change of the roots

  /// A change of the Claude Code root that removes the root of the first call.
  enum ClaudeRootChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The host gives a different Claude Code root.
    case moved

    /// The host gives no Claude Code root.
    case removed

    /// The name of the change in the test results.
    var testDescription: String { rawValue }

    /// The roots after the change.
    ///
    /// - Parameter codexRoot: The Codex root, which the change keeps.
    /// - Returns: The roots with the changed Claude Code root.
    func roots(keepingCodexRoot codexRoot: URL) -> [ImportSourceAgent: URL] {
      switch self {
      case .moved:
        [.claudeCode: TemporaryFolders.make(label: label), .codex: codexRoot]
      case .removed:
        [.codex: codexRoot]
      }
    }
  }

  /// Makes the roots with a Claude Code session file of ``firstTitle`` at ``fixedDate``, and
  /// an importer whose first call read them. The test then writes ``sameLengthTitle`` with
  /// the same size and the same date, so only a new read of the file gives the new title.
  ///
  /// - Returns: The roots and the importer.
  /// - Throws: The error of a write or of the importer.
  private static func scannedRootsWithAChangeTheStampHides() async throws
    -> (roots: Roots, importer: AgentSessionImporter)
  {
    let roots = try Roots.make()
    try write(claudeFile(title: firstTitle), to: roots.claudeSession, modified: fixedDate)
    let importer = await importer(roots.all)
    try write(claudeFile(title: sameLengthTitle), to: roots.claudeSession, modified: fixedDate)
    return (roots, importer)
  }

  @Test("a root that the host gives after the start is in the next page")
  func aRootGivenLaterIsInTheNextPage() async throws {
    let roots = try Roots.make()
    let importer = await Self.importer([:])

    await importer.replaceRoots([.claudeCode: roots.claude])
    await importer.index.waitUntilIdle()

    #expect(try await Self.sourceIDs(of: importer) == [Self.claudeID])
  }

  @Test("a root that the host takes away is in unreadableSources")
  func aRootTakenAwayIsUnreadable() async throws {
    let roots = try Roots.make()
    let importer = await Self.importer(roots.all)

    await importer.replaceRoots([.claudeCode: roots.claude])

    #expect(
      try await importer.importable(Self.request()).unreadableSources
        == [ImportSourceAgent.codex.rawValue])
  }

  @Test("an import from a root that the host takes away gives sourceUnreadable")
  func anImportFromARootTakenAwayIsUnreadable() async throws {
    let roots = try Roots.make()
    let importer = await Self.importer(roots.all)
    let order = SessionImportOrder(
      agent: ImportSourceAgent.codex.rawValue, source: Self.codexID, folder: nil, name: nil)

    await importer.replaceRoots([.claudeCode: roots.claude])

    await #expect(throws: SessionImportError.sourceUnreadable(agent: ImportSourceAgent.codex.rawValue)) {
      try await importer.importSession(order)
    }
  }

  @Test("a root that changes and comes back is read again", arguments: ClaudeRootChange.allCases)
  func aChangedRootIsReadAgain(_ change: ClaudeRootChange) async throws {
    let (roots, importer) = try await Self.scannedRootsWithAChangeTheStampHides()

    await importer.replaceRoots(change.roots(keepingCodexRoot: roots.codex))
    await importer.replaceRoots(roots.all)
    await importer.index.waitUntilIdle()

    #expect(try await Self.claudeTitle(of: importer) == Self.sameLengthTitle)
  }

  @Test("a root that the host gives again with no change keeps the metadata of its files")
  func anUnchangedRootKeepsItsMetadata() async throws {
    let (roots, importer) = try await Self.scannedRootsWithAChangeTheStampHides()

    await importer.replaceRoots(roots.all)
    await importer.index.waitUntilIdle()

    #expect(try await Self.claudeTitle(of: importer) == Self.firstTitle)
  }

  // MARK: - The skipped files

  /// A read of the index that skips an item it cannot read, and logs a warning with its path.
  enum SkippingRead: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The read of the size and the date of an item.
    case stamp

    /// The directory read of a folder of a root.
    case folder

    /// The name of the read in the test results.
    var testDescription: String { rawValue }

    /// Does the read on an item.
    ///
    /// - Parameter item: The item: a file that is gone for the stamp, and a root whose
    ///   `projects` folder is a file for the directory read.
    /// - Returns: The path that the warning must name.
    /// - Throws: The error of the write of the root.
    func run(on item: URL) throws -> String {
      switch self {
      case .stamp:
        _ = LocalExternalSessionFileSystem.item(of: item)
        return item.path
      case .folder:
        let projects = item.appendingPathComponent("projects", isDirectory: true)
        try ImportSessionFiles.write(Data(), to: projects)
        _ = ExternalSessionScan.find(
          .claudeCode, under: item, scope: .root, fileSystem: LocalExternalSessionFileSystem())
        return projects.path
      }
    }
  }

  @Test("an item that a read of the index cannot read gives a warning with its path",
    arguments: SkippingRead.allCases)
  func anItemThatAReadCannotReadGivesAWarning(_ read: SkippingRead) async throws {
    let item = TemporaryFolders.make(label: Self.label).appendingPathComponent("gone.jsonl")

    let (records, path) = try await TelemetryCapture.run(forbidding: []) { context in
      let path = try read.run(on: item)
      return (context.logRecords, path)
    }

    #expect(records.contains { $0.level == .warning && $0.metadata["path"] == .string(path) })
  }

  @Test("the trait of the suite removes the folders that a test made")
  func theTraitRemovesTheFolders() async throws {
    let made = Mutex<URL?>(nil)

    try await RemovesTemporaryFoldersTrait().provideScope(
      for: try #require(Test.current), testCase: nil
    ) {
      made.withLock { $0 = TemporaryFolders.make(label: Self.label) }
    }

    let folder = try #require(made.withLock { $0 })
    #expect(PathKind.of(folder) == .missing)
  }

  // MARK: - The earlier imports

  @Test("previousImports lists the earlier copies of a source")
  func previousImportsListsTheEarlierCopies() async throws {
    let roots = try Roots.make()
    let directory = InMemorySessionDirectory(
      launcher: InMemorySessionDirectory.Launcher(
        agentIDs: ["default"], defaultWorkingDirectory: Self.claudeFolder))
    let earlier = try await Self.recordImport(in: directory, at: Self.earlierImportDate)
    let later = try await Self.recordImport(in: directory, at: Self.laterImportDate)

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

  // MARK: - The write of an import

  @Test("an import makes a new session with the provenance of the source")
  func anImportHasTheProvenanceOfTheSource() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order())

    let provenance = try #require(try await fixture.directory.summary(of: result.session)?.importedFrom)
    #expect(
      provenance
        == SessionImportProvenance(
          agent: ImportSourceAgent.claudeCode.rawValue, sourceID: Self.claudeID,
          sourcePath: fixture.file.path, sourceTitle: ImportFixture.sourceTitle,
          sourceLastDate: try ImportFixture.lastRecordDate(), importedAt: provenance.importedAt))
  }

  @Test("an import from a source with no title has no source title in its provenance")
  func anImportFromASourceWithNoTitleHasNoSourceTitle() async throws {
    let fixture = try await ImportFixture.make(title: nil)

    let result = try await fixture.importer.importSession(fixture.order())

    let provenance = try #require(try await fixture.directory.summary(of: result.session)?.importedFrom)
    #expect(provenance.sourceTitle == nil)
  }

  @Test("an import with no folder works in the folder of the source session")
  func anImportWithNoFolderWorksInTheSourceFolder() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order())

    #expect(
      try await fixture.directory.summary(of: result.session)?.workingDirectory.canonicalPath
        == fixture.folder.canonicalPath)
  }

  @Test("the transcript of an import holds the prompt and the answer of the source")
  func theTranscriptHoldsThePromptAndTheAnswer() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order())

    let transcript = try #require(fixture.directory.importedTranscript(of: result.session))
    #expect(
      ImportedTranscriptReading.texts(of: transcript) == [
        "prompt: \(ImportSessionFiles.claudeCodeQuestion)",
        "response: Tool Bash: \(ImportSessionFiles.claudeCodeToolCommand): completed\n"
          + "\(ImportSessionFiles.claudeCodeToolOutput)\n\n\(ImportSessionFiles.claudeCodeAnswer)",
      ])
  }

  @Test("an import writes the updates of the source as the history of the new session")
  func anImportWritesTheHistory() async throws {
    let fixture = try await ImportFixture.make()
    let updates = try ClaudeCodeSessionReader(sourceID: Self.claudeID)
      .read(Data(contentsOf: fixture.file)).updates

    let result = try await fixture.importer.importSession(fixture.order())

    #expect(
      fixture.store.history(of: result.session)?.transcriptUpdates
        == SessionMergeEngine(replaying: updates).transcriptUpdates)
  }

  @Test("the result of an import names the new session")
  func theResultNamesTheNewSession() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order())

    #expect(try await fixture.directory.summary(of: result.session)?.title == result.name)
  }

  @Test("the name of the order is the name of the new session")
  func theNameOfTheOrderIsTheName() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order(name: Self.longerTitle))

    #expect(result.name == Self.longerTitle)
  }

  @Test("an import with no name takes the title of the source")
  func anImportWithNoNameTakesTheTitle() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order())

    #expect(result.name == Self.firstTitle)
  }

  @Test("a source with no title gives the name claude-code-import")
  func aSourceWithNoTitleGivesTheAgentImportName() async throws {
    let fixture = try await ImportFixture.make(title: nil)

    let result = try await fixture.importer.importSession(fixture.order())

    #expect(result.name == "claude-code-import")
  }

  @Test("a second import of the same source makes a second session with a new name")
  func aSecondImportMakesASecondSession() async throws {
    let fixture = try await ImportFixture.make()

    let first = try await fixture.importer.importSession(fixture.order())
    let second = try await fixture.importer.importSession(fixture.order())

    #expect(first.session != second.session && first.name != second.name)
  }

  @Test("after two imports of a source, previousImports has two entries")
  func twoImportsGiveTwoPreviousImports() async throws {
    let fixture = try await ImportFixture.make()
    _ = try await fixture.importer.importSession(fixture.order())
    _ = try await fixture.importer.importSession(fixture.order())

    let page = try await fixture.importer.importable(Self.request())

    #expect(page.sessions.first { $0.sourceID == Self.claudeID }?.previousImports.count == 2)
  }

  @Test("an import of a source by the path of its file imports that file")
  func anImportByPathImportsTheFile() async throws {
    let fixture = try await ImportFixture.make()

    let result = try await fixture.importer.importSession(fixture.order(source: fixture.file.path))

    #expect(
      try await fixture.directory.summary(of: result.session)?.importedFrom?.sourceID == Self.claudeID)
  }

  @Test("an import of a source that the root does not hold gives unknownSource")
  func anUnknownSourceThrows() async throws {
    let fixture = try await ImportFixture.make()

    await #expect(throws: AgentSessionImportError.unknownSource("no-such-session")) {
      try await fixture.importer.importSession(fixture.order(source: "no-such-session"))
    }
  }

  @Test("an import into a folder that does not exist makes no session")
  func anImportIntoAMissingFolderMakesNoSession() async throws {
    let fixture = try await ImportFixture.make()
    let missing = fixture.folder.appendingPathComponent("missing", isDirectory: true)

    await #expect(throws: SessionImportError.folderUnavailable(missing)) {
      try await fixture.importer.importSession(fixture.order(folder: missing))
    }

    #expect(
      try await fixture.directory.sessions(
        matching: SessionQuery(includesRecorded: true, limit: .max)
      ).isEmpty)
  }

  @Test("an import does not change the bytes or the date of the source file")
  func anImportLeavesTheSourceUnchanged() async throws {
    let fixture = try await ImportFixture.make()
    let before = try Self.fileStates(under: fixture.claude)

    _ = try await fixture.importer.importSession(fixture.order())

    #expect(try Self.fileStates(under: fixture.claude) == before)
  }

  @Test("a failed write of the history removes the folder of the new session")
  func aFailedHistoryWriteRemovesTheFolder() async throws {
    let fixture = try await ImportFixture.make(store: RecordingHistoryStore(failsWrite: true))

    await #expect(throws: RecordingHistoryStore.WriteFailure.self) {
      try await fixture.importer.importSession(fixture.order())
    }

    #expect(fixture.store.removedSessions.count == 1)
  }

  @Test("a failed write of the history fails the import")
  func aFailedHistoryWriteFailsTheImport() async throws {
    let fixture = try await ImportFixture.make(store: RecordingHistoryStore(failsWrite: true))

    await #expect(throws: RecordingHistoryStore.WriteFailure.self) {
      try await fixture.importer.importSession(fixture.order())
    }
  }
}

// MARK: - The fixtures of an import

/// A Claude Code root whose session works in a folder that exists, a directory that imports,
/// and a store that records the histories of the new sessions.
private struct ImportFixture {
  /// The directory label of the fixture.
  private static let label = "AgentSessionImporterTests-import"

  /// The source id of the Claude Code session.
  private static let claudeID = "5a1e0000-0000-4000-8000-000000000001"

  /// The custom title of the source session by default.
  static let sourceTitle = "Title A"

  /// The date of the last record of the session file
  /// (``ImportSessionFiles/claudeCodeLastRecordTimestamp``).
  ///
  /// - Returns: The date.
  /// - Throws: The error of the parse of the timestamp.
  static func lastRecordDate() throws -> Date {
    try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      .parse(ImportSessionFiles.claudeCodeLastRecordTimestamp)
  }

  /// The working folder of the source session. It exists.
  let folder: URL

  /// The Claude Code root (`~/.claude`).
  let claude: URL

  /// The file of the source session.
  let file: URL

  /// The session directory of the new sessions.
  let directory: InMemorySessionDirectory

  /// The store of the histories of the new sessions.
  let store: RecordingHistoryStore

  /// The importer under test.
  let importer: AgentSessionImporter

  /// Makes the fixture.
  ///
  /// - Parameters:
  ///   - title: The custom title of the source session, or `nil` for none.
  ///   - store: The store of the histories. A store whose writes succeed by default.
  /// - Returns: The fixture.
  /// - Throws: The error of a write.
  static func make(
    title: String? = sourceTitle, store: RecordingHistoryStore = RecordingHistoryStore()
  ) async throws -> ImportFixture {
    let base = TemporaryFolders.make(label: label)
    let folder = base.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let claude = base.appendingPathComponent(".claude", isDirectory: true)
    let file = try ImportSessionFiles.writeClaudeCode(
      id: claudeID, folder: folder, title: title, withAnswer: true, in: claude)
    let directory = InMemorySessionDirectory(
      launcher: InMemorySessionDirectory.Launcher(
        agentIDs: ["default"], defaultWorkingDirectory: folder))
    let importer = AgentSessionImporter(
      index: ExternalSessionIndex(
        fileSystem: UnwatchedLocalFileSystem(), indexFolder: nil, clock: ManualExternalSessionClock()),
      directory: directory, historyStore: store)
    await importer.replaceRoots([.claudeCode: claude])
    return ImportFixture(
      folder: folder, claude: claude, file: file, directory: directory, store: store,
      importer: importer)
  }

  /// The order that imports the source session.
  ///
  /// - Parameters:
  ///   - source: The id or the path of the source session. The id by default.
  ///   - folder: The folder of the new session, or `nil` for the folder of the source.
  ///   - name: The name of the new session, or `nil`.
  /// - Returns: The order.
  func order(source: String = claudeID, folder: URL? = nil, name: String? = nil)
    -> SessionImportOrder
  {
    SessionImportOrder(
      agent: ImportSourceAgent.claudeCode.rawValue, source: source, folder: folder, name: name)
  }
}

// MARK: - The temporary folders of a test

/// The temporary folders that one test of the suite made. The
/// ``RemovesTemporaryFoldersTrait`` removes them at the end of the test, so a run of the suite
/// leaves no folder in `/private/tmp`.
final class TemporaryFolders: Sendable {
  /// The folders of the test that runs now, or `nil` outside a test with the trait.
  @TaskLocal static var current: TemporaryFolders?

  /// The folders, in the order of their make.
  private let folders = Mutex<[URL]>([])

  /// Makes a new temporary folder, and keeps it for the removal at the end of the test.
  ///
  /// - Parameter label: The prefix of the name of the folder.
  /// - Returns: The folder.
  static func make(label: String) -> URL {
    let folder = makeResolvedDirectory(label: label)
    current?.folders.withLock { $0.append(folder) }
    return folder
  }

  /// Removes each kept folder.
  func removeAll() {
    for folder in folders.withLock({ $0 }) {
      try? FileManager.default.removeItem(at: folder)
    }
  }
}

/// A trait that removes the temporary folders of each test case at its end, also when the test
/// throws.
struct RemovesTemporaryFoldersTrait: SuiteTrait, TestTrait, TestScoping {
  /// The trait applies to each test of the suite.
  var isRecursive: Bool { true }

  /// Gives a scope to each test case only: a folder belongs to the one test that made it.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    testCase == nil ? nil : self
  }

  /// Runs the test with a new ``TemporaryFolders``, and removes its folders at the end.
  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    let folders = TemporaryFolders()
    defer { folders.removeAll() }
    try await TemporaryFolders.$current.withValue(folders) {
      try await function()
    }
  }
}

extension Trait where Self == RemovesTemporaryFoldersTrait {
  /// Removes the temporary folders of each test at its end.
  static var removesTemporaryFolders: Self { Self() }
}

/// The disk of the Mac with no watch: a change of a file reaches the index only through a find.
struct UnwatchedLocalFileSystem: ExternalSessionFileSystem {
  /// The disk.
  private let local = LocalExternalSessionFileSystem()

  func items(in folder: URL) throws -> [ExternalSessionDirectoryItem] {
    try local.items(in: folder)
  }

  func item(at url: URL) -> ExternalSessionDirectoryItem? {
    local.item(at: url)
  }

  func openForReading(_ file: URL) throws -> any SessionByteSource {
    try local.openForReading(file)
  }

  func contents(of file: URL) -> Data? {
    local.contents(of: file)
  }

  func replaceContents(of file: URL, with data: Data) throws {
    try local.replaceContents(of: file, with: data)
  }

  func removeItem(at file: URL) {
    local.removeItem(at: file)
  }

  func watch(
    _ folders: [URL], latency: Duration, onChange: @escaping @Sendable ([URL]) -> Void
  ) -> (any ExternalSessionWatch)? {
    nil
  }
}

/// A store of the histories of imported sessions that records each write and each removal.
final class RecordingHistoryStore: ImportedHistoryStore {
  /// The error of a write that fails.
  struct WriteFailure: Error {}

  /// True when each write throws ``WriteFailure``.
  private let failsWrite: Bool

  /// The written history of each session.
  private let histories = Mutex<[ULID: SessionMergeEngine]>([:])

  /// The sessions whose folder the importer removed, in order.
  private let removals = Mutex<[ULID]>([])

  /// Makes the store.
  ///
  /// - Parameter failsWrite: True when each write throws. False by default.
  init(failsWrite: Bool = false) {
    self.failsWrite = failsWrite
  }

  /// The sessions whose folder the importer removed, in order.
  var removedSessions: [ULID] { removals.withLock { $0 } }

  /// The written history of a session.
  ///
  /// - Parameter session: The session.
  /// - Returns: The history, or `nil` when no write gave one.
  func history(of session: ULID) -> SessionMergeEngine? {
    histories.withLock { $0[session] }
  }

  func writeHistory(_ history: SessionMergeEngine, of session: SessionSummary) throws {
    guard !failsWrite else { throw WriteFailure() }
    histories.withLock { $0[session.id] = history }
  }

  func removeFolder(of session: SessionSummary) {
    removals.withLock { $0.append(session.id) }
  }
}
