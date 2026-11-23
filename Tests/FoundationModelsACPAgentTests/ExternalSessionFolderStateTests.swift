import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The progress of one folder (`folderIndexState`) of ``ExternalSessionIndex``, so the header of
/// the sessions of other agents can show "Reading N of M" for the folder of a tab, and the error
/// of a cursor that is not a cursor of the index.
@Suite struct ExternalSessionFolderStateTests {
  /// The number of files of the store.
  private static let fileCount = 300

  /// The number of project folders of the store.
  private static let projectCount = 6

  /// The number of files of each project folder of the store.
  private static let filesOfAProject = fileCount / projectCount

  /// The project of the queries.
  private static let queriedProject = 1

  /// The most rows of a page.
  private static let limit = 10

  @Test("a folder query gives the progress of that folder, and a query with no folder gives none")
  func aFolderQueryGivesTheProgressOfTheFolder() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    let folderPage = try await index.externalSessions(
      ExternalSessionQuery(folder: store.folder(ofProject: Self.queriedProject), limit: Self.limit))
    let page = try await index.externalSessions(ExternalSessionQuery(limit: Self.limit))

    #expect(
      folderPage.folderIndexState
        == ExternalSessionIndexState(
          filesFound: Self.filesOfAProject, filesRead: Self.filesOfAProject, isComplete: true))
    #expect(folderPage.indexState.filesFound == Self.fileCount)
    #expect(page.folderIndexState == nil)
    await index.stop()
  }

  @Test("the progress of a folder is not complete while a file of the folder is not read")
  func theProgressOfAFolderCountsTheFilesNotRead() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let held = DispatchSemaphore(value: 0)
    // The file 1 is in the queried project. Its read waits until the test ends the hold.
    store.fileSystem.setReadHook(for: store.url(of: Self.queriedProject)) { held.wait() }
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilRead(index, atLeast: Self.fileCount - 1)
    let folder = store.folder(ofProject: Self.queriedProject)

    let during = try await index.externalSessions(ExternalSessionQuery(folder: folder, limit: Self.limit))
    held.signal()
    await index.waitUntilIdle()
    let after = try await index.externalSessions(ExternalSessionQuery(folder: folder, limit: Self.limit))

    #expect(
      during.folderIndexState
        == ExternalSessionIndexState(
          filesFound: Self.filesOfAProject, filesRead: Self.filesOfAProject - 1, isComplete: false))
    #expect(after.folderIndexState?.isComplete == true)
    await index.stop()
  }

  @Test("a stream of a folder gives the progress of that folder in each element")
  func aStreamOfAFolderGivesTheProgressOfTheFolder() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    var changes = index.externalSessionChanges(folder: store.folder(ofProject: Self.queriedProject))
      .makeAsyncIterator()

    let first = await changes.next()

    #expect(first?.folderIndexState?.filesFound == Self.filesOfAProject)
    #expect(first?.folderIndexState?.isComplete == true)
    await index.stop()
  }

  @Test("a query with a cursor that is not a cursor of the index gives invalidCursor")
  func aBadCursorGivesInvalidCursor() async throws {
    let store = FakeSessionStore.make(fileCount: 1, projectCount: 1)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()

    await #expect(throws: ExternalSessionError.invalidCursor("not-a-cursor")) {
      _ = try await index.externalSessions(ExternalSessionQuery(limit: Self.limit, cursor: "not-a-cursor"))
    }
    await index.stop()
  }
}
