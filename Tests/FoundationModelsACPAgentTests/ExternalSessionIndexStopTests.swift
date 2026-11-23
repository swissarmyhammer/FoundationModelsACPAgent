import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The stops, the finds that run at one time, and the start of a root of
/// ``ExternalSessionIndex``: the defects that the review of D212 step 2 found. Each test holds
/// the index at one step with a hook of the fake file system, so no test uses a clock or a
/// time limit.
@Suite struct ExternalSessionIndexStopTests {
  /// The number of project folders of a store with more than one folder.
  private static let projectCount = 6

  /// The most rows of a page that holds each file of a small store.
  private static let wideLimit = 1_000

  /// Each row of the index, also the automated rows.
  ///
  /// - Parameter index: The index.
  /// - Returns: The rows.
  /// - Throws: The error of the query.
  private static func allRows(of index: ExternalSessionIndex) async throws -> [ExternalSessionSummary] {
    try await index.externalSessions(ExternalSessionQuery(automated: true, limit: wideLimit)).sessions
  }

  @Test("a second stop stops each watch one time only")
  func aSecondStopStopsNoWatchAgain() async {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    await index.stop()
    await index.stop()

    #expect(store.fileSystem.watchStopCount == 1)
  }

  @Test("a removed root stops the find that runs, at the next folder")
  func aRemovedRootStopsItsFind() async {
    let store = FakeSessionStore.make(fileCount: Self.projectCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) {
      // The find has read the folder of the project folders. The root goes before it reads
      // a project folder.
      let removed = DispatchSemaphore(value: 0)
      Task {
        await index.replaceRoots([:])
        removed.signal()
      }
      removed.wait()
    }

    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    #expect(store.fileSystem.directoryReadCount == 1)
  }

  @Test("a stop during a find writes no index file with less entries")
  func aStopDuringAFindRemovesNoEntry() async throws {
    let store = FakeSessionStore.make(fileCount: Self.projectCount, projectCount: Self.projectCount)
    let first = store.makeIndex()
    await first.replaceRoots(store.roots)
    await first.waitUntilIdle()
    await first.stop()
    let second = store.makeIndex()
    store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) {
      // The second index loaded the index file. Its find stops before it reads a project
      // folder, so it found no file. The stop cancels the finds before it stops the watch,
      // and it waits for this find, so the hook waits only for the stop of the watch.
      let stopStarted = DispatchSemaphore(value: 0)
      store.fileSystem.setWatchStopHook { stopStarted.signal() }
      Task { await second.stop() }
      stopStarted.wait()
    }

    await second.replaceRoots(store.roots)
    await second.waitUntilIdle()
    await second.stop()

    let data = try #require(store.fileSystem.agentFile(at: FakeSessionStore.indexFile))
    let entries = try #require(
      ExternalSessionIndexFile.entries(in: data, of: .claudeCode, root: FakeSessionStore.root))
    #expect(entries.count == Self.projectCount)
  }

  @Test("an import before the load of the index file ends finds a session that the file does not have")
  func anImportBeforeTheLoadFindsANewSession() async throws {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1)
    let first = store.makeIndex()
    await first.replaceRoots(store.roots)
    await first.waitUntilIdle()
    await first.stop()
    let newNumber = 1
    store.fileSystem.add(store.file(newNumber), at: store.url(of: newNumber))
    let loadMayGo = DispatchSemaphore(value: 0)
    let installed = DispatchSemaphore(value: 0)
    store.fileSystem.setAgentFileHook(for: FakeSessionStore.indexFile) { loadMayGo.wait() }
    store.fileSystem.setReadHook(for: store.url(of: newNumber)) {
      // The import reads the new file. The load of the index file installs its entries
      // before this read ends.
      loadMayGo.signal()
      installed.wait()
    }
    // The index starts the watch of the root after it installed the entries of the file.
    store.fileSystem.setWatchHook { installed.signal() }
    // The first listing is the find of the import. The find of the start of the root comes
    // after the load, and it waits until the import ended, so it does not add the file again.
    let importEnded = DispatchSemaphore(value: 0)
    store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) {
      store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) { importEnded.wait() }
    }
    let second = store.makeIndex()

    await second.replaceRoots(store.roots)
    let located = await second.session(matching: store.id(of: newNumber), of: .claudeCode)
    importEnded.signal()
    await second.waitUntilIdle()

    #expect(located?.summary.sourceID == store.id(of: newNumber))
    await second.stop()
  }

  @Test("the end of one find of a root does not end the state of an other find of the root")
  func twoFindsOfARootKeepTheirState() async {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1, givesWatches: false)
    let index = store.makeIndex()
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let hold = DispatchSemaphore(value: 0)
    store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) {
      enter.yield()
      hold.wait()
    }
    await index.replaceRoots(store.roots)
    for await _ in entered { break }
    // The find of the start of the root waits in the hook. The find of an import runs now
    // and ends.
    _ = await index.session(matching: "no-such-session", of: .claudeCode)
    let readsAfterTwoFinds = store.fileSystem.directoryReadCount
    store.clock.advance(by: ExternalSessionIndex.findInterval)

    // The first find still runs, so this query starts no find.
    _ = try? await Self.allRows(of: index)
    hold.signal()
    await index.waitUntilIdle()

    #expect(store.fileSystem.directoryReadCount == readsAfterTwoFinds + 1)
    await index.stop()
  }

  @Test("a folder of the layout that comes after the watch started is found by a query")
  func aLaterLayoutFolderIsFound() async throws {
    let store = FakeSessionStore.make(fileCount: 0, projectCount: 1)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    // The folder of the project folders did not exist when the watch started, so the watch
    // gives no event for this file.
    store.fileSystem.add(store.file(0), at: store.url(of: 0))
    store.clock.advance(by: ExternalSessionIndex.findInterval)

    _ = try await Self.allRows(of: index)
    await index.waitUntilIdle()

    #expect(try await Self.allRows(of: index).contains { $0.sourceID == store.id(of: 0) })
    await index.stop()
  }
}
