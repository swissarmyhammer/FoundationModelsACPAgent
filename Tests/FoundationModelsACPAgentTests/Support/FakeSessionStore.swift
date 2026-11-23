import ACPImport
import Foundation
import FoundationModelsExtras

@testable import FoundationModelsACPAgent

/// A Claude Code store on a ``FakeExternalSessionFileSystem`` (D212, section 7): session files
/// in project folders, with sizes from 100 KB to 60 MB, and 93 of each 100 automated.
///
/// File `n` is in project `n % projectCount` (after the files of a large first project, when
/// the store has one), its working folder is `/work/project-<project>`, and its date is `n`
/// seconds before the newest date. Of each 100 files, 93 are automated, 4 are typed and 3 have
/// no `entrypoint`. Each 50th file of 300 KB or more has no working folder in its tail.
struct FakeSessionStore: Sendable {
  /// The Claude Code root of the store.
  static let root = URL(fileURLWithPath: "/fake/home/.claude", isDirectory: true)

  /// The folder of the index files of the agent.
  static let indexFolder = URL(fileURLWithPath: "/fake/local/external-sessions", isDirectory: true)

  /// The sizes of the files, in turn: from 100 KB to 60 MB.
  private static let sizes: [Int64] = [
    102_400, 307_200, 499_712, 788_480, 1_090_000, 4_600_000, 62_914_560,
  ]

  /// The date of file 0, the newest file.
  private static let newestDate = Date(timeIntervalSince1970: 1_795_000_000)

  /// The share of the automated files, of each 100.
  private static let automatedShare = 93

  /// The share of the typed files, of each 100, after the automated files.
  private static let typedShare = 4

  /// The number of files in a cycle of the kinds.
  private static let kindCycle = 100

  /// Each file whose number has this remainder by ``missingTailFolderCycle`` has no working
  /// folder in its tail.
  private static let missingTailFolderCycle = 50

  /// The smallest size of a file with no working folder in its tail.
  private static let missingTailFolderMinimumSize: Int64 = 300_000

  /// The file system of the store.
  let fileSystem: FakeExternalSessionFileSystem

  /// The clock of the index of the store.
  let clock = ManualExternalSessionClock()

  /// The number of files.
  let fileCount: Int

  /// The number of project folders.
  let projectCount: Int

  /// The number of files of project 0 before the other files, or 0.
  let firstProjectFileCount: Int

  /// The roots of the index: the Claude Code root.
  var roots: [ImportSourceAgent: URL] { [.claudeCode: Self.root] }

  /// The index file of Claude Code.
  static var indexFile: URL { ExternalSessionIndexFile.file(of: .claudeCode, in: indexFolder) }

  /// Makes a store.
  ///
  /// - Parameters:
  ///   - fileCount: The number of files.
  ///   - projectCount: The number of project folders.
  ///   - firstProjectFileCount: The number of files of project 0 before the other files, or 0.
  ///   - givesWatches: True when the file system gives a watch.
  /// - Returns: The store.
  static func make(
    fileCount: Int, projectCount: Int, firstProjectFileCount: Int = 0, givesWatches: Bool = true
  ) -> FakeSessionStore {
    let store = FakeSessionStore(
      fileSystem: FakeExternalSessionFileSystem(givesWatches: givesWatches), fileCount: fileCount,
      projectCount: projectCount, firstProjectFileCount: firstProjectFileCount)
    for number in 0..<fileCount {
      store.fileSystem.add(store.file(number), at: store.url(of: number))
    }
    return store
  }

  /// Makes an index over the store.
  ///
  /// - Returns: The index. It has no root.
  func makeIndex() -> ExternalSessionIndex {
    ExternalSessionIndex(fileSystem: fileSystem, indexFolder: Self.indexFolder, clock: clock)
  }

  /// The project of a file.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The project.
  func project(of number: Int) -> Int {
    guard number >= firstProjectFileCount else { return 0 }
    let others = max(projectCount - (firstProjectFileCount > 0 ? 1 : 0), 1)
    return (firstProjectFileCount > 0 ? 1 : 0) + number % others
  }

  /// The working folder of a project.
  ///
  /// - Parameter project: The project.
  /// - Returns: The folder.
  func folder(ofProject project: Int) -> URL {
    URL(fileURLWithPath: "/work/project-\(project)", isDirectory: true)
  }

  /// The id of a file.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The id.
  func id(of number: Int) -> String {
    String(format: "%08x-0000-4000-8000-%012x", number, number)
  }

  /// The URL of a file.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The URL.
  func url(of number: Int) -> URL {
    let project = ImportSourceAgent.projectKey(of: folder(ofProject: project(of: number)))
    return Self.root.appendingPathComponent("projects/\(project)/\(id(of: number)).jsonl")
  }

