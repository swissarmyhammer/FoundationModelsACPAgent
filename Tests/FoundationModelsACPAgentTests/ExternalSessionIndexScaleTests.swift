import ACPImport
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The scale of ``ExternalSessionIndex`` (D212, section 7): a fake store of 30,000 Claude Code
/// files in 60 project folders, with sizes from 100 KB to 60 MB, 93% automated. The fake
/// counts each call and each byte, and holds no file bytes.
@Suite struct ExternalSessionIndexScaleTests {
  // MARK: - Constants

  /// The number of files of the store.
  private static let fileCount = 30_000

  /// The number of project folders of the store.
  private static let projectCount = 60

  /// The project of the folder query of the shared build.
  private static let queriedProject = 41

  /// The most rows of a page of a query.
  private static let pageLimit = 20

  /// The most bytes that the index reads of one file: 384 KB.
  private static let mostBytesOfAFile = 393_216

  /// The most bytes of one read call: 256 KB.
  private static let mostBytesOfARead = 262_144

  /// The number of files that the index reads before a test measures a query.
  private static let filesReadBeforeTheQuery = 1_000

  /// The number of files that the index reads before a test removes the root.
  private static let filesReadBeforeTheRemoval = 500

  /// The number of files of the large first project of the store of a follow.
  private static let largeProjectFileCount = 5_000

  // MARK: - The shared build

  /// A store, its index after a full build, and the number of reads before the folder query
  /// that started the build.
  private struct Build: Sendable {
    /// The store.
    let store: FakeSessionStore

    /// The index.
    let index: ExternalSessionIndex

    /// The number of reads before the folder query.
    let readsBeforeTheQuery: Int
  }

  /// The full build that the tests of the read limits share, in a fixed order.
  ///
  /// The index file holds each file in the state `found`, so the load gives each entry and
  /// queues no file. The directory read of the root waits until a follow of ``queriedProject``
  /// starts. Thus no worker reads a file before the follow, and the find then queues the files
  /// of that folder at level 1. The test waits until the index is idle.
  private static let sharedBuild = Task { () -> Build in
    let store = FakeSessionStore.make(fileCount: fileCount, projectCount: projectCount)
    store.fileSystem.setAgentFile(store.foundIndexFile(), at: FakeSessionStore.indexFile)
    let findHold = DispatchSemaphore(value: 0)
    store.fileSystem.setListingHook(for: FakeSessionStore.projectsFolder) { findHold.wait() }
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilFound(index, atLeast: fileCount)
    let (followStarted, start) = AsyncStream.makeStream(of: Void.self)
    let follow = Task {
      try await index.whileFollowing(folder: store.folder(ofProject: queriedProject)) {
        start.yield()
        try await ExternalSessionIndexWaits.untilCancelled()
      }
    }
    for await _ in followStarted { break }
    let readsBeforeTheQuery = store.fileSystem.readCount
    findHold.signal()
    await index.waitUntilIdle()
    follow.cancel()
    _ = await follow.result
    return Build(store: store, index: index, readsBeforeTheQuery: readsBeforeTheQuery)
  }

  /// The bytes that the build read of each file, by its path.
  ///
  /// - Parameter reads: The reads.
  /// - Returns: The bytes of each file.
  private static func bytesOfEachFile(_ reads: [FakeExternalSessionFileSystem.Read]) -> [String: Int] {
    Dictionary(reads.map { ($0.path, min($0.length, Int($0.size) - $0.offset)) }, uniquingKeysWith: +)
  }

  /// The files of some reads in the order of their first read.
  ///
  /// - Parameter reads: The reads.
  /// - Returns: The paths of the files.
  private static func filesInReadOrder(_ reads: ArraySlice<FakeExternalSessionFileSystem.Read>) -> [String] {
    var seen: Set<String> = []
    return reads.map(\.path).filter { seen.insert($0).inserted }
  }

  // MARK: - The reads of a build

  @Test("a follow puts its project folder first: until that folder is read, other files are only the reads in flight")
  func aFolderQueryReadsItsProjectFolderFirst() async throws {
    let build = await Self.sharedBuild.value
    let root = build.store.fileSystem.reads.map { read in
      FakeExternalSessionFileSystem.Read(
        path: String(read.path.dropFirst(FakeSessionStore.root.path.count + 1)), offset: read.offset,
        length: read.length, size: read.size)
    }
    let order = Self.filesInReadOrder(root[build.readsBeforeTheQuery...])
    let lastFolderFile = try #require(
      order.lastIndex { build.store.isPath($0, ofProject: Self.queriedProject) })

