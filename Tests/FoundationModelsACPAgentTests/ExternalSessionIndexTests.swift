import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The behavior of ``ExternalSessionIndex`` (D212, sections 4.4, 4.5 and 7) on a small fake
/// store: the reads of a changed, a grown and a gone file, the 30 s limit of a read, the index
/// file, the typed filter and the folder match. The scale is in
/// ``ExternalSessionIndexScaleTests``.
@Suite struct ExternalSessionIndexTests {
  // MARK: - Constants

  /// The number of files of the store.
  private static let fileCount = 300

  /// The number of project folders of the store.
  private static let projectCount = 6

  /// The most rows of a page that holds each file of the store.
  private static let wideLimit = 1_000

  /// The growth of a changed file, in bytes.
  private static let growth: Int64 = 4_096

  /// The number of changes of one file in the test of the 30 s limit.
  private static let changeCount = 100

  /// The time between two changes of one file: 100 changes in 10 s.
  private static let changeInterval: Duration = .milliseconds(100)

  /// The length of a new last line that is longer than each tail window (a long tool result).
  private static let longLineLength = 300_000

  /// The custom title in the head of a file.
  private static let customTitle = "My name"

  /// The text of a `summary` record in the tail of a file.
  private static let summaryText = "A summary"

  /// The format number of an index file of a later version of the agent.
  private static let laterFormatNumber = ExternalSessionIndexFile.formatNumber + 1

  // MARK: - Fixtures

  /// A store whose index read each file, and 30 s after that read.
  ///
  /// - Returns: The store and its index.
  private static func builtStore() async -> (store: FakeSessionStore, index: ExternalSessionIndex) {
    let store = FakeSessionStore.make(fileCount: fileCount, projectCount: projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    store.clock.advance(by: ExternalSessionIndex.rereadInterval)
    return (store, index)
  }

  /// Each row of the index, also the automated rows.
  ///
  /// - Parameter index: The index.
  /// - Returns: The rows.
  /// - Throws: The error of the query.
  private static func allRows(of index: ExternalSessionIndex) async throws -> [ExternalSessionSummary] {
    try await index.externalSessions(ExternalSessionQuery(automated: true, limit: wideLimit)).sessions
  }

  /// The reads of one file after a number of reads.
  ///
  /// - Parameters:
  ///   - url: The file.
  ///   - store: The store.
  ///   - start: The number of reads before.
  /// - Returns: The reads of the file.
  private static func reads(
    of url: URL, in store: FakeSessionStore, after start: Int
  ) -> [FakeExternalSessionFileSystem.Read] {
    store.fileSystem.reads[start...].filter { $0.path == url.path }
  }

  // MARK: - A changed file

  @Test("a file with a new stamp is read one time")
  func aFileWithANewStampIsReadOneTime() async throws {
    let (store, index) = await Self.builtStore()
    let url = store.url(of: 0)
    let opensBefore = store.fileSystem.opens[url.path] ?? 0

    store.fileSystem.change(url, growth: Self.growth)
    store.fileSystem.emit([url])
    await index.waitUntilIdle()

    #expect(store.fileSystem.opens[url.path] == opensBefore + 1)
  }

  @Test("a larger file with a known head gets a read of its tail only")
  func aLargerFileWithAKnownHeadGetsATailRead() async throws {
    let (store, index) = await Self.builtStore()
    let number = try #require(store.firstFile(of: .typed, largerThan: ExternalSessionScan.tailOnlyMinimumSize))
    let url = store.url(of: number)
    let readsBefore = store.fileSystem.readCount

    store.fileSystem.change(url, growth: Self.growth)
    store.fileSystem.emit([url])
    await index.waitUntilIdle()

    let reads = Self.reads(of: url, in: store, after: readsBefore)
    try #require(!reads.isEmpty)
    #expect(reads.allSatisfy { $0.offset > 0 })
  }

  @Test("a tail read keeps the first prompt and gives the new last prompt")
  func aTailReadKeepsTheHeadAndGivesTheNewTail() async throws {
    let (store, index) = await Self.builtStore()
    let number = try #require(store.firstFile(of: .typed, largerThan: ExternalSessionScan.tailOnlyMinimumSize))
    let url = store.url(of: number)

    store.fileSystem.change(url, growth: Self.growth)
    store.fileSystem.emit([url])
    await index.waitUntilIdle()

    var changed = store.file(number)
    changed.version += 1
    let row = try #require(try await Self.allRows(of: index).first { $0.sourceID == store.id(of: number) })
    #expect(
      [row.firstPrompt, row.lastPrompt] == [store.file(number).firstPrompt, changed.lastPrompt])
  }

