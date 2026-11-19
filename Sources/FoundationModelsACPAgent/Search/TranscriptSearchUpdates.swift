import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// Keeps the transcript search index of the agent current (D207, ^en1kt61).
///
/// The agent gives each change to this object with no wait, and the object applies the changes
/// to the index (``TranscriptSearchIndex``) in a task of its own, one after the other:
///
/// - **A history write.** After each write of a history file (the end of a prompt, of a mail
///   turn and of `session/close`, and the copy of a fork), the agent gives the history. The
///   object makes its chunks and gives the chunk items and the session item of that session.
/// - **A change of the session directory.** A rename, the tags and the recap (`factsChanged`),
///   an archive and an unarchive give the new session item only. The `started` event of a
///   session that has a history in the session table gives its history, so a fork that the
///   directory registers after the write of its copy is indexed with its live facts.
/// - **A delete.** The agent gives each session of the deleted folder, and the object removes
///   their items.
/// - **The reconcile at launch** (``startReconcile(folders:recordingRoot:)``).
///
/// One task applies the changes in the order that they came. Thus a later turn of a session
/// never comes before an earlier one, and a reconcile, which reads the files when its turn
/// comes, never overwrites a newer turn. A failure is logged with ``ACPAgentTelemetry``, and
/// the next change goes on. The turn never waits for the index.
final class TranscriptSearchUpdates: Sendable {
  /// Reads the summary of a session in the session directory, or `nil` when the directory does
  /// not know the session.
  typealias SummaryReader = @Sendable (ULID) async throws -> SessionSummary?

  /// Gives the retained history of a session that the session table holds, or `nil` when the
  /// table does not hold it or holds no transcript entry for it.
  typealias LiveHistory = @Sendable (SessionId) async -> SessionMergeEngine?

  /// Gives the recording root of the sessions of a working folder.
  typealias RecordingRootReader = @Sendable (URL) async throws -> URL

  /// Gives the working folders of the project store.
  typealias FolderReader = @Sendable () throws -> [URL]

  /// One change of the index, in the queue of the task that applies the changes.
  enum Change: Sendable {
    /// The history of a session after a write. The summary is the summary of the event that
    /// gave it, or `nil` to read it from the session directory.
    case history(SessionId, SessionMergeEngine, summary: SessionSummary?)

    /// The new facts of a session of the session directory.
    case facts(SessionSummary)

    /// The facts of a session changed: read them from the session directory.
    case factsOfSession(ULID)

    /// The sessions of a deleted session folder.
    case removal(Set<SessionId>)

    /// The reconcile of one working folder that the process can read.
    case reconcile(TranscriptSearchFolder)

    /// A mark in the queue: the applier resumes the wait when it comes to the mark, so each
    /// change before the mark is applied (``waitUntilApplied()``).
    case mark(CheckedContinuation<Void, Never>)
  }

  /// The index that the object keeps current.
  let index: TranscriptSearchIndex

  /// Applies each change to the index.
  private let applier: TranscriptSearchApplier

  /// The input of the queue of changes.
  private let changes: AsyncStream<Change>.Continuation

  /// The task that applies the changes, the task that reads the events of the session
  /// directory, and the task of the reconcile at launch.
  private let tasks = Mutex<[Task<Void, Never>]>([])

  /// The task of the reconcile at launch, or `nil` before
  /// ``startReconcile(folders:recordingRoot:)``. ``waitUntilApplied()`` waits until the task put
  /// each folder in the queue.
  private let launchReconcile = Mutex<Task<Void, Never>?>(nil)

  /// Makes the object. It starts the task that applies the changes.
  ///
  /// - Parameters:
  ///   - index: The index to keep current.
  ///   - summaryReader: Reads the summary of a session in the session directory.
  init(index: TranscriptSearchIndex, summaryReader: @escaping SummaryReader) {
    self.index = index
    let applier = TranscriptSearchApplier(index: index, summaryReader: summaryReader)
    let (stream, changes) = AsyncStream.makeStream(of: Change.self)
    self.applier = applier
    self.changes = changes
    let worker = Task(priority: .utility) {
      for await change in stream {
        await applier.apply(change)
      }
    }
    tasks.withLock { $0.append(worker) }
  }

