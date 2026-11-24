import ACPImport
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The external items of the transcript search index (D212, design sections 5.2 and 6): one item
/// for each typed session that the index of the external sessions has read, and the external
/// results of the search of Multitool.
///
/// Each case builds a small fake store of Claude Code with ``FakeSessionStore``, follows its
/// index with ``TranscriptSearchUpdates/followExternalSessions(_:rows:onApplied:)``, and waits
/// on the hook of each applied change until the items hold the state that the case expects. No
/// case uses a clock or a time limit. Each case removes the folder of its search index.
@Suite struct TranscriptSearchExternalTests {
  // MARK: - Constants

  /// The name of the suite, for the folders of the search index.
  private static let label = "TranscriptSearchExternalTests"

  /// The number of files of the store: 93 automated, 4 typed and 3 with no entrypoint.
  private static let fileCount = 100

  /// The number of project folders of the store.
  private static let projectCount = 2

  /// The most rows of a page that holds each file of the store.
  private static let wideLimit = 1_000

  /// A word that only the title of one typed session holds.
  private static let titleWord = "quokka"

  /// A word that only the new title of that session holds, after a re-read.
  private static let newTitleWord = "wombat"

  /// The most results of a page of a search.
  private static let pageLimit = 20

  // MARK: - Fixtures

  /// A store whose index read each file, a search index in a new folder, and the follow of the
  /// index of the store.
  private struct Setup {
    /// The fake store of Claude Code.
    let store: FakeSessionStore

    /// The index of the external sessions of the store.
    let externalIndex: ExternalSessionIndex

    /// The transcript search index.
    let searchIndex: TranscriptSearchIndex

    /// The updates that follow ``externalIndex``. The setup holds them, so their tasks live.
    let updates: TranscriptSearchUpdates

    /// One element after each change that the search index applied.
    let applied: AsyncStream<Void>

    /// The folder of the search index.
    let folder: URL

    /// Builds the store and its index, then starts the follow.
    ///
    /// - Parameter prepare: A change of the store before the build, for example a title.
    init(prepare: (FakeSessionStore) -> Void = { _ in }) async {
      store = FakeSessionStore.make(
        fileCount: TranscriptSearchExternalTests.fileCount,
        projectCount: TranscriptSearchExternalTests.projectCount)
      prepare(store)
      externalIndex = store.makeIndex()
      await externalIndex.replaceRoots(store.roots)
      await externalIndex.waitUntilIdle()
      folder = makeResolvedDirectory(label: TranscriptSearchExternalTests.label)
      searchIndex = TranscriptSearchIndex(
        folder: folder, embedder: nil, modelID: nil, readableFolder: { _ in true })
      await searchIndex.load()
      updates = TranscriptSearchUpdates(index: searchIndex, summaryReader: { _ in nil })
      let (applied, input) = AsyncStream.makeStream(of: Void.self)
      self.applied = applied
      let externalIndex = externalIndex
      updates.followExternalSessions(
        externalIndex.externalSessionChanges(folder: nil),
        rows: { await externalIndex.typedReadSessions() }, onApplied: { input.yield() })
    }

    /// Waits for the applied changes until a condition holds. The condition is checked first,
    /// and again after each applied change.
    ///
    /// - Parameter condition: The condition.
    func until(_ condition: () async throws -> Bool) async rethrows {
      var iterator = applied.makeAsyncIterator()
      while try await !condition() {
        guard await iterator.next() != nil else {
          return
        }
      }
    }

    /// The sessions of the external items of the search index.
    ///
    /// - Returns: The sessions.
    func itemSessions() async -> [ExternalSessionSummary] {
      await searchIndex.externalSessions()
    }

    /// Each session that the index of the external sessions has read, also the automated ones.
    ///
    /// - Returns: The sessions.
    /// - Throws: The error of the query.
    func readSessions() async throws -> [ExternalSessionSummary] {
      try await externalIndex.externalSessions(
        ExternalSessionQuery(automated: true, limit: TranscriptSearchExternalTests.wideLimit)
      ).sessions
    }