  @Test("a grown file whose new last line is longer than the tail windows stays read with its fields")
  func aLongLastLineKeepsTheEntry() async throws {
    let (store, index) = await Self.builtStore()
    let number = try #require(store.firstFile(of: .typed, largerThan: ExternalSessionScan.tailOnlyMinimumSize))
    let url = store.url(of: number)

    store.fileSystem.change(url, growth: Int64(Self.longLineLength) + 1) { file in
      file.longLastLineLength = Self.longLineLength
    }
    store.fileSystem.emit([url])
    await index.waitUntilIdle()

    let row = try await Self.allRows(of: index).first { $0.sourceID == store.id(of: number) }
    #expect(row?.firstPrompt == store.file(number).firstPrompt)
  }

  @Test("a tail read keeps the title of the higher rank")
  func aTailReadKeepsTheTitleOfTheHigherRank() async throws {
    let store = FakeSessionStore.make(fileCount: 0, projectCount: 1)
    let number = try #require((0..<Self.fileCount).first { store.kind(of: $0) == .typed })
    var file = store.file(number)
    file.headTitle = Self.customTitle
    file.size = ExternalSessionScan.tailOnlyMinimumSize * 2
    store.fileSystem.add(file, at: store.url(of: number))
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    store.clock.advance(by: ExternalSessionIndex.rereadInterval)

    store.fileSystem.change(store.url(of: number), growth: Self.growth) { file in
      file.tailSummary = Self.summaryText
    }
    store.fileSystem.emit([store.url(of: number)])
    await index.waitUntilIdle()

    #expect(try await Self.allRows(of: index).first?.title == Self.customTitle)
  }

  @Test("a file that is gone while a worker reads it does not come back")
  func aFileGoneDuringItsReadDoesNotComeBack() async throws {
    let (store, index) = await Self.builtStore()
    let url = store.url(of: 0)
    let id = store.id(of: 0)
    let removalSeen = DispatchSemaphore(value: 0)
    store.fileSystem.setReadHook(for: url) {
      store.fileSystem.removeFile(url)
      store.fileSystem.emit([url])
      // The read goes on after the index applied the event of the removal.
      removalSeen.wait()
    }
    var changes = index.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await changes.next()

    store.fileSystem.change(url, growth: Self.growth)
    store.fileSystem.emit([url])
    await ExternalSessionIndexWaits.untilRemoved(&changes, id: id)
    removalSeen.signal()
    await index.waitUntilIdle()

    #expect(try await !Self.allRows(of: index).contains { $0.sourceID == id })
  }

  @Test("a find keeps an entry that an event adds while the directory read runs")
  func aFindKeepsAnEntryThatAnEventAdds() async throws {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1)
    let projectFolder = store.url(of: 0).deletingLastPathComponent()
    let lateNumber = 1
    let late = projectFolder.appendingPathComponent("\(store.id(of: lateNumber)).jsonl")
    let lateFileRead = DispatchSemaphore(value: 0)
    store.fileSystem.setListingHook(for: projectFolder) {
      // The listing has no late file. Its event, and the read of the file, come before the
      // find ends.
      store.fileSystem.add(store.file(lateNumber), at: late)
      store.fileSystem.emit([late])
      lateFileRead.wait()
    }
    let index = store.makeIndex()
    var changes = index.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await changes.next()

    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilRead(&changes, atLeast: 1)
    lateFileRead.signal()
    await index.waitUntilIdle()