  /// Ends the queue of changes and cancels the reads of the object.
  deinit {
    changes.finish()
    for task in tasks.withLock({ $0 }) {
      task.cancel()
    }
  }

  /// Replaces the reader of the summary of a session. A test gives a reader that fails.
  ///
  /// - Parameter reader: The new reader.
  func useSummaryReader(_ reader: @escaping SummaryReader) async {
    await applier.useSummaryReader(reader)
  }

  /// Gives the history of a session that the agent wrote to its file. The call does not wait.
  ///
  /// - Parameters:
  ///   - history: The retained history that the agent wrote.
  ///   - session: The session.
  func indexHistory(_ history: SessionMergeEngine, of session: SessionId) {
    changes.yield(.history(session, history, summary: nil))
  }

  /// Returns when the index applied each change that the object got before this call. The
  /// reconcile at launch is such a change from the time that it starts: the call first waits
  /// until its task put each folder in the queue. The shutdown of the agent waits here, and then
  /// for the saves of the index, so a quit keeps the last change.
  func waitUntilApplied() async {
    await launchReconcile.withLock { $0 }?.value
    await withCheckedContinuation { mark in
      changes.yield(.mark(mark))
    }
  }

  /// Removes the items of each session of a deleted session folder. The call does not wait.
  ///
  /// - Parameter sessions: The sessions.
  func remove(_ sessions: Set<SessionId>) {
    changes.yield(.removal(sessions))
  }

  /// Starts to read the events of the session directory. Each event goes to
  /// ``directoryEventArrived(_:liveHistory:)``. The read holds this object weakly, and it ends
  /// when the object goes away.
  ///
  /// - Parameters:
  ///   - events: The event stream of the session directory.
  ///   - liveHistory: Gives the retained history of a session of the session table.
  func start(
    reading events: AsyncStream<SessionDirectoryEvent>, liveHistory: @escaping LiveHistory
  ) {
    let reader = Task(priority: .utility) { [weak self] in
      for await event in events {
        guard let self else {
          return
        }
        await self.directoryEventArrived(event, liveHistory: liveHistory)
      }
    }
    tasks.withLock { $0.append(reader) }
  }

  /// Gives one event of the session directory to the index.
  ///
  /// A `started` session with a history in the session table gives its history with the facts
  /// of the event. A `factsChanged` gives the new session item. An `archived` and an
  /// `unarchived` give the session item that the directory reads. The other events do not
  /// change the facts of a session.
  ///
  /// - Parameters:
  ///   - event: The event.
  ///   - liveHistory: Gives the retained history of a session of the session table.
  func directoryEventArrived(_ event: SessionDirectoryEvent, liveHistory: LiveHistory) async {
    switch event {
    case .started(let summary, _):
      let session = SessionId(rawValue: summary.id.description)
      guard let history = await liveHistory(session) else {
        return
      }
      changes.yield(.history(session, history, summary: summary))
    case .factsChanged(let summary):
      changes.yield(.facts(summary))
    case .archived(let id), .unarchived(let id):
      changes.yield(.factsOfSession(id))
    case .stateChanged, .messageQueued, .messageDelivered:
      return
    }
  }

  /// Starts the reconcile at launch in a task with a low priority
  /// (``reconcile(folders:recordingRoot:)``).
  ///
  /// - Parameters:
  ///   - folders: Gives the working folders of the project store.
  ///   - recordingRoot: Gives the recording root of a working folder.
  func startReconcile(
    folders: @escaping FolderReader, recordingRoot: @escaping RecordingRootReader
  ) {
    let reconcile = Task(priority: .background) { [weak self] in
      let projectFolders: [URL]
      do {
        projectFolders = try folders()
      } catch {
        ACPAgentTelemetry.logger(.transcriptSearch).warning(
          "The project store cannot be read. The transcript search reconciles no folder.",
          metadata: ACPAgentTelemetry.errorMetadata(error))
        return
      }
      await self?.reconcile(folders: projectFolders, recordingRoot: recordingRoot)
    }
    tasks.withLock { $0.append(reconcile) }
    launchReconcile.withLock { $0 = reconcile }
  }

