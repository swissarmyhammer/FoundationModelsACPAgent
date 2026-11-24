import Foundation
import FoundationModelsACPAgent
import FoundationModelsKanban

/// The source of the boards of the content catalog (D214, part 3) over the shared `KanbanHost`
/// of the process: the read, the stamp and the change stream of the board of a folder with no
/// session. A host gives it to `useBoardContentSource(_:)`. The read and the stamp never write. The change stream writes only when it merges an
/// iCloud conflict version of a log, as `KanbanHost.boardChanges(inFolder:)` does.
public struct KanbanBoardContentSource: BoardContentSource {
  /// The host of the boards.
  public let host: KanbanHost

  /// Makes the source over the shared host of the process.
  public init(host: KanbanHost = .shared) {
    self.host = host
  }

  /// The stamp of the board of a folder: the stamp of `KanbanHost`, or `nil` for no board.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The stamp, or `nil`.
  public func stamp(ofFolder folder: URL) -> ContentStamp? {
    host.boardStamp(ofFolder: folder).map { ContentStamp(value: $0.value) }
  }

  /// The board of a folder, with the records of the board and of each task.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The board, or `nil` when the folder has no board.
  /// - Throws: The error of the read, for example `KanbanError.incompatibleBoard`.
  public func board(inFolder folder: URL) async throws -> BoardContent? {
    guard case .board(let snapshot) = try await host.readBoard(inFolder: folder) else {
      return nil
    }
    return Self.content(of: snapshot, in: folder)
  }

  /// The changes of the board of a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The stream. It ends when the task that reads it is cancelled.
  /// - Throws: The error of the start of the watch.
  public func changes(inFolder folder: URL) async throws -> AsyncStream<BoardSourceChange> {
    let changes = try await host.boardChanges(inFolder: folder)
    let (stream, continuation) = AsyncStream.makeStream(of: BoardSourceChange.self)
    let task = Task {
      for await change in changes {
        switch change.kind {
        case .tasksChanged(let ids): continuation.yield(.tasksChanged(ids))
        case .tasksRemoved(let ids): continuation.yield(.tasksRemoved(ids))
        case .boardChanged: continuation.yield(.boardChanged)
        case .boardRemoved: continuation.yield(.boardRemoved)
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// The neutral records of a snapshot of a board.
  ///
  /// - Parameters:
  ///   - snapshot: The snapshot.
  ///   - folder: The folder of the board.
  /// - Returns: The board and its tasks.
  static func content(of snapshot: BoardSnapshot, in folder: URL) -> BoardContent {
    let columns = snapshot.columns.sorted { $0.order < $1.order }
    let names = Dictionary(columns.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let titles = Dictionary(
      snapshot.tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    let board = BoardContentRecord(
      folder: folder,
      columns: columns.map { column in
        BoardColumnSummary(
          id: column.id, name: column.name,
          taskCount: snapshot.tasks.filter { $0.column == column.id }.count)
      })
    let tasks = snapshot.tasks.map { task in
      TaskContentRecord(
        id: TaskContentID(folder: folder, taskID: task.id), shortID: task.shortID,
        title: task.title, description: task.description, columnID: task.column ?? "",
        columnName: task.column.flatMap { names[$0] } ?? "", tags: task.tags.sorted(),
        assignees: task.assignees.map(\.name),
        dependsOn: task.dependsOn.map { TaskDependency(id: $0, title: titles[$0]) },
        comments: task.comments.map(\.text), created: task.created, updated: task.updated,
        isDone: task.isDone)
    }
    return BoardContent(board: board, tasks: tasks)
  }
}
