import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// One column of a board record.
public struct BoardColumnSummary: Sendable, Equatable, Codable {
  /// The id of the column.
  public let id: String

  /// The name of the column.
  public let name: String

  /// The number of tasks in the column.
  public let taskCount: Int

  /// Makes a column summary.
  ///
  /// - Parameters:
  ///   - id: The id of the column.
  ///   - name: The name of the column.
  ///   - taskCount: The number of tasks in the column.
  public init(id: String, name: String, taskCount: Int) {
    self.id = id
    self.name = name
    self.taskCount = taskCount
  }
}

/// The record of the board of one folder (D214, part 3): the folder, and the columns in their
/// order with the count of tasks in each.
public struct BoardContentRecord: Sendable, Equatable, Codable, Identifiable {
  /// The folder of the board.
  public let folder: URL

  /// The columns, in their order.
  public let columns: [BoardColumnSummary]

  /// The id: the folder.
  public var id: URL { folder }

  /// Makes a board record.
  ///
  /// - Parameters:
  ///   - folder: The folder of the board.
  ///   - columns: The columns, in their order.
  public init(folder: URL, columns: [BoardColumnSummary]) {
    self.folder = folder
    self.columns = columns
  }
}

/// The id of one task record: the folder of its board and the id of the task.
public struct TaskContentID: Sendable, Hashable, Codable {
  /// The folder of the board.
  public let folder: URL

  /// The id of the task in the board.
  public let taskID: String

  /// Makes an id.
  ///
  /// - Parameters:
  ///   - folder: The folder of the board.
  ///   - taskID: The id of the task.
  public init(folder: URL, taskID: String) {
    self.folder = folder
    self.taskID = taskID
  }
}

/// One task that a task depends on.
public struct TaskDependency: Sendable, Equatable, Codable {
  /// The id of the task, or the URI text of a task of another board.
  public let id: String

  /// The title of the task, or `nil` when the board does not hold it.
  public let title: String?

  /// Makes a dependency.
  ///
  /// - Parameters:
  ///   - id: The id or the URI text of the task.
  ///   - title: The title, or `nil`.
  public init(id: String, title: String?) {
    self.id = id
    self.title = title
  }
}

/// The record of one task for the content catalog of a host (D214, part 3).
public struct TaskContentRecord: Sendable, Equatable, Codable, Identifiable {
  /// The id: the folder and the id of the task.
  public let id: TaskContentID

  /// The short id of the task.
  public let shortID: String

  /// The title.
  public let title: String

  /// The description.
  public let description: String

  /// The id of the column of the task.
  public let columnID: String

  /// The name of the column of the task.
  public let columnName: String

  /// The tags, sorted.
  public let tags: [String]

  /// The names of the assignees.
  public let assignees: [String]

  /// The tasks that the task depends on.
  public let dependsOn: [TaskDependency]

  /// The text of each comment, in order.
  public let comments: [String]

  /// The date of the creation.
  public let created: Date

  /// The date of the last change.
  public let updated: Date

  /// True when the task is done.
  public let isDone: Bool

  /// Makes a task record.
  public init(
    id: TaskContentID, shortID: String, title: String, description: String, columnID: String,
    columnName: String, tags: [String], assignees: [String], dependsOn: [TaskDependency],
    comments: [String], created: Date, updated: Date, isDone: Bool
  ) {
    self.id = id
    self.shortID = shortID
    self.title = title
    self.description = description
    self.columnID = columnID
    self.columnName = columnName
    self.tags = tags
    self.assignees = assignees
    self.dependsOn = dependsOn
    self.comments = comments
    self.created = created
    self.updated = updated
    self.isDone = isDone
  }
}

/// The board of one folder, as a source reads it.
public struct BoardContent: Sendable, Equatable {
  /// The record of the board.
  public let board: BoardContentRecord

  /// The records of the tasks.
  public let tasks: [TaskContentRecord]

  /// Makes a board content.
  ///
  /// - Parameters:
  ///   - board: The record of the board.
  ///   - tasks: The records of the tasks.
  public init(board: BoardContentRecord, tasks: [TaskContentRecord]) {
    self.board = board
    self.tasks = tasks
  }
}

/// One change of the board of one folder, as a source gives it.
public enum BoardSourceChange: Sendable, Equatable {
  /// These tasks are new or changed.
  case tasksChanged(Set<String>)

  /// These tasks went away.
  case tasksRemoved(Set<String>)

  /// The board changed: a column, a tag, an actor or the board itself.
  case boardChanged

  /// The board went away.
  case boardRemoved
}