    #expect(try await Self.allRows(of: index).contains { $0.sourceID == store.id(of: lateNumber) })
  }

  @Test("a stop right after the roots leaves no watch")
  func aStopLeavesNoWatch() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()

    await index.replaceRoots(store.roots)
    await index.stop()

    #expect(store.fileSystem.watchCount == 0)
  }

  @Test("the project key of a folder query comes from the resolved path of the folder")
  func theProjectKeyOfAQueryIsResolved() {
    let match = ExternalSessionFolderMatch(folder: URL(fileURLWithPath: "/tmp/proj", isDirectory: true))

    #expect(match.projectKey == "-private-tmp-proj")
  }

  @Test("a file that is gone loses its entry")
  func aFileThatIsGoneLosesItsEntry() async throws {
    let (store, index) = await Self.builtStore()
    let url = store.url(of: 0)

    store.fileSystem.removeFile(url)
    store.fileSystem.emit([url])
    await index.waitUntilIdle()

    #expect(try await !Self.allRows(of: index).contains { $0.sourceID == store.id(of: 0) })
  }

  @Test("100 changes of one file in 10 s cause at most one read")
  func oneHundredChangesCauseAtMostOneRead() async throws {
    let (store, index) = await Self.builtStore()
    let url = store.url(of: 0)
    let opensBefore = store.fileSystem.opens[url.path] ?? 0

    for _ in 0..<Self.changeCount {
      store.fileSystem.change(url, growth: Self.growth)
      store.fileSystem.emit([url])
      await index.waitUntilIdle()
      store.clock.advance(by: Self.changeInterval)
    }

    #expect((store.fileSystem.opens[url.path] ?? 0) - opensBefore <= 1)
  }

  @Test("the last change of a file in 10 s is read 30 s after the read before it")
  func theLastChangeIsReadAfterTheLimit() async throws {
    let (store, index) = await Self.builtStore()
    let url = store.url(of: 0)
    for _ in 0..<Self.changeCount {
      store.fileSystem.change(url, growth: Self.growth)
      store.fileSystem.emit([url])
      await index.waitUntilIdle()
      store.clock.advance(by: Self.changeInterval)
    }

    store.clock.advance(by: ExternalSessionIndex.rereadInterval)
    await index.waitUntilIdle()

    let row = try #require(try await Self.allRows(of: index).first { $0.sourceID == store.id(of: 0) })
    var changed = store.file(0)
    changed.version = Self.changeCount
    #expect(row.lastPrompt == changed.lastPrompt)
  }

  // MARK: - The index file

  /// A change of the index file of a built store that makes the file unusable.
  enum IndexFileDamage: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The header has the format number of a later version of the agent.
    case laterFormatNumber

    /// A line of the file is not JSON.
    case badBytes

    /// The name of the change in the test results.
    var testDescription: String { rawValue }

    /// The damaged bytes of a good index file.
    ///
    /// - Parameter data: The bytes of the good file.
    /// - Returns: The damaged bytes.
    func applied(to data: Data) -> Data {
      switch self {
      case .laterFormatNumber:
        Data(
          String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: #""format":\#(ExternalSessionIndexFile.formatNumber)"#,
            with: #""format":\#(ExternalSessionIndexTests.laterFormatNumber)"#
          ).utf8)
      case .badBytes:
        data + Data("{not json\n".utf8)
      }
    }
  }

  @Test("an index file that the index cannot use causes a new build", arguments: IndexFileDamage.allCases)
  func anUnusableIndexFileCausesANewBuild(_ damage: IndexFileDamage) async throws {
    let (store, _) = await Self.builtStore()
    let good = try #require(store.fileSystem.agentFile(at: FakeSessionStore.indexFile))
    store.fileSystem.setAgentFile(damage.applied(to: good), at: FakeSessionStore.indexFile)
    let opensBefore = store.fileSystem.openCount
    let index = store.makeIndex()

    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    #expect(store.fileSystem.openCount - opensBefore == Self.fileCount)
  }

  @Test("an index file that the index cannot use gives a complete index with no error")
  func anUnusableIndexFileGivesACompleteIndex() async throws {
    let (store, _) = await Self.builtStore()
    store.fileSystem.setAgentFile(Data("{not json\n".utf8), at: FakeSessionStore.indexFile)
    let index = store.makeIndex()

    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    #expect(
      await index.indexState
        == ExternalSessionIndexState(filesFound: Self.fileCount, filesRead: Self.fileCount, isComplete: true))
  }

  @Test("a removed root removes its index file")
  func aRemovedRootRemovesItsIndexFile() async throws {
    let (store, index) = await Self.builtStore()
    try #require(store.fileSystem.agentFile(at: FakeSessionStore.indexFile) != nil)

    await index.replaceRoots([:])
    await index.waitUntilIdle()

    #expect(store.fileSystem.agentFile(at: FakeSessionStore.indexFile) == nil)
  }

  // MARK: - The typed filter

  @Test("a query of the typed sessions gives no automated session")
  func aTypedQueryGivesNoAutomatedSession() async throws {
    let (_, index) = await Self.builtStore()

    let page = try await index.externalSessions(ExternalSessionQuery(limit: Self.wideLimit))

    try #require(!page.sessions.isEmpty)
    #expect(page.sessions.allSatisfy { !$0.isAutomated })
  }

  @Test("a query of the typed sessions gives each session with no entrypoint")
  func aTypedQueryGivesEachSessionWithNoEntrypoint() async throws {
    let (store, index) = await Self.builtStore()

    let page = try await index.externalSessions(ExternalSessionQuery(limit: Self.wideLimit))

    let expected = Set(store.numbers(of: .noEntrypoint).map(store.id(of:)))
    #expect(expected.isSubset(of: Set(page.sessions.map(\.sourceID))))
  }

  // MARK: - The folder match

  @Test("a folder query gives only the sessions whose cwd is the folder")
  func aFolderQueryComparesTheCwd() async throws {
    let store = FakeSessionStore.make(fileCount: 0, projectCount: 1)
    let dotted = URL(fileURLWithPath: "/work/a.b", isDirectory: true)
    let dashed = URL(fileURLWithPath: "/work/a-b", isDirectory: true)
    // Both folders have the project key `-work-a-b`, thus their files share one project folder.
    for (number, folder) in [dotted, dashed].enumerated() {
      let id = store.id(of: number)
      store.fileSystem.add(
        FakeExternalSessionFileSystem.File(
          id: id, cwd: folder.path, kind: .typed, size: ExternalSessionScan.tailOnlyMinimumSize * 2,
          modified: Date(timeIntervalSince1970: TimeInterval(number)), hasTailFolder: true),
        at: FakeSessionStore.root.appendingPathComponent(
          "projects/\(ImportSourceAgent.projectKey(of: dashed))/\(id).jsonl"))
    }
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    let page = try await index.externalSessions(ExternalSessionQuery(folder: dashed, limit: Self.wideLimit))

    #expect(page.sessions.map(\.sourceID) == [store.id(of: 1)])
  }

  @Test("a folder query gives the sessions of the folder, the newest first")
  func aFolderQueryGivesTheNewestFirst() async throws {
    let (store, index) = await Self.builtStore()

    let page = try await index.externalSessions(
      ExternalSessionQuery(folder: store.folder(ofProject: 1), automated: true, limit: Self.wideLimit))

    let expected = (0..<Self.fileCount).filter { store.project(of: $0) == 1 }.map(store.id(of:))
    #expect(page.sessions.map(\.sourceID) == expected)
  }

  @Test("a folder query of a project folder with no entry finds and reads that one folder")
  func aFolderQueryWithNoEntryFindsItsFolder() async throws {
    let store = FakeSessionStore.make(
      fileCount: Self.fileCount, projectCount: Self.projectCount, givesWatches: false)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    // A new project folder after the find, with no event: only a find of that one folder
    // finds it before the find interval of the root.
    let newFolder = URL(fileURLWithPath: "/work/new-project", isDirectory: true)
    let id = store.id(of: Self.fileCount)
    store.fileSystem.add(
      FakeExternalSessionFileSystem.File(
        id: id, cwd: newFolder.path, kind: .typed, size: ExternalSessionScan.tailOnlyMinimumSize * 2,
        modified: Date(), hasTailFolder: true),
      at: FakeSessionStore.root.appendingPathComponent(
        "projects/\(ImportSourceAgent.projectKey(of: newFolder))/\(id).jsonl"))

    _ = try await index.externalSessions(ExternalSessionQuery(folder: newFolder, limit: Self.wideLimit))
    await index.waitUntilIdle()

    let page = try await index.externalSessions(ExternalSessionQuery(folder: newFolder, limit: Self.wideLimit))
    #expect(page.sessions.map(\.sourceID) == [id])
  }

  @Test("a stream of a folder gives a session of that folder that a read adds")
  func aFolderStreamGivesANewSession() async throws {
    let (store, index) = await Self.builtStore()
    let number = Self.fileCount
    let url = store.url(of: number)
    let changes = index.externalSessionChanges(folder: store.folder(ofProject: store.project(of: number)))
    var iterator = changes.makeAsyncIterator()
    _ = await iterator.next()

    store.fileSystem.add(store.file(number), at: url)
    store.fileSystem.emit([url])
    let change = await iterator.next()

    #expect(change?.changed.map(\.sourceID) == [store.id(of: number)])
  }
}