    let others = order[...lastFolderFile].filter {
      !build.store.isPath($0, ofProject: Self.queriedProject)
    }

    #expect(others.count <= ExternalSessionIndex.workerCount, "\(others.count) other files")
  }

  @Test("a full build reads at most 384 KB of each file")
  func aFullBuildReadsAtMost384KBOfEachFile() async throws {
    let build = await Self.sharedBuild.value

    let most = Self.bytesOfEachFile(build.store.fileSystem.reads).values.max() ?? 0

    #expect(most <= Self.mostBytesOfAFile, "\(most) bytes")
  }

  @Test("a full build reads each file of the store")
  func aFullBuildReadsEachFile() async throws {
    let build = await Self.sharedBuild.value

    #expect(Self.bytesOfEachFile(build.store.fileSystem.reads).count == Self.fileCount)
  }

  @Test("a full build has at most 4 reads at one time")
  func aFullBuildHasAtMostFourReadsAtOneTime() async throws {
    let build = await Self.sharedBuild.value

    #expect(build.store.fileSystem.mostActiveReads <= ExternalSessionIndex.workerCount)
  }

  @Test("a full build reads no full file")
  func aFullBuildReadsNoFullFile() async throws {
    let build = await Self.sharedBuild.value

    #expect(build.store.fileSystem.reads.filter(\.isFull).isEmpty)
  }

  @Test("no read call of a full build reads more than 256 KB")
  func noReadOfAFullBuildIsLargerThan256KB() async throws {
    let build = await Self.sharedBuild.value

    let longest = build.store.fileSystem.reads.map(\.length).max() ?? 0

    #expect(longest <= Self.mostBytesOfARead, "\(longest) bytes")
  }

  @Test("a build after a load of the index file reads no file")
  func aBuildAfterALoadReadsNoFile() async throws {
    let build = await Self.sharedBuild.value
    let opensBefore = build.store.fileSystem.openCount
    let index = ExternalSessionIndex(
      fileSystem: build.store.fileSystem, indexFolder: FakeSessionStore.indexFolder,
      clock: ManualExternalSessionClock())

    await index.replaceRoots(build.store.roots)
    await index.waitUntilIdle()

    #expect(build.store.fileSystem.openCount == opensBefore)
  }

  @Test("a build after a load of the index file has each entry of the first build")
  func aBuildAfterALoadHasEachEntry() async throws {
    let build = await Self.sharedBuild.value
    let index = ExternalSessionIndex(
      fileSystem: build.store.fileSystem, indexFolder: FakeSessionStore.indexFolder,
      clock: ManualExternalSessionClock())

    await index.replaceRoots(build.store.roots)
    await index.waitUntilIdle()

    #expect(await index.indexState == build.index.indexState)
  }

  // MARK: - A second build

  @Test("a second build of a store with no change reads no file")
  func aSecondBuildWithNoChangeReadsNoFile() async throws {
    let store = FakeSessionStore.make(
      fileCount: Self.fileCount, projectCount: Self.projectCount, givesWatches: false)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await index.waitUntilIdle()
    let opensBefore = store.fileSystem.openCount
    let directoryReadsBefore = store.fileSystem.directoryReadCount
    try #require(opensBefore == Self.fileCount)

    store.clock.advance(by: ExternalSessionIndex.findInterval)
    _ = try await index.externalSessions(ExternalSessionQuery(limit: Self.pageLimit))
    await index.waitUntilIdle()

    try #require(store.fileSystem.directoryReadCount > directoryReadsBefore)
    #expect(store.fileSystem.openCount == opensBefore)
  }

  // MARK: - The stops

  // These tests check what the index does, not a time: a time limit fails on a loaded
  // machine and proves nothing about the index.

  @Test("a query answers while the build runs, and does not wait for it")
  func aQueryAnswersWhileTheBuildRuns() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilRead(index, atLeast: Self.filesReadBeforeTheQuery)
    let query = ExternalSessionQuery(folder: store.folder(ofProject: Self.queriedProject), limit: Self.pageLimit)

    let page = try await index.externalSessions(query)

    #expect(page.indexState.isComplete == false)
    await index.replaceRoots([:])
    await index.waitUntilIdle()
  }

  @Test("a cancelled follow moves the files of its folder to level 2")
  func aCancelledFollowMovesItsFilesToLevelTwo() async throws {
    let store = FakeSessionStore.make(
      fileCount: Self.fileCount, projectCount: Self.projectCount,
      firstProjectFileCount: Self.largeProjectFileCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilFound(index, atLeast: Self.fileCount)
    let (followStarted, start) = AsyncStream.makeStream(of: Void.self)
    let follow = Task {
      try await index.whileFollowing(folder: store.folder(ofProject: 0)) {
        start.yield()
        try await ExternalSessionIndexWaits.untilCancelled()
      }
    }
    for await _ in followStarted { break }
    try #require(await index.queuedCounts.folder > 0)

    follow.cancel()
    _ = await follow.result

    let folderCount = await index.queuedCounts.folder
    #expect(folderCount == 0, "\(folderCount) files at level 1")
    await index.replaceRoots([:])
    await index.waitUntilIdle()
  }

  @Test("a cancelled query moves the files of its folder to level 2")
  func aCancelledQueryMovesItsFilesToLevelTwo() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilFound(index, atLeast: Self.fileCount)
    let query = ExternalSessionQuery(folder: store.folder(ofProject: Self.queriedProject), limit: Self.pageLimit)

    let isCancelled = await Task {
      // The task cancels itself, so the query runs in a cancelled task.
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try await index.externalSessions(query)
        return false
      } catch {
        return error is CancellationError
      }
    }.value

    let folderCount = await index.queuedCounts.folder
    #expect(folderCount == 0 && isCancelled, "\(folderCount) files at level 1, cancelled: \(isCancelled)")
    await index.replaceRoots([:])
    await index.waitUntilIdle()
  }

  @Test("a cancelled list of the rows of a folder moves the files of that folder to level 2")
  func aCancelledListMovesItsFilesToLevelTwo() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilFound(index, atLeast: Self.fileCount)
    let folder = store.folder(ofProject: Self.queriedProject)

    let isCancelled = await Task {
      // The task cancels itself, so the list runs in a cancelled task.
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try await index.sessions(of: [.claudeCode], folder: folder, automated: false)
        return false
      } catch {
        return error is CancellationError
      }
    }.value

    let folderCount = await index.queuedCounts.folder
    #expect(folderCount == 0 && isCancelled, "\(folderCount) files at level 1, cancelled: \(isCancelled)")
    await index.replaceRoots([:])
    await index.waitUntilIdle()
  }

  @Test("a stop right after the roots leaves no read after it")
  func aStopLeavesNoRead() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)

    await index.stop()
    let opensAtTheStop = store.fileSystem.openCount
    await index.waitUntilIdle()

    #expect(store.fileSystem.openCount == opensAtTheStop)
  }

  @Test("a stop during a build writes each entry that the index read")
  func aStopWritesTheReadEntries() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilRead(index, atLeast: Self.filesReadBeforeTheRemoval)

    await index.stop()

    let data = try #require(store.fileSystem.agentFile(at: FakeSessionStore.indexFile))
    let entries = try #require(
      ExternalSessionIndexFile.entries(in: data, of: .claudeCode, root: FakeSessionStore.root))
    let written = entries.values.filter { $0.summary.state != .found }.count
    #expect(written == (await index.indexState).filesRead)
  }

  /// A worker checks for a cancel before each file. Thus after the removal, each worker opens
  /// at most the one file that it took before the removal.
  @Test("a removed root stops all reads")
  func aRemovedRootStopsAllReads() async throws {
    let store = FakeSessionStore.make(fileCount: Self.fileCount, projectCount: Self.projectCount)
    let index = store.makeIndex()
    await index.replaceRoots(store.roots)
    await ExternalSessionIndexWaits.untilRead(index, atLeast: Self.filesReadBeforeTheRemoval)

    await index.replaceRoots([:])
    let openedAtTheRemoval = store.fileSystem.openCount
    await index.waitUntilIdle()

    let openedAfter = store.fileSystem.openCount - openedAtTheRemoval
    #expect(openedAfter <= ExternalSessionIndex.workerCount, "\(openedAfter) files opened after the removal")
  }
}