  /// The path of a file relative to the root.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The path.
  func path(of number: Int) -> String {
    String(url(of: number).path.dropFirst(Self.root.path.count + 1))
  }

  /// The kind of a file.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The kind.
  func kind(of number: Int) -> FakeExternalSessionFileSystem.SessionKind {
    switch number % Self.kindCycle {
    case ..<Self.automatedShare: .automated
    case ..<(Self.automatedShare + Self.typedShare): .typed
    default: .noEntrypoint
    }
  }

  /// The file of a number, as the store first writes it.
  ///
  /// - Parameter number: The number of the file.
  /// - Returns: The file.
  func file(_ number: Int) -> FakeExternalSessionFileSystem.File {
    let size = Self.sizes[number % Self.sizes.count]
    return FakeExternalSessionFileSystem.File(
      id: id(of: number), cwd: folder(ofProject: project(of: number)).path, kind: kind(of: number),
      size: size, modified: Self.newestDate.addingTimeInterval(-TimeInterval(number)),
      hasTailFolder: number % Self.missingTailFolderCycle != 1
        || size < Self.missingTailFolderMinimumSize)
  }

  /// The numbers of the files of one kind.
  ///
  /// - Parameter kind: The kind.
  /// - Returns: The numbers.
  func numbers(of kind: FakeExternalSessionFileSystem.SessionKind) -> [Int] {
    (0..<fileCount).filter { self.kind(of: $0) == kind }
  }

  /// The first file of a kind whose size is larger than a size.
  ///
  /// - Parameters:
  ///   - kind: The kind.
  ///   - size: The size.
  /// - Returns: The number of the file.
  func firstFile(of kind: FakeExternalSessionFileSystem.SessionKind, largerThan size: Int64) -> Int? {
    numbers(of: kind).first { file($0).size > size }
  }

  /// The project of a path relative to the root, from its project folder.
  ///
  /// - Parameters:
  ///   - path: The path, relative to the root.
  ///   - project: The project.
  /// - Returns: True when the path is in the folder of the project.
  func isPath(_ path: String, ofProject project: Int) -> Bool {
    path.hasPrefix("projects/\(ImportSourceAgent.projectKey(of: folder(ofProject: project)))/")
  }
}

extension FakeSessionStore {
  /// The bytes of an index file whose entries are each file of the store in the state
  /// `found`: a load gives each entry, and no file is in the read queue before a find.
  ///
  /// - Returns: The bytes.
  func foundIndexFile() -> Data {
    let lines = (0..<fileCount).map { number in
      let file = file(number)
      let found = ExternalSessionFoundFile(
        path: path(of: number),
        projectKey: ImportSourceAgent.projectKey(of: folder(ofProject: project(of: number))),
        size: file.size, modified: file.modified)
      return ExternalSessionIndexEntry(summary: ExternalSessionScan.foundSummary(of: .claudeCode, file: found)).line
    }
    return ExternalSessionIndexFile.data(of: .claudeCode, root: Self.root, lines: lines)
  }

  /// The folder of the project folders of the root.
  static var projectsFolder: URL { root.appendingPathComponent("projects", isDirectory: true) }
}

/// The waits of the tests of the index, on its own streams. No wait uses a clock.
enum ExternalSessionIndexWaits {
  /// Waits until the index has read at least some files.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - count: The number of files.
  static func untilRead(_ index: ExternalSessionIndex, atLeast count: Int) async {
    for await change in index.externalSessionChanges(folder: nil)
    where change.indexState.filesRead >= count {
      return
    }
  }

  /// Waits until the index has found at least some files.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - count: The number of files.
  static func untilFound(_ index: ExternalSessionIndex, atLeast count: Int) async {
    for await change in index.externalSessionChanges(folder: nil)
    where change.indexState.filesFound >= count {
      return
    }
  }

  /// Waits until the index publishes the removal of a session.
  ///
  /// - Parameters:
  ///   - changes: The changes of the index, after their first element.
  ///   - id: The id of the session.
  static func untilRemoved(
    _ changes: inout AsyncStream<ExternalSessionChange>.Iterator, id: String
  ) async {
    while let change = await changes.next() {
      if change.removed.contains(where: { $0.sourceID == id }) { return }
    }
  }

  /// Waits until a stream of the index gives a state with at least some files read.
  ///
  /// - Parameters:
  ///   - changes: The changes of the index.
  ///   - count: The number of files.
  static func untilRead(_ changes: inout AsyncStream<ExternalSessionChange>.Iterator, atLeast count: Int) async {
    while let change = await changes.next() {
      if change.indexState.filesRead >= count { return }
    }
  }

  /// Suspends until the task is cancelled.
  ///
  /// - Throws: `CancellationError` after the cancellation.
  static func untilCancelled() async throws {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
    try Task.checkCancellation()
  }
}