    /// The page of a search of a query.
    ///
    /// - Parameters:
    ///   - text: The query.
    ///   - sessions: The session filter, or `nil` for none.
    ///   - cursor: The cursor of the page, or `nil` for the first page.
    /// - Returns: The page.
    /// - Throws: The error of the parse or of the search.
    func search(_ text: String, sessions: Set<ULID>? = nil, cursor: String? = nil) async throws
      -> SessionSearchPage
    {
      try await searchIndex.search(
        SessionSearchRequest(
          query: try SessionSearchQuery(parsing: text), sessions: sessions, includeArchived: false,
          preferredFolder: nil, session: nil, limit: TranscriptSearchExternalTests.pageLimit,
          cursor: cursor),
        visibleSessions: [:])
    }

    /// Changes the title of a file of the store, and waits until the index read it again. The
    /// clock first moves past the 30 s limit of a read, so the index reads the file now.
    ///
    /// - Parameters:
    ///   - number: The number of the file.
    ///   - title: The new title.
    func retitle(_ number: Int, to title: String) async {
      let url = store.url(of: number)
      store.clock.advance(by: ExternalSessionIndex.rereadInterval)
      store.fileSystem.change(url, growth: 1) { $0.tailSummary = title }
      store.fileSystem.emit([url])
      await externalIndex.waitUntilIdle()
    }

    /// Stops the follow and the index of the external sessions, and removes the folder of the
    /// search index.
    func close() async {
      await updates.stopFollowingExternalSessions()
      await searchIndex.waitForSaves()
      await externalIndex.stop()
      try? FileManager.default.removeItem(at: folder)
    }
  }

  /// The first typed file of the store.
  ///
  /// - Parameter store: The store.
  /// - Returns: The number of the file.
  /// - Throws: An error when the store has no typed file.
  private static func typedFile(of store: FakeSessionStore) throws -> Int {
    try #require(store.numbers(of: .typed).first)
  }

  /// Sets the title of the first typed file before the build.
  ///
  /// - Parameter store: The store.
  private static func titleFirstTypedFile(_ store: FakeSessionStore) {
    guard let number = store.numbers(of: .typed).first else {
      return
    }
    let url = store.url(of: number)
    store.fileSystem.change(url, growth: 1) { $0.tailSummary = "The \(titleWord) migration" }
  }

  // MARK: - The items

  @Test("the index holds one external item for each typed session and none for an automated one")
  func anItemForEachTypedSession() async throws {
    let setup = await Setup()
    let read = try await setup.readSessions()
    let typedIDs = Set(read.filter { !$0.isAutomated }.map(\.id))
    try #require(!typedIDs.isEmpty && read.contains(where: \.isAutomated))

    await setup.until { Set(await setup.itemSessions().map(\.id)) == typedIDs }

    #expect(Set(await setup.itemSessions().map(\.id)) == typedIDs)
    #expect(Set(await setup.externalIndex.typedReadSessions().map(\.id)) == typedIDs)
    await setup.close()
  }

  @Test("a change with automated sessions gives no item to an automated session")
  func aChangeGivesNoItemToAnAutomatedSession() async throws {
    let setup = await Setup()
    let read = try await setup.readSessions()
    let typedIDs = Set(read.filter { !$0.isAutomated }.map(\.id))
    await setup.until { Set(await setup.itemSessions().map(\.id)) == typedIDs }

    // The index of the external sessions gives the automated sessions in its changes too.
    await setup.searchIndex.updateExternalSessions(changed: read, removed: [])

    #expect(Set(await setup.itemSessions().map(\.id)) == typedIDs)
    await setup.close()
  }