/// The source of the boards of the folders (D214, part 3). The library does not link
/// FoundationModelsKanban, so a host gives the source: an adapter over `KanbanHost`
/// (`readBoard(inFolder:)`, `boardStamp(ofFolder:)`, `boardChanges(inFolder:)`). The source only
/// reads; its change stream can write the merge of an iCloud conflict, as `KanbanHost` does.
public protocol BoardContentSource: Sendable {
  /// The stamp of the board of a folder, or `nil` when the folder has no board. The read opens
  /// no log.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The stamp, or `nil`.
  func stamp(ofFolder folder: URL) -> ContentStamp?

  /// The board of a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The board, or `nil` when the folder has no board.
  /// - Throws: The error of the read, for example a board of an older format.
  func board(inFolder folder: URL) async throws -> BoardContent?

  /// A stream of the changes of the board of a folder. The stream ends when the task that reads
  /// it is cancelled.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The stream.
  /// - Throws: The error of the start of the watch.
  func changes(inFolder folder: URL) async throws -> AsyncStream<BoardSourceChange>
}

/// The boards part of the content catalog (D214, part 3). A domain is the board of one known
/// folder: the folder of a session of the session directory that the `readableFolder` rule
/// permits. Its records are the tasks; ``board(of:)`` gives the record of the board.
///
/// With no source (``RoutedACPAgent/useBoardContentSource(_:)``), the part has no domain.
public struct BoardContentCatalog: Sendable {
  /// The session directory, for the known folders.
  private let directory: any SessionDirectory

  /// Tells whether the process can read a folder now with no prompt.
  private let readableFolder: @Sendable (URL) -> Bool

  /// The source of the boards, or `nil`.
  private let source: (any BoardContentSource)?

  /// The stamp of each folder that a read of this part gave, for the catch-up of a new watch.
  private let given: BoardGivenStamps

  /// Makes the part.
  ///
  /// - Parameters:
  ///   - directory: The session directory.
  ///   - readableFolder: The folder rule of the host.
  ///   - source: The source of the boards, or `nil`.
  ///   - given: The stamps that the reads gave. Each part of one agent uses the same value.
  init(
    directory: any SessionDirectory, readableFolder: @escaping @Sendable (URL) -> Bool,
    source: (any BoardContentSource)?, given: BoardGivenStamps = BoardGivenStamps()
  ) {
    self.directory = directory
    self.readableFolder = readableFolder
    self.source = source
    self.given = given
  }

  /// The stamp of the board of each known folder that has a board.
  ///
  /// - Returns: The stamp of each folder.
  /// - Throws: The error of the session directory.
  public func stamps() async throws -> [URL: ContentStamp] {
    guard let source else { return [:] }
    var stamps: [URL: ContentStamp] = [:]
    for folder in try await knownFolders() {
      let stamp = source.stamp(ofFolder: folder)
      given.record(stamp, for: folder)
      stamps[folder] = stamp
    }
    return stamps
  }

  /// The records of the tasks of the board of a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The tasks, in the order of their ids, or none for a folder with no board or a
  ///   folder that the rule refuses.
  /// - Throws: The error of the read of the board.
  public func records(of folder: URL) async throws -> [TaskContentRecord] {
    try await content(of: folder)?.tasks.sorted { $0.id.taskID < $1.id.taskID } ?? []
  }

  /// The record of the board of a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The record, or `nil` for a folder with no board or a folder that the rule refuses.
  /// - Throws: The error of the read of the board.
  public func board(of folder: URL) async throws -> BoardContentRecord? {
    try await content(of: folder)?.board
  }

  /// The record of one task.
  ///
  /// - Parameter id: The id of the task.
  /// - Returns: The record, or `nil` when the board has no such task.
  /// - Throws: The error of the read of the board.
  public func record(_ id: TaskContentID) async throws -> TaskContentRecord? {
    try await records(of: id.folder).first { $0.id == id }
  }

