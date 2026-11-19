import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Synchronization
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The updates of the transcript search index (D207, ^en1kt61): the history of each write, the
/// changes of the session directory, and the reconcile at launch. The updates run off the turn,
/// in the order that they came.
@Suite struct TranscriptSearchUpdatesTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchUpdatesTests"

  /// The session that the tests index.
  private static let sessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// A second session.
  private static let otherSessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// The working folder of the sessions that the tests index.
  private static let folder = URL(fileURLWithPath: "/projects/zoo", isDirectory: true)

  /// A working folder that the process cannot read.
  private static let closedFolder = URL(fileURLWithPath: "/projects/closed", isDirectory: true)

  /// A working folder whose recording root holds a record that does not read.
  private static let badRecordFolder = URL(fileURLWithPath: "/projects/bad", isDirectory: true)

  /// The date of each summary.
  private static let summaryDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// The most polls of a wait for the index. The updates run with a low priority, so a full
  /// parallel test run can keep them back for many seconds.
  private static let pollLimit = 3600

  /// The time between two polls of a wait for the index.
  private static let pollInterval = Duration.milliseconds(25)

  /// The title of each session before a change.
  private static let firstTitle = "Zebra research"

  /// The title of a session after a change.
  private static let changedTitle = "Quokka research"

  /// The time that a slow read of a recording root takes. The reconcile at launch then puts its
  /// folder in the queue after a wait that does not wait for the reconcile.
  private static let slowRootRead = Duration.milliseconds(200)

  // MARK: - Fixtures

  /// A history of one user message and one agent message.
  ///
  /// - Parameter answer: The text of the agent message.
  /// - Returns: The history.
  private static func history(answer: String) -> SessionMergeEngine {
    SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "user-1"),
          content: .value([.text(TextContent(text: "Where do they live?"))]))),
      .agentMessageChunk(
        ContentChunk(
          content: .text(TextContent(text: answer)), messageId: MessageId(rawValue: "agent-1"))),
    ])
  }

  /// The summary of a session in the session directory.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - title: The title of the session.
  ///   - folder: The working folder of the session.
  /// - Returns: The summary.
  private static func summary(
    of session: SessionId, title: String, folder: URL = folder
  ) throws -> SessionSummary {
    SessionSummary(
      id: try session.ulid(), agentID: "default", workingDirectory: folder, title: title,
      tags: [], kind: .root, state: .idle, origin: .client, createdAt: summaryDate,
      updatedAt: summaryDate, isLive: true)
  }

  /// The items that the index holds for a session after its history and its summary.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - history: The history of the session.
  ///   - summary: The summary of the session.
  /// - Returns: The session item, then the chunk items.
  private static func expectedItems(
    of session: SessionId, history: SessionMergeEngine, summary: SessionSummary
  ) -> [TranscriptSearchItem] {
    [TranscriptSearchItem(session: session, metadata: TranscriptSessionMetadata(summary: summary))]
      + history.searchChunks.map { TranscriptSearchItem(chunk: $0, session: session) }
  }

  /// An empty index in a new folder.
  ///
  /// - Parameters:
  ///   - label: The label of the folder.
  ///   - readableFolder: Tells whether the process can read a folder now.
  /// - Returns: The index.
  private static func makeIndex(
    label: String, readableFolder: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) async -> TranscriptSearchIndex {
    let index = TranscriptSearchIndex(
      folder: makeResolvedDirectory(label: "\(Self.label)-\(label)"), embedder: nil,
      modelID: nil, readableFolder: readableFolder)
    await index.load()
    return index
  }

  /// Waits until a condition over the index holds, or until the poll limit.
  ///
  /// - Parameter condition: Tells whether the wait is over.
  /// - Throws: The cancel of the wait.
  private static func waitUntil(_ condition: () async -> Bool) async throws {
    try await pollUntil(limit: pollLimit, interval: pollInterval) { await condition() }
  }

  // MARK: - The history of a write

  /// The history of a write gives the session item and the chunk items of its session.
  @Test(.timeLimit(.minutes(3))) func aWrittenHistoryGivesTheItemsOfItsSession() async throws {
    let summary = try Self.summary(of: Self.sessionId, title: Self.firstTitle)
    let history = Self.history(answer: "The quokka lives on an island.")
    let index = await Self.makeIndex(label: "history")
    let updates = TranscriptSearchUpdates(index: index) { _ in summary }

    updates.indexHistory(history, of: Self.sessionId)
    try await Self.waitUntil { await !index.items(of: Self.sessionId).isEmpty }

    #expect(
      await index.items(of: Self.sessionId)
        == Self.expectedItems(of: Self.sessionId, history: history, summary: summary))
  }

  /// A summary that does not read is logged, and the next change goes on.
  @Test(.timeLimit(.minutes(3))) func aFailedSummaryReadLetsTheNextChangeGoOn() async throws {
    let summary = try Self.summary(of: Self.sessionId, title: Self.firstTitle)
    let failing = try Self.otherSessionId.ulid()
    let index = await Self.makeIndex(label: "failure")
    let updates = TranscriptSearchUpdates(index: index) { id in
      guard id != failing else {
        throw SessionDirectoryError.unknownSession(id)
      }
      return summary
    }

    updates.indexHistory(Self.history(answer: "No answer."), of: Self.otherSessionId)
    updates.indexHistory(Self.history(answer: "The quokka."), of: Self.sessionId)
    try await Self.waitUntil { await !index.items(of: Self.sessionId).isEmpty }

    #expect(await !index.items(of: Self.sessionId).isEmpty)
  }

  // MARK: - The changes of the session directory

  /// A `started` event of a session with a history in the session table gives its items with
  /// the facts of the event. A fork registers after the write of its copy.
  @Test(.timeLimit(.minutes(3))) func aStartedSessionWithAHistoryIsIndexed() async throws {
    let summary = try Self.summary(of: Self.sessionId, title: Self.firstTitle)
    let history = Self.history(answer: "The quokka lives on an island.")
    let index = await Self.makeIndex(label: "started")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }

    await updates.directoryEventArrived(
      .started(summary, requestedByClient: nil), liveHistory: { _ in history })
    try await Self.waitUntil { await !index.items(of: Self.sessionId).isEmpty }

    #expect(
      await index.items(of: Self.sessionId)
        == Self.expectedItems(of: Self.sessionId, history: history, summary: summary))
  }

  /// A rename gives the new session item, and the chunk items stay.
  @Test(.timeLimit(.minutes(3))) func aRenameChangesOnlyTheSessionItem() async throws {
    let summary = try Self.summary(of: Self.sessionId, title: Self.firstTitle)
    let renamed = try Self.summary(of: Self.sessionId, title: Self.changedTitle)
    let history = Self.history(answer: "The quokka lives on an island.")
    let index = await Self.makeIndex(label: "rename")
    let updates = TranscriptSearchUpdates(index: index) { _ in summary }
    updates.indexHistory(history, of: Self.sessionId)
    try await Self.waitUntil { await !index.items(of: Self.sessionId).isEmpty }

    await updates.directoryEventArrived(.factsChanged(renamed), liveHistory: { _ in nil })
    let expected = Self.expectedItems(of: Self.sessionId, history: history, summary: renamed)
    try await Self.waitUntil { await index.items(of: Self.sessionId) == expected }

    #expect(await index.items(of: Self.sessionId) == expected)
  }

  /// An archive gives the new session item that the directory reads, and the chunk items stay.
  @Test(.timeLimit(.minutes(3))) func anArchiveChangesOnlyTheSessionItem() async throws {
    let summary = try Self.summary(of: Self.sessionId, title: Self.firstTitle)
    let archived = try Self.summary(of: Self.sessionId, title: Self.changedTitle)
    let current = Mutex(summary)
    let history = Self.history(answer: "The quokka lives on an island.")
    let index = await Self.makeIndex(label: "archive")
    let updates = TranscriptSearchUpdates(index: index) { _ in current.withLock { $0 } }
    updates.indexHistory(history, of: Self.sessionId)
    try await Self.waitUntil { await !index.items(of: Self.sessionId).isEmpty }

    current.withLock { $0 = archived }
    await updates.directoryEventArrived(
      .archived(id: try Self.sessionId.ulid()), liveHistory: { _ in nil })
    let expected = Self.expectedItems(of: Self.sessionId, history: history, summary: archived)
    try await Self.waitUntil { await index.items(of: Self.sessionId) == expected }

    #expect(await index.items(of: Self.sessionId) == expected)
  }

  // MARK: - The reconcile

  /// The reconcile removes the items of a session of a read folder that has no history file.
  @Test(.timeLimit(.minutes(3))) func theReconcileRemovesASessionWithNoHistoryFile() async throws {
    let index = await Self.makeIndex(label: "reconcile-removed")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    let emptyRoot = makeResolvedDirectory(label: "\(Self.label)-reconcile-removed-root")
    await Self.indexStale(Self.sessionId, folder: Self.folder, in: index)

    await updates.reconcile(folders: [Self.folder], recordingRoot: { _ in emptyRoot })
    try await Self.waitUntil { await index.items(of: Self.sessionId).isEmpty }

    #expect(await index.items(of: Self.sessionId).isEmpty)
  }

  /// The wait for the applied changes waits for the reconcile at launch: the reconcile of a
  /// folder whose recording root reads slowly is applied when the wait returns.
  @Test(.timeLimit(.minutes(3))) func theWaitIncludesTheReconcileAtLaunch() async throws {
    let index = await Self.makeIndex(label: "launch-reconcile")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    let emptyRoot = makeResolvedDirectory(label: "\(Self.label)-launch-reconcile-root")
    await Self.indexStale(Self.sessionId, folder: Self.folder, in: index)

    updates.startReconcile(
      folders: { [Self.folder] },
      recordingRoot: { _ in
        try await Task.sleep(for: Self.slowRootRead)
        return emptyRoot
      })
    await updates.waitUntilApplied()

    #expect(await index.items(of: Self.sessionId).isEmpty)
  }

  /// The reconcile keeps the items of a session of a folder that the process cannot read.
  @Test(.timeLimit(.minutes(3))) func theReconcileKeepsTheItemsOfAClosedFolder() async throws {
    let index = await Self.makeIndex(label: "reconcile-closed") { $0 != Self.closedFolder }
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }

    _ = try await Self.reconcileClosedAndOpenFolders(with: updates)

    #expect(await !index.items(of: Self.otherSessionId).isEmpty)
  }

  /// The reconcile asks for no recording root of a folder that the process cannot read.
  @Test(.timeLimit(.minutes(3))) func theReconcileReadsNoRootOfAClosedFolder() async throws {
    let index = await Self.makeIndex(label: "reconcile-no-root") { $0 != Self.closedFolder }
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }

    let asked = try await Self.reconcileClosedAndOpenFolders(with: updates)

    #expect(asked == [Self.folder])
  }

  /// The reconcile keeps the items of a session whose record (`index.md`) does not read
  /// (D207, ^pqweam5).
  @Test(.timeLimit(.minutes(3))) func theReconcileKeepsTheItemsOfAnUnreadableRecord() async throws {
    let index = await Self.makeIndex(label: "reconcile-bad-record")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    let badRoot = try Self.rootWithUnreadableRecord(of: Self.otherSessionId)
    let emptyRoot = makeResolvedDirectory(label: "\(Self.label)-reconcile-bad-record-empty")
    await Self.indexStale(Self.otherSessionId, folder: Self.badRecordFolder, in: index)
    await Self.indexStale(Self.sessionId, folder: Self.folder, in: index)
    let stale = await index.items(of: Self.otherSessionId)

    await updates.reconcile(folders: [Self.badRecordFolder, Self.folder]) { folder in
      folder == Self.badRecordFolder ? badRoot : emptyRoot
    }
    try await Self.waitUntil { await index.items(of: Self.sessionId).isEmpty }

    #expect(await index.items(of: Self.otherSessionId) == stale)
  }

  /// A recording root with one session folder whose record (`index.md`) holds no frontmatter.
  ///
  /// - Parameter session: The session of the folder.
  /// - Returns: The recording root.
  /// - Throws: The error of the write.
  private static func rootWithUnreadableRecord(of session: SessionId) throws -> URL {
    let root = makeResolvedDirectory(label: "\(label)-reconcile-bad-record-root")
    let sessionFolder = root.appendingPathComponent(session.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
    try "This record holds no frontmatter.".write(
      to: sessionFolder.appendingPathComponent(RecordedSessionIndexFile.fileName),
      atomically: true, encoding: .utf8)
    return root
  }

  /// Indexes a session with stale content: one chunk that no history file holds.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - folder: The working folder of the session.
  ///   - index: The index.
  private static func indexStale(_ session: SessionId, folder: URL, in index: TranscriptSearchIndex)
    async
  {
    await index.index(
      session: session, chunks: history(answer: "A stale answer.").searchChunks,
      metadata: TranscriptSessionMetadata(
        name: firstTitle, slug: "zebra-research", tags: [], folder: folder, agentName: nil,
        recap: nil, lastSummary: nil))
  }

  /// Reconciles a folder that the process cannot read and a folder with an empty root. The
  /// index of `updates` holds ``otherSessionId`` in the closed folder and ``sessionId`` in the
  /// open folder. The call returns after the reconcile removed ``sessionId``, so the work of
  /// the closed folder is over too.
  ///
  /// - Parameter updates: The updates. Its index reads ``closedFolder`` as closed.
  /// - Returns: The folders whose recording root the reconcile asked for, in order.
  /// - Throws: The cancel of the wait.
  private static func reconcileClosedAndOpenFolders(with updates: TranscriptSearchUpdates)
    async throws -> [URL]
  {
    let index = updates.index
    let emptyRoot = makeResolvedDirectory(label: "\(label)-reconcile-open-root")
    let asked = Mutex<[URL]>([])
    await indexStale(otherSessionId, folder: closedFolder, in: index)
    await indexStale(sessionId, folder: folder, in: index)

    await updates.reconcile(folders: [closedFolder, folder]) { folder in
      asked.withLock { $0.append(folder) }
      return emptyRoot
    }
    try await waitUntil { await index.items(of: sessionId).isEmpty }
    return asked.withLock { $0 }
  }
}
