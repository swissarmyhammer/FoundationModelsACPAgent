import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Synchronization
import Testing
import ULID

@testable import FoundationModelsACPAgent
import FoundationModelsACPAgentKanban

/// The boards part of the content catalog (D214, part 3): the seam (``BoardContentSource``) with
/// a fake source, and the adapter over `KanbanHost` with a real board.
@Suite(.closesHarnesses) struct BoardContentCatalogTests {
  /// A source whose board and changes a test sets.
  final class FakeSource: BoardContentSource, Sendable {
    /// The board, or `nil`.
    let content = Mutex<BoardContent?>(nil)

    /// The continuation of the change stream, once it was asked for.
    let continuation = Mutex<AsyncStream<BoardSourceChange>.Continuation?>(nil)

    /// The stream of the changes, made at the init so that no change is lost.
    let stream: AsyncStream<BoardSourceChange>

    /// The gate of the start of a watch: ``changes(inFolder:)`` returns only after ``openGate()``.
    let gate: AsyncStream<Void>

    /// The continuation of ``gate``.
    let gateContinuation: AsyncStream<Void>.Continuation

    /// Makes the source.
    ///
    /// - Parameter gated: When `true`, a watch starts only after ``openGate()``.
    init(gated: Bool = false) {
      let (stream, continuation) = AsyncStream.makeStream(of: BoardSourceChange.self)
      self.stream = stream
      self.continuation.withLock { $0 = continuation }
      let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
      self.gate = gate
      self.gateContinuation = gateContinuation
      if !gated {
        gateContinuation.finish()
      }
    }

    /// Lets each watch start.
    func openGate() {
      gateContinuation.finish()
    }

    func stamp(ofFolder folder: URL) -> ContentStamp? {
      content.withLock { $0 }.map { ContentStamp.hashing($0.tasks.map(\.title)) }
    }

    func board(inFolder folder: URL) async throws -> BoardContent? {
      content.withLock { $0 }
    }

    func changes(inFolder folder: URL) async throws -> AsyncStream<BoardSourceChange> {
      for await _ in gate {}
      return stream
    }

    /// Sends a change.
    func send(_ change: BoardSourceChange) {
      continuation.withLock { $0 }?.yield(change)
    }
  }

  /// A task record of a folder.
  ///
  /// - Parameters:
  ///   - id: The id of the task.
  ///   - title: The title.
  ///   - folder: The folder.
  /// - Returns: The record.
  private static func task(_ id: String, title: String, in folder: URL) -> TaskContentRecord {
    TaskContentRecord(
      id: TaskContentID(folder: folder, taskID: id), shortID: String(id.prefix(7)), title: title,
      description: "", columnID: "todo", columnName: "To Do", tags: [], assignees: [],
      dependsOn: [], comments: [], created: Date(), updated: Date(), isDone: false)
  }

  /// A directory with one session in `folder`.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The directory.
  private static func directory(with folder: URL) -> InMemorySessionDirectory {
    let directory = InMemorySessionDirectory()
    directory.register(
      SessionSummary(
        id: ULID.generate(), agentID: "default", workingDirectory: folder, tags: [], kind: .root,
        state: .idle, origin: .client, createdAt: Date(), updatedAt: Date(), isLive: false))
    return directory
  }

  /// Reads the changes of `stream` until one satisfies `matches`.
  private static func firstChange(
    of stream: AsyncStream<ContentCatalogChange<URL, TaskContentRecord>>,
    where matches: (ContentCatalogChange<URL, TaskContentRecord>) -> Bool
  ) async -> ContentCatalogChange<URL, TaskContentRecord>? {
    for await change in stream where matches(change) {
      return change
    }
    return nil
  }

  // MARK: - The seam