  /// Reconciles the index with the history files of a set of working folders.
  ///
  /// The reconcile skips each folder that the rule of the index (``TranscriptSearchIndex/
  /// readableFolder``) tells it cannot read: it reads nothing in that folder, also not its
  /// settings, and the items of its sessions stay. For each other folder it reads the recording
  /// root, and puts the reconcile of the folder in the queue of changes. The reconcile of a
  /// folder reads each `session-history.json` of the root when its turn comes, gives the chunk
  /// items of each session, and removes the items of each session of the folder that has no
  /// history file.
  ///
  /// - Parameters:
  ///   - folders: The working folders of the project store.
  ///   - recordingRoot: Gives the recording root of a working folder.
  func reconcile(folders: [URL], recordingRoot: RecordingRootReader) async {
    for folder in folders where index.readableFolder(folder) {
      do {
        let root = try await recordingRoot(folder)
        changes.yield(.reconcile(TranscriptSearchFolder(folder: folder, recordingRoot: root)))
      } catch {
        ACPAgentTelemetry.logger(.transcriptSearch).warning(
          "The settings of a project cannot be read. The transcript search does not reconcile it.",
          metadata: ACPAgentTelemetry.errorMetadata(error))
      }
    }
  }
}

/// One working folder that the reconcile reads, with the recording root of its sessions.
struct TranscriptSearchFolder: Sendable {
  /// The working folder.
  let folder: URL

  /// The recording root of the sessions of the folder.
  let recordingRoot: URL
}

/// Applies the changes of ``TranscriptSearchUpdates`` to the index, one at a time.
actor TranscriptSearchApplier {
  /// The index.
  let index: TranscriptSearchIndex

  /// Reads the summary of a session in the session directory.
  private var summaryReader: TranscriptSearchUpdates.SummaryReader

  /// Makes the applier.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - summaryReader: Reads the summary of a session in the session directory.
  init(index: TranscriptSearchIndex, summaryReader: @escaping TranscriptSearchUpdates.SummaryReader)
  {
    self.index = index
    self.summaryReader = summaryReader
  }

  /// Replaces the reader of the summary of a session.
  ///
  /// - Parameter reader: The new reader.
  func useSummaryReader(_ reader: @escaping TranscriptSearchUpdates.SummaryReader) {
    summaryReader = reader
  }

  /// Applies one change.
  ///
  /// - Parameter change: The change.
  func apply(_ change: TranscriptSearchUpdates.Change) async {
    switch change {
    case .history(let session, let history, let summary):
      await indexHistory(history, of: session, summary: summary)
    case .facts(let summary):
      await index.update(
        session: SessionId(rawValue: summary.id.description),
        metadata: TranscriptSessionMetadata(summary: summary))
    case .factsOfSession(let id):
      let session = SessionId(rawValue: id.description)
      guard let summary = await readSummary(of: session) else {
        return
      }
      await index.update(session: session, metadata: TranscriptSessionMetadata(summary: summary))
    case .removal(let sessions):
      await index.index([:], removing: sessions)
    case .reconcile(let folder):
      await reconcile(folder)
    case .mark(let mark):
      mark.resume()
    }
  }

  /// Indexes the history of a session with its facts. A session whose facts the directory does
  /// not give is not indexed: the `started` event of the session gives its facts later.
  ///
  /// - Parameters:
  ///   - history: The retained history of the session.
  ///   - session: The session.
  ///   - summary: The summary of the session, or `nil` to read it from the directory.
  private func indexHistory(
    _ history: SessionMergeEngine, of session: SessionId, summary: SessionSummary?
  ) async {
    let known = if let summary { summary } else { await readSummary(of: session) }
    guard let known else {
      return
    }
    await index.index(
      session: session, chunks: history.searchChunks,
      metadata: TranscriptSessionMetadata(summary: known))
  }

  /// Reads the summary of a session from the session directory. A failed read is logged.
  ///
  /// - Parameter session: The session.
  /// - Returns: The summary, or `nil` when the directory does not know the session or the read
  ///   failed.
  private func readSummary(of session: SessionId) async -> SessionSummary? {
    guard let id = ULID(ulidString: session.rawValue) else {
      return nil
    }
    do {
      return try await summaryReader(id)
    } catch {
      ACPAgentTelemetry.logger(.transcriptSearch).warning(
        "The facts of a session did not read. The transcript search keeps its old items.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: session))
      return nil
    }
  }
}
