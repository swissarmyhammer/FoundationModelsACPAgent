import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The rebuild of the index of one source (``ExternalSessionIndex/rebuild(_:)``, D212 5.6): the
/// index removes the rows and the index file of the source, then finds and reads each file again.
@Suite struct ExternalSessionIndexRebuildTests {
  /// The number of files of the store.
  private static let fileCount = 40

  /// The number of project folders of the store.
  private static let projectCount = 4

  /// A query of each session of the store on one page.
  private static let everyRow = ExternalSessionQuery(automated: true, limit: fileCount)

  @Test("a rebuild reads each file again and gives the same rows")
  func aRebuildReadsEachFileAgain() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    let before = try await index.externalSessions(Self.everyRow)
    let readsBefore = store.fileSystem.reads.count

    let isRebuilt = await index.rebuild(.claudeCode)
    await index.waitUntilIdle()
    let after = try await index.externalSessions(Self.everyRow)
    let readPaths = Set(store.fileSystem.reads.dropFirst(readsBefore).map(\.path))

    #expect(isRebuilt)
    #expect(after.sessions == before.sessions)
    #expect(after.sessions.count == Self.fileCount)
    #expect(after.indexState.isComplete)
    #expect(readPaths == Set((0..<Self.fileCount).map { store.url(of: $0).path }))
    await index.stop()
  }

  @Test("a rebuild gives the old rows to a subscriber as removed")
  func aRebuildGivesTheOldRowsAsRemoved() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    var changes = index.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await changes.next()

    await index.rebuild(.claudeCode)
    var removed: Set<String> = []
    while removed.count < Self.fileCount, let change = await changes.next() {
      removed.formUnion(change.removed.map(\.sourceID))
    }

    #expect(removed == Set((0..<Self.fileCount).map(store.id(of:))))
    await index.stop()
  }

  @Test("a rebuild of a source with no root does nothing")
  func aRebuildOfASourceWithNoRootDoesNothing() async throws {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    let readsBefore = store.fileSystem.reads.count

    let isRebuilt = await index.rebuild(.codex)
    await index.waitUntilIdle()

    #expect(!isRebuilt)
    #expect(store.fileSystem.reads.count == readsBefore)
    await index.stop()
  }
}