  /// The part gives the tasks and the stamp of a known folder, and maps the changes of the
  /// source: changed tasks, removed tasks, and a removed board.
  @Test func thePartReadsAndMapsTheChangesOfTheSource() async throws {
    let folder = makeResolvedDirectory(label: "BoardContentCatalogTests-seam").standardizedFileURL
    let source = FakeSource()
    let first = Self.task("01AAAAAAAAAAAAAAAAAAAAAAAA", title: "Feed the zebra", in: folder)
    source.content.withLock {
      $0 = BoardContent(
        board: BoardContentRecord(
          folder: folder, columns: [BoardColumnSummary(id: "todo", name: "To Do", taskCount: 1)]),
        tasks: [first])
    }
    let part = BoardContentCatalog(
      directory: Self.directory(with: folder), readableFolder: { _ in true }, source: source)

    #expect(try await part.records(of: folder) == [first])
    #expect(try await part.board(of: folder)?.columns.first?.taskCount == 1)
    #expect(try await part.stamps()[folder] != nil)

    let changes = part.changes()
    source.send(.tasksChanged([first.id.taskID]))
    #expect(await Self.firstChange(of: changes) { $0 == .changed(folder, [first]) } != nil)
    source.send(.tasksRemoved([first.id.taskID]))
    #expect(await Self.firstChange(of: changes) { $0 == .removed(folder, [first.id]) } != nil)
    source.send(.boardRemoved)
    #expect(await Self.firstChange(of: changes) { $0 == .domainRemoved(folder) } != nil)
  }

  /// A change of a board that a reader read, after the call of `changes()` and before the watch
  /// started, gives a change with the records: the watch compares the stamps.
  @Test func aChangeBeforeTheWatchStartedGivesAChange() async throws {
    let folder = makeResolvedDirectory(label: "BoardContentCatalogTests-catch-up").standardizedFileURL
    let source = FakeSource(gated: true)
    let first = Self.task("01AAAAAAAAAAAAAAAAAAAAAAAA", title: "Feed the zebra", in: folder)
    let board = BoardContentRecord(folder: folder, columns: [])
    source.content.withLock { $0 = BoardContent(board: board, tasks: [first]) }
    let part = BoardContentCatalog(
      directory: Self.directory(with: folder), readableFolder: { _ in true }, source: source)
    #expect(try await part.records(of: folder) == [first])
    let changes = part.changes()

    let second = Self.task("01BBBBBBBBBBBBBBBBBBBBBBBB", title: "Feed the lion", in: folder)
    source.content.withLock { $0 = BoardContent(board: board, tasks: [first, second]) }
    source.openGate()

    #expect(await Self.firstChange(of: changes) { $0 == .changed(folder, [first, second]) } != nil)
  }

  /// A folder that the `readableFolder` rule refuses gives no record and no stamp.
  @Test func aFolderThatTheRuleRefusesGivesNoRecord() async throws {
    let folder = makeResolvedDirectory(label: "BoardContentCatalogTests-refused").standardizedFileURL
    let source = FakeSource()
    source.content.withLock {
      $0 = BoardContent(
        board: BoardContentRecord(folder: folder, columns: []),
        tasks: [Self.task("01AAAAAAAAAAAAAAAAAAAAAAAA", title: "Feed the zebra", in: folder)])
    }
    let part = BoardContentCatalog(
      directory: Self.directory(with: folder), readableFolder: { _ in false }, source: source)

    #expect(try await part.records(of: folder).isEmpty)
    #expect(try await part.stamps().isEmpty)
  }

  // MARK: - The adapter over KanbanHost

  /// A task that the kanban tool of a session adds gives a change with the task record to a
  /// reader with no session of its own; a delete gives the id of the task.
  @Test func theAdapterGivesTheTaskOfAWriteAndTheIdOfADelete() async throws {
    let fixture = try await KanbanFixture.make(label: "board-catalog", sessions: 1)
    let session = fixture.sessions[0]
    _ = try await fixture.modelWrite("Feed the zebra", in: session)
    let folder = fixture.folder.standardizedFileURL
    let source = KanbanBoardContentSource()
    let part = BoardContentCatalog(
      directory: fixture.agent.sessionDirectory, readableFolder: { _ in true }, source: source)
    #expect(try await part.records(of: folder).map(\.title) == ["Feed the zebra"])
    #expect(source.stamp(ofFolder: folder) != nil)
    let changes = part.changes()

    _ = try await fixture.modelWrite("Feed the lion", in: session)
    let added = await Self.firstChange(of: changes) {
      guard case .changed(folder, let records) = $0 else { return false }
      return records.contains { $0.title == "Feed the lion" }
    }
    #expect(added != nil)
    let lion = try #require(try await part.records(of: folder).first { $0.title == "Feed the lion" })

    _ = try await fixture.modelExecute(
      #"mutation { deleteTask(input: { id: "\#(lion.id.taskID)" }) { id } }"#, in: session)
    let removed = await Self.firstChange(of: changes) {
      guard case .removed(folder, let ids) = $0 else { return false }
      return ids.contains(lion.id)
    }
    #expect(removed != nil)
  }
}