  @Test("a removed session of a change loses its item")
  func aRemovedSessionLosesItsItem() async throws {
    let setup = await Setup()
    let typed = try await setup.readSessions().filter { !$0.isAutomated }
    let removed = try #require(typed.first).id
    await setup.until { await setup.itemSessions().count == typed.count }

    await setup.searchIndex.updateExternalSessions(changed: [], removed: [removed])

    let kept = Set(typed.map(\.id)).subtracting([removed])
    #expect(Set(await setup.itemSessions().map(\.id)) == kept)
    await setup.close()
  }

  @Test("an external item has the id external:<source>/<id> and the block of the index fields")
  func anItemHasTheExternalIDAndTheIndexFields() {
    let summary = ExternalSessionSummary(
      source: "claude-code", sourceID: "abc", path: "projects/p/abc.jsonl", size: 1,
      modified: Date(timeIntervalSince1970: 0), cwd: URL(fileURLWithPath: "/work/p"),
      gitBranch: "main", title: "Title", firstPrompt: "First", lastPrompt: "Last", state: .read)

    let item = TranscriptSearchItem(external: summary)

    #expect(item.id == "external:claude-code/abc")
    #expect(item.renderBlock() == "Title\nFirst\nLast\n/work/p\nmain")
  }

  // MARK: - The search

  @Test("a search on a word of a title gives the external session with the field title")
  func aTitleWordGivesTheExternalResult() async throws {
    let setup = await Setup(prepare: Self.titleFirstTypedFile)
    let id = setup.store.id(of: try Self.typedFile(of: setup.store))

    try await setup.until { try await !setup.search(Self.titleWord).externalSessions.isEmpty }

    let page = try await setup.search(Self.titleWord)
    #expect(page.externalSessions.map(\.session.sourceID) == [id])
    #expect(page.externalSessions.first?.field == ExternalSessionSearchResult.titleField)
    #expect(page.sessions.isEmpty)
    await setup.close()
  }

  @Test("a re-read with a new title changes the external result")
  func aNewTitleChangesTheResult() async throws {
    let setup = await Setup(prepare: Self.titleFirstTypedFile)
    let number = try Self.typedFile(of: setup.store)
    try await setup.until { try await !setup.search(Self.titleWord).externalSessions.isEmpty }

    await setup.retitle(number, to: "The \(Self.newTitleWord) plan")
    try await setup.until { try await !setup.search(Self.newTitleWord).externalSessions.isEmpty }

    let newPage = try await setup.search(Self.newTitleWord)
    #expect(newPage.externalSessions.map(\.session.sourceID) == [setup.store.id(of: number)])
    #expect(try await setup.search(Self.titleWord).externalSessions.isEmpty)
    await setup.close()
  }

  @Test("a removed root removes the external items and the external results")
  func aRemovedRootRemovesTheResults() async throws {
    let setup = await Setup(prepare: Self.titleFirstTypedFile)
    try await setup.until { try await !setup.search(Self.titleWord).externalSessions.isEmpty }

    await setup.externalIndex.replaceRoots([:])
    await setup.until { await setup.itemSessions().isEmpty }

    #expect(await setup.itemSessions().isEmpty)
    #expect(try await setup.search(Self.titleWord).externalSessions.isEmpty)
    await setup.close()
  }

  @Test("a search with a sessions filter gives no external result")
  func aSessionsFilterGivesNoExternalResult() async throws {
    let setup = await Setup(prepare: Self.titleFirstTypedFile)
    try await setup.until { try await !setup.search(Self.titleWord).externalSessions.isEmpty }

    let page = try await setup.search(Self.titleWord, sessions: [ULID()])

    #expect(page.externalSessions.isEmpty)
    await setup.close()
  }

  @Test("a later page of a search gives no external result")
  func aLaterPageGivesNoExternalResult() async throws {
    let setup = await Setup(prepare: Self.titleFirstTypedFile)
    try await setup.until { try await !setup.search(Self.titleWord).externalSessions.isEmpty }

    let page = try await setup.search(
      Self.titleWord, cursor: TranscriptSearchCursor.cursor(of: Self.pageLimit))

    #expect(page.externalSessions.isEmpty)
    await setup.close()
  }
}
