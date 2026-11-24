import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The counts of the typed and of the automated sessions of the index, for a root and for one
/// folder, with no paging (``ExternalSessionIndex/externalSessionCounts(source:folder:)``). Each
/// count is the same as the number of rows of a page of the same scope.
@Suite struct ExternalSessionCountsTests {
  /// The number of files of the store.
  private static let fileCount = 300

  /// The number of project folders of the store.
  private static let projectCount = 5

  /// The project of the folder counts.
  private static let countedProject = 2

  /// The number of rows of a page of the same scope.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - folder: The folder, or `nil` for each folder.
  ///   - automated: True to include the automated sessions.
  /// - Returns: The number of rows.
  private static func rowCount(
    _ index: ExternalSessionIndex, folder: URL?, automated: Bool
  ) async throws -> Int {
    try await index.externalSessions(
      ExternalSessionQuery(folder: folder, automated: automated, limit: fileCount)
    ).sessions.count
  }

  /// Checks the counts of a scope against the pages of that scope.
  private static func expectCountsMatchThePages(
    _ index: ExternalSessionIndex, folder: URL?
  ) async throws {
    let counts = try await index.externalSessionCounts(source: nil, folder: folder)
    let typed = try await rowCount(index, folder: folder, automated: false)
    let every = try await rowCount(index, folder: folder, automated: true)
    #expect(counts.typedCount == typed)
    #expect(counts.automatedCount == every - typed)
    #expect(counts.typedCount > 0)
    #expect(counts.automatedCount > 0)
  }

  @Test("the counts of a root and of a folder are the counts of their pages")
  func theCountsAreTheCountsOfThePages() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    try await Self.expectCountsMatchThePages(index, folder: nil)
    try await Self.expectCountsMatchThePages(index, folder: store.folder(ofProject: Self.countedProject))
    let root = try await index.externalSessionCounts(source: nil, folder: nil)
    let folder = try await index.externalSessionCounts(
      source: nil, folder: store.folder(ofProject: Self.countedProject))
    #expect(root.indexState == ExternalSessionIndexState(
      filesFound: Self.fileCount, filesRead: Self.fileCount, isComplete: true))
    #expect(folder.indexState.isComplete)
    #expect(folder.typedCount + folder.automatedCount < root.typedCount + root.automatedCount)
    await index.stop()
  }

  @Test("the counts change when a session file is removed")
  func theCountsChangeAfterARemoval() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    let typed = try #require(store.numbers(of: .typed).first)
    let automated = try #require(store.numbers(of: .automated).first)
    let before = try await index.externalSessionCounts(source: nil, folder: nil)
    var changes = index.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await changes.next()

    for number in [typed, automated] {
      store.fileSystem.removeFile(store.url(of: number))
      store.fileSystem.emit([store.url(of: number)])
      await ExternalSessionIndexWaits.untilRemoved(&changes, id: store.id(of: number))
    }
    let after = try await index.externalSessionCounts(source: nil, folder: nil)

    #expect(after.typedCount == before.typedCount - 1)
    #expect(after.automatedCount == before.automatedCount - 1)
    try await Self.expectCountsMatchThePages(index, folder: nil)
    await index.stop()
  }

  @Test("the counts of a source with no root are zero, and an unknown source is an error")
  func theCountsOfAnotherSource() async throws {
    let store = FakeSessionStore.make(fileCount: 10, projectCount: 1)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    let codex = try await index.externalSessionCounts(source: ImportSourceAgent.codex.rawValue, folder: nil)

    #expect(codex.typedCount == 0)
    #expect(codex.automatedCount == 0)
    await #expect(throws: ExternalSessionIndexError.unknownSource("none")) {
      _ = try await index.externalSessionCounts(source: "none", folder: nil)
    }
    await index.stop()
  }
}