  /// Makes a new stream of the changes of the boards of the known folders: the folders known at
  /// the call, and the folder of each session that starts later. Each call gives a new stream of
  /// its own.
  ///
  /// - Changed tasks give `changed` with their records.
  /// - Removed tasks give `removed` with their ids.
  /// - A change of the board gives `changed` with each task.
  /// - A removed board gives `domainRemoved`.
  ///
  /// The stream holds the newest changes that its subscriber did not read, and it drops the
  /// oldest ones. It ends when the subscriber stops it.
  ///
  /// - Returns: The stream of the changes after this call.
  public func changes() -> AsyncStream<ContentCatalogChange<URL, TaskContentRecord>> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ContentCatalogChange<URL, TaskContentRecord>.self,
      bufferingPolicy: .bufferingNewest(SubscriberFeed<ULID>.defaultBufferLimit))
    guard source != nil else {
      continuation.finish()
      return stream
    }
    let events = directory.events()
    let part = self
    let task = Task {
      await withTaskGroup(of: Void.self) { group in
        var watched: Set<URL> = []
        func follow(_ folder: URL) {
          guard watched.insert(folder).inserted else { return }
          group.addTask { await part.follow(folder, into: continuation) }
        }
        for folder in (try? await part.knownFolders()) ?? [] {
          follow(folder)
        }
        for await event in events {
          guard case .started(let summary, _) = event else { continue }
          let folder = summary.workingDirectory.standardizedFileURL
          if part.readableFolder(folder) {
            follow(folder)
          }
        }
        group.cancelAll()
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  // MARK: - The reads

  /// The working folder of each session of the directory that the rule permits, sorted.
  ///
  /// - Returns: The folders.
  /// - Throws: The error of the session directory.
  private func knownFolders() async throws -> [URL] {
    let summaries = try await directory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    return Set(summaries.map { $0.workingDirectory.standardizedFileURL })
      .filter(readableFolder)
      .sorted { $0.path < $1.path }
  }

  /// The board of a folder that the rule permits.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The board, or `nil`.
  /// - Throws: The error of the read of the board.
  private func content(of folder: URL) async throws -> BoardContent? {
    guard let source, readableFolder(folder) else { return nil }
    let folder = folder.standardizedFileURL
    // The stamp before the read: a board that changes during the read gives one more change of
    // the catch-up, never one less.
    given.record(source.stamp(ofFolder: folder), for: folder)
    return try await source.board(inFolder: folder)
  }

  /// Follows the changes of the board of one folder, and yields each change of the catalog.
  ///
  /// - Parameters:
  ///   - folder: The folder.
  ///   - continuation: The continuation of the stream of the catalog.
  private func follow(
    _ folder: URL, into continuation: AsyncStream<ContentCatalogChange<URL, TaskContentRecord>>.Continuation
  ) async {
    guard let source, let changes = try? await source.changes(inFolder: folder) else { return }
    // The watch starts after the call of `changes()`. A change of the board before the watch
    // started gives no event, so compare the stamp now with the stamp that a read gave.
    if case .some(let seen) = given.stamp(of: folder) {
      let now = source.stamp(ofFolder: folder)
      if now != seen {
        if now == nil {
          continuation.yield(.domainRemoved(folder))
        } else {
          continuation.yield(.changed(folder, (try? await records(of: folder)) ?? []))
        }
      }
    }
    for await change in changes {
      switch change {
      case .tasksChanged(let ids):
        let records = ((try? await records(of: folder)) ?? []).filter { ids.contains($0.id.taskID) }
        if !records.isEmpty {
          continuation.yield(.changed(folder, records))
        }
      case .tasksRemoved(let ids):
        continuation.yield(
          .removed(folder, ids.sorted().map { TaskContentID(folder: folder, taskID: $0) }))
      case .boardChanged:
        continuation.yield(.changed(folder, (try? await records(of: folder)) ?? []))
      case .boardRemoved:
        continuation.yield(.domainRemoved(folder))
      }
    }
  }
}

/// The stamp of the board of each folder that a read of the boards part gave. A new watch of a
/// folder compares it with the stamp now, so that a change before the watch started is not lost.
final class BoardGivenStamps: Sendable {
  /// The stamp of each folder that a read gave: `nil` for a folder with no board.
  private let stamps = Mutex<[URL: ContentStamp?]>([:])

  /// Records the stamp that a read gave.
  ///
  /// - Parameters:
  ///   - stamp: The stamp, or `nil` for no board.
  ///   - folder: The folder.
  func record(_ stamp: ContentStamp?, for folder: URL) {
    stamps.withLock { $0[folder.standardizedFileURL] = .some(stamp) }
  }

  /// The stamp that a read gave for a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: `nil` when no read gave a stamp; `.some(nil)` when a read found no board.
  func stamp(of folder: URL) -> ContentStamp?? {
    stamps.withLock { $0[folder.standardizedFileURL] }
  }
}

/// The source of the boards that a host gives to the agent.
final class BoardContentSourceHolder: Sendable {
  /// The source, or `nil`.
  private let held = Mutex<(any BoardContentSource)?>(nil)

  /// The stamps that the reads of the boards part gave.
  let given = BoardGivenStamps()

  /// The source now.
  var source: (any BoardContentSource)? {
    held.withLock { $0 }
  }

  /// Replaces the source.
  ///
  /// - Parameter source: The new source, or `nil`.
  func use(_ source: (any BoardContentSource)?) {
    held.withLock { $0 = source }
  }
}

extension RoutedACPAgent {
  /// Gives the source of the boards of the folders to the boards part of the content catalog
  /// (D214, part 3). The library does not link FoundationModelsKanban, so the host gives an
  /// adapter over `KanbanHost`. With no source, the boards part has no domain.
  ///
  /// - Parameter source: The source, or `nil`.
  public nonisolated func useBoardContentSource(_ source: (any BoardContentSource)?) {
    boardContentSource.use(source)
  }
}
