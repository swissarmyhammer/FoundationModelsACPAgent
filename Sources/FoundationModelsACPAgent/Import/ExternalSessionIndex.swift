import ACPImport
import Foundation
import FoundationModelsExtras
import Logging
import Synchronization

/// The index of the external sessions of the Mac: the session files of Claude Code and Codex
/// under the roots that the host can read (D212, section 4).
///
/// The index keeps one small entry for each session file (``ExternalSessionSummary``). It
/// builds the entries in two steps (``ExternalSessionScan``):
///
/// - **Step A, find.** Directory reads with the resource keys of the size, the date and the
///   kind. No file is opened. Each new file is an entry in the state `found`.
/// - **Step B, read.** Four worker tasks at the utility priority read the metadata windows of
///   each file in the state `found`: at most 384 KB of a file, never the full file. The read
///   queue has two levels (``ExternalSessionReadQueue``): the files of a folder that a client
///   asks for now, then each other file, each level the newest first. Each worker checks for
///   cancellation before each file.
///
/// The index does no file I/O in its own isolation: each find, read and write runs in a task
/// at the utility priority. Thus a query never waits for a read, and a query never waits for
/// the build: it gives the entries that the index has now, and the progress of the index
/// (``ExternalSessionIndexState``).
///
/// The index keeps itself current. It writes its entries to the index file of each source
/// (``ExternalSessionIndexFile``) after each 500 new entries and at the end of a build, and it
/// loads that file when a root starts. One watch of each root (FSEvents, a latency of 2 s)
/// gives the changed files. The index reads a changed file at most one time in 30 s; a file
/// that grew, and whose head the index knows, gets a read of its tail only; a file that is gone
/// loses its entry. A root with no watch gets a new find when a client asks, at most one time
/// in 30 s.
///
/// The index gives the operations of `ExternalSessionHost` that read the index:
/// ``externalSessions(_:)`` and ``externalSessionChanges(folder:)``.
actor ExternalSessionIndex {
  // MARK: - Constants

  /// The number of worker tasks of Step B.
  static let workerCount = 4

  /// The latency of the watch of a root.
  static let watchLatency: Duration = .seconds(2)

  /// The shortest time between two reads of one file.
  static let rereadInterval: Duration = .seconds(30)

  /// The shortest time between two finds of a root with no watch.
  static let findInterval: Duration = .seconds(30)

  /// The number of new entries after which the index writes its index file.
  static let entriesPerSave = 500

  // MARK: - State

  /// The file system of the finds, the reads and the index files.
  private let fileSystem: any ExternalSessionFileSystem

  /// The folder of the index files, or `nil` for an index that writes no index file.
  private let indexFolder: URL?

  /// The clock of the 30 s limits.
  private let clock: any ExternalSessionClock

  /// The state of each root, by its source agent.
  private var roots: [ImportSourceAgent: ExternalSessionRoot] = [:]

  /// The number of the next root.
  private var nextGeneration = 0

  /// The read queue of Step B.
  private var queue = ExternalSessionReadQueue()

  /// The files that a worker reads now.
  private var inFlight: Set<ExternalSessionFileKey> = []

  /// The worker tasks, by their number.
  private var workers: [Int: Task<Void, Never>] = [:]

  /// The number of the next worker.
  private var nextWorker = 0

  /// The tasks of the finds, the loads and the writes, by their number.
  private var tasks: [Int: Task<Void, Never>] = [:]

  /// The task of the events of the watch of each root. It runs while its root is in the index.
  private var eventTasks: [ImportSourceAgent: Task<Void, Never>] = [:]

  /// The number of the next task.
  private var nextTask = 0

  /// The last task that reads or writes the index file of each source agent. Each new task of
  /// that file waits for it, so the loads, the writes and the removals of one file run in
  /// order.
  private var fileChains: [ImportSourceAgent: Task<Void, Never>] = [:]

  /// The source agents whose write of the index file waits in the file chain and has not
  /// taken its entries yet. A new write of such an agent is not needed: the waiting write
  /// takes the entries of its own start.
  private var waitingSaves: Set<ImportSourceAgent> = []

  /// The time at which each file that changed too soon after its last read gets its read.
  private var deferred: [ExternalSessionFileKey: ContinuousClock.Instant] = [:]

  /// The task that waits for the earliest time of ``deferred``, and that time.
  private var deferral: (task: Task<Void, Never>, deadline: ContinuousClock.Instant)?

  /// The project key of each folder that a client follows now, by the token of the follow.
  private var follows: [UUID: String] = [:]

  /// The tasks that wait until the index is idle, by their token.
  private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  /// True when the last published state was complete.
  private var wasComplete = false

  /// True after ``stop()``: the index starts no find, read, watch or timer, and writes only
  /// the last index files of the stop.
  private var isStopped = false

  /// The tasks that wait for the end of the read of a file that a worker reads now, by the
  /// file.
  private var readWaiters: [ExternalSessionFileKey: [CheckedContinuation<Void, Never>]] = [:]

  /// The number of event batches of the watches that the index did not apply yet. A watch
  /// adds to it on its own thread, before the batch reaches the actor.
  private let pendingEvents = Mutex(0)

  /// The subscribers of the changes of the index.
  private let feed = SubscriberFeed<ExternalSessionIndexEvent> {
    ACPAgentTelemetry.logger(.session).debug(
      "A subscriber of the external sessions is slow. It lost its oldest change.")
  }

  /// Makes an index with no root. ``replaceRoots(_:)`` starts the build.
  ///
  /// - Parameters:
  ///   - fileSystem: The file system. The local disk by default.
  ///   - indexFolder: The folder of the index files (``AgentHome/externalSessionIndexDirectory``),
  ///     or `nil` for an index that writes no index file.
  ///   - clock: The clock of the 30 s limits. The continuous clock by default.
  init(
    fileSystem: any ExternalSessionFileSystem = LocalExternalSessionFileSystem(),
    indexFolder: URL?,
    clock: any ExternalSessionClock = ContinuousExternalSessionClock()
  ) {
    self.fileSystem = fileSystem
    self.indexFolder = indexFolder
    self.clock = clock
  }

  // MARK: - The roots

  /// Replaces all the roots. A root that is new starts a build: the load of its index file,
  /// its watch and a find. A root that changed or is gone loses its entries, its reads and its
  /// index file (Remove Access). A root that is the same keeps its entries.
  ///
  /// - Parameter newRoots: The root of each source agent that the host can read now.
  nonisolated func replaceRoots(_ newRoots: [ImportSourceAgent: URL]) async {
    let prefixes = newRoots.mapValues(ExternalSessionRoot.prefixes(of:))
    await applyRoots(newRoots, prefixes: prefixes)
  }

  /// The source agents of the roots now.
  var sources: Set<ImportSourceAgent> { Set(roots.keys) }

  /// Builds the index of one source again (D212 5.6, Rebuild Index): the root loses its
  /// entries, its reads and its index file, as for a removed root, and then starts again at the
  /// same URL, with a new find of each file and a full read of each file. The subscribers get
  /// the old rows as removed, and the new rows as the reads end.
  ///
  /// - Parameter agent: The source agent.
  /// - Returns: `false` when the index has no root of the source agent, or is stopped.
  @discardableResult
  func rebuild(_ agent: ImportSourceAgent) -> Bool {
    guard !isStopped, let root = roots[agent] else { return false }
    removeRoot(agent)
    startRoot(agent, url: root.url, prefixes: root.prefixes)
    publish()
    resumeIdleWaiters()
    return true
  }

  /// Replaces all the roots, with the path prefixes of each new root.
  private func applyRoots(
    _ newRoots: [ImportSourceAgent: URL], prefixes: [ImportSourceAgent: [String]]
  ) {
    guard !isStopped else { return }
    for (agent, root) in roots where newRoots[agent] != root.url {
      removeRoot(agent)
    }
    for (agent, url) in newRoots where roots[agent] == nil {
      startRoot(agent, url: url, prefixes: prefixes[agent] ?? [])
    }
    publish()
    resumeIdleWaiters()
  }

  /// Starts a new root: the task of its events, then the load of its index file, its watch and
  /// its first find.
  private func startRoot(_ agent: ImportSourceAgent, url: URL, prefixes: [String]) {
    nextGeneration += 1
    let generation = nextGeneration
    let (events, input) = AsyncStream.makeStream(of: [URL].self)
    roots[agent] = ExternalSessionRoot(
      url: url, prefixes: prefixes, generation: generation, eventInput: input)
    eventTasks[agent] = Task.detached(priority: .utility) { [weak self, fileSystem] in
      for await batch in events {
        let items = Self.eventItems(of: batch, agent: agent, prefixes: prefixes, fileSystem)
        await self?.applyEvents(items, of: agent, generation: generation)
      }
    }
    let file = indexFolder.map { ExternalSessionIndexFile.file(of: agent, in: $0) }
    chainFileTask(of: agent) { [fileSystem] index in
      let loaded = file.flatMap { Self.loadEntries(from: $0, of: agent, root: url, fileSystem) }
      await index.install(loaded ?? [:], of: agent, generation: generation)
      let folders = agent.layout.folders.map { url.appendingPathComponent($0, isDirectory: true) }
      let watch = fileSystem.watch(folders, latency: Self.watchLatency) { [weak index] batch in
        index?.receiveEvents(batch, input: input)
      }
      // A folder of the layout that does not exist now (for example the archive folder of
      // Codex before the first archive) is not in the watch.
      let isPartial = folders.contains { fileSystem.item(at: $0)?.kind != .directory }
      await index.attach(watch, isPartial: isPartial, to: agent, generation: generation)
      await index.find(agent, scope: .root, generation: generation, level: .background)
    }
  }

  /// The entries of an index file. A file with bad bytes or a different format number gives
  /// no entry, and a log line: the index builds again, with no error.
  private nonisolated static func loadEntries(
    from file: URL, of agent: ImportSourceAgent, root: URL,
    _ fileSystem: any ExternalSessionFileSystem
  ) -> [String: ExternalSessionIndexEntry]? {
    guard let data = fileSystem.contents(of: file) else { return nil }
    guard let entries = ExternalSessionIndexFile.entries(in: data, of: agent, root: root) else {
      ACPAgentTelemetry.logger(.session).info(
        "The index file of external sessions has a different format or bad bytes. The index builds again.",
        metadata: ["path": "\(file.path)"])
      return nil
    }
    return entries
  }

  /// Gives the entries of the index file to a root.
  ///
  /// An entry that the root has now came from a find, a read or an event after the start of
  /// the root, for example the find and the read of an import that came before the load ended.
  /// It is newer than the index file, so it stays (``newer(_:_:)``), and the entries of the file
  /// fill the other paths.
  private func install(
    _ entries: [String: ExternalSessionIndexEntry], of agent: ImportSourceAgent, generation: Int
  ) {
    guard let root = roots[agent], root.generation == generation else { return }
    roots[agent]?.replaceEntries(entries.merging(root.entries, uniquingKeysWith: Self.newer))
    publish()
  }

  /// The entry of a path that the index file and the root both have. The entry of the root
  /// stays, but an entry that a find only found, with the stamp of the entry of the file, gives
  /// its place to the entry of the file: the file has the read fields of the same bytes.
  private static func newer(
    _ loaded: ExternalSessionIndexEntry, _ current: ExternalSessionIndexEntry
  ) -> ExternalSessionIndexEntry {
    let isSameFound =
      current.summary.state == .found && loaded.summary.size == current.summary.size
      && loaded.summary.modified == current.summary.modified
    return isSameFound ? loaded : current
  }

  /// Keeps the watch of a root. The watch of a root that is gone stops at once.
  private func attach(
    _ watch: (any ExternalSessionWatch)?, isPartial: Bool, to agent: ImportSourceAgent,
    generation: Int
  ) {
    guard !isStopped, roots[agent]?.generation == generation else {
      watch?.stop()
      return
    }
    roots[agent]?.watch = watch
    roots[agent]?.isWatchPartial = isPartial
  }

  /// Removes a root: its watch stops, its queued reads go, the results of its running reads
  /// are dropped, and its index file is removed.
  private func removeRoot(_ agent: ImportSourceAgent) {
    guard let root = roots.removeValue(forKey: agent) else { return }
    root.findCancel.cancel()
    root.watch?.stop()
    root.eventInput.finish()
    eventTasks.removeValue(forKey: agent)?.cancel()
    queue.remove { $0.agent == agent }
    deferred = deferred.filter { $0.key.agent != agent }
    publish(removed: Array(root.entries.values))
    guard let indexFolder else { return }
    let file = ExternalSessionIndexFile.file(of: agent, in: indexFolder)
    chainFileTask(of: agent) { [fileSystem] _ in fileSystem.removeItem(at: file) }
  }

  // MARK: - Step A

  /// Runs a find of a scope of a root in a task, then applies it.
  private func find(
    _ agent: ImportSourceAgent, scope: ExternalSessionFindScope, generation: Int,
    level: ExternalSessionReadLevel
  ) async {
    guard !isStopped, let start = findStart(of: agent, scope: scope, generation: generation)
    else { return }
    markFinding(agent, scope: scope, generation: generation, isFinding: true)
    let found = await Task.detached(priority: .utility) { [fileSystem] in
      Self.foundEntries(of: agent, under: start.url, scope: scope, fileSystem, cancel: start.cancel)
    }.value
    markFinding(agent, scope: scope, generation: generation, isFinding: false)
    // A cancelled find is not complete: it applies nothing, so it removes no entry.
    guard !isStopped, !start.cancel.isCancelled else { return }
    applyFind(
      found, of: agent, generation: generation, scope: scope, level: level, before: start.entries)
  }

  /// The root of a find and the summary of each entry of the scope when the directory read
  /// starts, or `nil` when the root is gone. A find removes only the entries that it saw at
  /// its start and that did not change after it: an event can add or change an entry while
  /// the directory read runs.
  private func findStart(
    of agent: ImportSourceAgent, scope: ExternalSessionFindScope, generation: Int
  ) -> (url: URL, entries: [String: ExternalSessionSummary], cancel: ExternalSessionFindCancel)? {
    guard let root = roots[agent], root.generation == generation else { return nil }
    let entries = root.entries.compactMapValues { entry in
      Self.scope(scope, holds: entry.summary) ? entry.summary : nil
    }
    return (root.url, entries, root.findCancel)
  }

  /// The found files of a scope, each with its entry in the state `found`. The entries are
  /// made in the task of the find, so the actor encodes nothing.
  private nonisolated static func foundEntries(
    of agent: ImportSourceAgent, under root: URL, scope: ExternalSessionFindScope,
    _ fileSystem: any ExternalSessionFileSystem, cancel: ExternalSessionFindCancel
  ) -> [ExternalSessionFoundFile: ExternalSessionIndexEntry] {
    Dictionary(
      ExternalSessionScan.find(
        agent, under: root, scope: scope, fileSystem: fileSystem, cancel: cancel
      ).map {
        ($0, ExternalSessionIndexEntry(summary: ExternalSessionScan.foundSummary(of: agent, file: $0)))
      }
    ) { first, _ in first }
  }

  /// Marks the start or the end of a find of a root. A find of an older generation of the root
  /// marks nothing.
  private func markFinding(
    _ agent: ImportSourceAgent, scope: ExternalSessionFindScope, generation: Int, isFinding: Bool
  ) {
    guard roots[agent]?.generation == generation else { return }
    let change = isFinding ? 1 : -1
    switch scope {
    case .root:
      roots[agent]?.rootFindCount += change
    case .project(let key):
      let count = (roots[agent]?.projectFindCounts[key] ?? 0) + change
      roots[agent]?.projectFindCounts[key] = count > 0 ? count : nil
    }
  }

  /// Applies a find: each new file is an entry in the state `found` and is queued, each file
  /// with a new stamp is queued, and each entry that the find saw at its start, whose file is
  /// gone and that did not change after the start, is removed.
  private func applyFind(
    _ found: [ExternalSessionFoundFile: ExternalSessionIndexEntry], of agent: ImportSourceAgent,
    generation: Int, scope: ExternalSessionFindScope, level: ExternalSessionReadLevel,
    before: [String: ExternalSessionSummary]
  ) {
    guard roots[agent]?.generation == generation else { return }
    for (file, entry) in found {
      noteFound(
        file, entry: entry, of: agent, existing: roots[agent]?.entries[file.path]?.summary,
        level: level)
    }
    let foundPaths = Set(found.keys.map(\.path))
    let gone = before.filter { path, summary in
      !foundPaths.contains(path) && roots[agent]?.entries[path]?.summary == summary
        && !inFlight.contains(ExternalSessionFileKey(agent: agent, path: path))
    }
    remove(Array(gone.keys), of: agent)
    if scope == .root {
      roots[agent]?.isFound = true
      roots[agent]?.lastFind = clock.now
    }
    publish()
    startWorkers()
    saveIfDue(agent)
    resumeIdleWaiters()
  }

  /// True when a scope of a find holds an entry.
  private static func scope(_ scope: ExternalSessionFindScope, holds summary: ExternalSessionSummary)
    -> Bool
  {
    switch scope {
    case .root: true
    case .project(let key): summary.projectKey == key
    }
  }

  /// Applies one file of a find.
  private func noteFound(
    _ file: ExternalSessionFoundFile, entry: ExternalSessionIndexEntry,
    of agent: ImportSourceAgent, existing: ExternalSessionSummary?, level: ExternalSessionReadLevel
  ) {
    let key = ExternalSessionFileKey(agent: agent, path: file.path)
    guard let existing else {
      roots[agent]?.set(entry)
      roots[agent]?.unsavedCount += 1
      enqueue(key, modified: file.modified, projectKey: file.projectKey, level: level)
      return
    }
    if existing.state == .found {
      enqueue(key, modified: file.modified, projectKey: file.projectKey, level: level)
    } else if existing.size != file.size || existing.modified != file.modified {
      scheduleRead(key, modified: file.modified, projectKey: file.projectKey, level: level)
    }
  }

  /// Removes the entries of some files, and publishes their removal.
  private func remove(_ paths: [String], of agent: ImportSourceAgent) {
    guard !paths.isEmpty else { return }
    let removed = paths.compactMap { path in
      queue.remove(ExternalSessionFileKey(agent: agent, path: path))
      return roots[agent]?.removeEntry(at: path)
    }
    roots[agent]?.unsavedCount += removed.count
    publish(removed: removed)
  }

  /// Starts a find of each root with no watch, or with a partial watch, whose last find is 30 s
  /// old or older.
  private func requestFinds(of agents: [ImportSourceAgent]) {
    guard !isStopped else { return }
    let now = clock.now
    for agent in agents {
      guard let root = roots[agent], root.watch == nil || root.isWatchPartial, root.isFound,
        !root.isFinding,
        root.lastFind.map({ now >= $0 + Self.findInterval }) ?? true
      else { continue }
      let generation = root.generation
      spawn { index in await index.find(agent, scope: .root, generation: generation, level: .background) }
    }
  }

  // MARK: - The events of a watch

  /// Gives one batch of a watch to the task of the events of its root. The call runs on the
  /// thread of the watch.
  ///
  /// - Parameters:
  ///   - batch: The URLs of the changed items.
  ///   - input: The input of the events of the root.
  private nonisolated func receiveEvents(
    _ batch: [URL], input: AsyncStream<[URL]>.Continuation
  ) {
    pendingEvents.withLock { $0 += 1 }
    if case .terminated = input.yield(batch) {
      pendingEvents.withLock { $0 -= 1 }
    }
  }

  /// The items of one batch of a watch, with the stat of each item and the entry of each
  /// session file that exists. The task of the events of the root makes them, so the actor
  /// reads no file and encodes nothing.
  private nonisolated static func eventItems(
    of batch: [URL], agent: ImportSourceAgent, prefixes: [String],
    _ fileSystem: any ExternalSessionFileSystem
  ) -> [ExternalSessionEventItem] {
    batch.compactMap { url in
      guard let path = ExternalSessionRoot.relativePath(of: url, prefixes: prefixes) else {
        return nil
      }
      let components = path.split(separator: "/").map(String.init)
      let item = fileSystem.item(at: url)
      let entry = item.flatMap { item -> ExternalSessionIndexEntry? in
        guard item.kind == .file, agent.layout.holds(components) else { return nil }
        let file = ExternalSessionFoundFile(
          path: path, projectKey: agent.projectKey(ofFile: components), size: item.size,
          modified: item.modified)
        return ExternalSessionIndexEntry(summary: ExternalSessionScan.foundSummary(of: agent, file: file))
      }
      return ExternalSessionEventItem(path: path, components: components, kind: item?.kind, entry: entry)
    }
  }

  /// Applies one batch of a watch: a session file that changed is queued, a session file that
  /// is gone loses its entry, and a folder that changed gets a find.
  private func applyEvents(
    _ items: [ExternalSessionEventItem], of agent: ImportSourceAgent, generation: Int
  ) {
    defer {
      pendingEvents.withLock { $0 -= 1 }
      resumeIdleWaiters()
    }
    guard roots[agent]?.generation == generation else { return }
    for item in items {
      applyEvent(item, of: agent, generation: generation)
    }
    publish()
    startWorkers()
    saveIfDue(agent)
  }

  /// Applies the event of one item of a root.
  private func applyEvent(
    _ item: ExternalSessionEventItem, of agent: ImportSourceAgent, generation: Int
  ) {
    switch (item.kind, agent.layout.holds(item.components)) {
    case (.directory, _), (nil, false):
      requestEventFind(agent, components: item.components, generation: generation)
    case (nil, true):
      remove([item.path], of: agent)
    case (.file, true):
      guard let entry = item.entry else { return }
      let summary = entry.summary
      let file = ExternalSessionFoundFile(
        path: summary.path, projectKey: summary.projectKey, size: summary.size,
        modified: summary.modified)
      noteFound(
        file, entry: entry, of: agent, existing: roots[agent]?.entries[item.path]?.summary,
        level: .background)
    case (.file, false), (.other, _):
      return
    }
  }

  /// Starts a find for a folder event: the project folder of a Claude Code root, else the whole
  /// root.
  private func requestEventFind(_ agent: ImportSourceAgent, components: [String], generation: Int) {
    guard !isStopped, let root = roots[agent] else { return }
    let projectIndex = ImportSourceLayout.projectComponentIndex
    let isProject = agent.layout.hasProjectFolders && components.indices.contains(projectIndex)
    let scope: ExternalSessionFindScope = isProject ? .project(components[projectIndex]) : .root
    switch scope {
    case .root where root.isFinding:
      return
    case .project(let key) where root.isFinding(project: key):
      return
    default:
      spawn { index in await index.find(agent, scope: scope, generation: generation, level: .background) }
    }
  }

  // MARK: - The read queue

  /// Queues a file whose stamp changed: at once when its last read is 30 s old or older, else
  /// at 30 s after its last read. A file that a worker reads now gets its next read 30 s
  /// later.
  private func scheduleRead(
    _ key: ExternalSessionFileKey, modified: Date, projectKey: String?,
    level: ExternalSessionReadLevel
  ) {
    let now = clock.now
    let deadline =
      inFlight.contains(key)
      ? now + Self.rereadInterval
      : roots[key.agent]?.lastRead[key.path].map { $0 + Self.rereadInterval }
    guard let deadline, now < deadline else {
      enqueue(key, modified: modified, projectKey: projectKey, level: level)
      return
    }
    deferred[key] = min(deferred[key] ?? deadline, deadline)
    armDeferral()
  }

  /// Queues a file at its level: level 1 when a client follows its project folder.
  private func enqueue(
    _ key: ExternalSessionFileKey, modified: Date, projectKey: String?,
    level: ExternalSessionReadLevel
  ) {
    guard !inFlight.contains(key) else {
      scheduleRead(key, modified: modified, projectKey: projectKey, level: level)
      return
    }
    let isFollowed = projectKey.map { follows.values.contains($0) } ?? false
    queue.enqueue(key, modified: modified, projectKey: projectKey, level: isFollowed ? .folder : level)
  }

  /// Starts the task that queues the deferred files at their time, when no task waits for an
  /// earlier time.
  private func armDeferral() {
    guard !isStopped, let earliest = deferred.values.min() else { return }
    if let deferral, deferral.deadline <= earliest { return }
    deferral?.task.cancel()
    let task = Task { await self.runDeferrals(until: earliest) }
    deferral = (task, earliest)
  }

  /// Waits for a time, then queues each deferred file whose time came.
  private func runDeferrals(until deadline: ContinuousClock.Instant) async {
    do {
      try await clock.sleep(until: deadline)
    } catch {
      return
    }
    guard deferral?.deadline == deadline else { return }
    deferral = nil
    queueDueDeferrals()
    armDeferral()
    resumeIdleWaiters()
  }

  /// Queues each deferred file whose time came.
  private func queueDueDeferrals() {
    let now = clock.now
    for (key, deadline) in deferred where deadline <= now {
      deferred[key] = nil
      guard let summary = roots[key.agent]?.entries[key.path]?.summary else { continue }
      enqueue(key, modified: summary.modified, projectKey: summary.projectKey, level: .background)
    }
    startWorkers()
  }

  // MARK: - Step B

  /// Starts workers until the index has ``workerCount`` workers, or one worker for each queued
  /// file.
  private func startWorkers() {
    guard !isStopped else { return }
    while workers.count < Self.workerCount, workers.count < queue.count + inFlight.count {
      let worker = nextWorker
      nextWorker += 1
      workers[worker] = Task.detached(priority: .utility) { [self, fileSystem] in
        await Self.work(index: self, worker: worker, fileSystem: fileSystem)
      }
    }
  }

  /// The loop of one worker: takes a file, checks for cancellation, reads the file in its own
  /// task, and gives the result to the index.
  private nonisolated static func work(
    index: ExternalSessionIndex, worker: Int, fileSystem: any ExternalSessionFileSystem
  ) async {
    while let job = await index.takeJob(worker: worker) {
      guard !Task.isCancelled else {
        await index.abandon(job, worker: worker)
        return
      }
      let outcome = ExternalSessionScan.read(job, fileSystem: fileSystem)
      await index.finish(job, outcome: outcome)
    }
  }

  /// The next read of a worker, or `nil` when the queue is empty. The worker ends after `nil`.
  private func takeJob(worker: Int) -> ExternalSessionReadJob? {
    while !isStopped, let key = queue.next() {
      guard let root = roots[key.agent] else { continue }
      inFlight.insert(key)
      let prior = root.entries[key.path]?.summary
      return ExternalSessionReadJob(
        key: key, root: root.url, projectKey: prior?.projectKey, prior: prior,
        generation: root.generation)
    }
    workers[worker] = nil
    resumeIdleWaiters()
    return nil
  }

  /// Ends a worker whose task was cancelled before its read.
  private func abandon(_ job: ExternalSessionReadJob, worker: Int) {
    inFlight.remove(job.key)
    resumeReadWaiters(of: job.key)
    workers[worker] = nil
    resumeIdleWaiters()
  }

  /// Applies the result of one read.
  ///
  /// The result of a file whose entry an event or a find removed while the read ran is
  /// dropped: the file is gone. An entry that a read makes unreadable leaves the rows, thus
  /// the subscribers get its removal.
  private func finish(_ job: ExternalSessionReadJob, outcome: ExternalSessionReadOutcome) {
    inFlight.remove(job.key)
    defer {
      resumeReadWaiters(of: job.key)
      resumeIdleWaiters()
    }
    let agent = job.key.agent
    guard roots[agent]?.generation == job.generation,
      let old = roots[agent]?.entries[job.key.path]
    else { return }
    roots[agent]?.lastRead[job.key.path] = clock.now
    switch outcome {
    case .read(let entry):
      roots[agent]?.set(entry)
      roots[agent]?.unsavedCount += 1
      publish(changed: [entry], removed: entry.summary.state == .read ? [] : [old])
    case .unchanged:
      return
    case .gone:
      remove([job.key.path], of: agent)
    }
    saveIfDue(agent)
  }

  // MARK: - The index file

  /// Writes the index file of a root after ``entriesPerSave`` new entries, and at the end of a
  /// build.
  private func saveIfDue(_ agent: ImportSourceAgent) {
    guard !isStopped, let root = roots[agent], root.unsavedCount > 0 else { return }
    let isSettled =
      root.isFound && root.foundCount == 0 && queue.count(of: agent) == 0
      && !inFlight.contains { $0.agent == agent }
    guard root.unsavedCount >= Self.entriesPerSave || isSettled else { return }
    save(agent)
  }

  /// Writes the index file of a root in its file chain. The write takes the entries of its own
  /// start, so a write that waits in the chain makes a second write unnecessary.
  private func save(_ agent: ImportSourceAgent) {
    guard let indexFolder, let root = roots[agent] else { return }
    roots[agent]?.unsavedCount = 0
    guard waitingSaves.insert(agent).inserted else { return }
    let generation = root.generation
    let file = ExternalSessionIndexFile.file(of: agent, in: indexFolder)
    chainFileTask(of: agent) { [fileSystem] index in
      guard let snapshot = await index.saveSnapshot(of: agent, generation: generation) else {
        return
      }
      let data = ExternalSessionIndexFile.data(of: agent, root: snapshot.root, lines: snapshot.lines)
      do {
        try fileSystem.replaceContents(of: file, with: data)
      } catch {
        ACPAgentTelemetry.logger(.session).warning(
          "The index of external sessions cannot write its index file.",
          metadata: ["path": "\(file.path)", "error": "\(error)"])
      }
    }
  }

  /// The root and the line of each entry of a root, for a write of its index file, or `nil`
  /// when the root is gone.
  private func saveSnapshot(of agent: ImportSourceAgent, generation: Int) -> (
    root: URL, lines: [Data]
  )? {
    waitingSaves.remove(agent)
    guard let root = roots[agent], root.generation == generation else { return nil }
    return (root.url, root.entries.values.map(\.line))
  }

  // MARK: - The tasks

  /// Starts a task of the index at the utility priority, and keeps it until it ends.
  ///
  /// - Parameter work: The work of the task.
  /// - Returns: The task.
  @discardableResult
  private func spawn(_ work: @escaping @Sendable (ExternalSessionIndex) async -> Void)
    -> Task<Void, Never>
  {
    let number = nextTask
    nextTask += 1
    let task = Task.detached(priority: .utility) { [self] in
      await work(self)
      await self.taskEnded(number)
    }
    tasks[number] = task
    return task
  }

  /// Starts a task of the index file of a source agent, after the last task of that file.
  private func chainFileTask(
    of agent: ImportSourceAgent, _ work: @escaping @Sendable (ExternalSessionIndex) async -> Void
  ) {
    let previous = fileChains[agent]
    fileChains[agent] = spawn { index in
      await previous?.value
      await work(index)
    }
  }

  /// Forgets a task that ended.
  private func taskEnded(_ number: Int) {
    tasks[number] = nil
    resumeIdleWaiters()
  }

  /// Stops the index, and writes the last index files. The agent calls it at its shutdown.
  ///
  /// After the call starts, the index starts no find, read, watch or timer, and a watch that a
  /// running load gives stops at once. The workers end after their read now. When each task
  /// ended, the index writes the index file of each root with entries that it did not write
  /// yet, and the call returns after those writes.
  func stop() async {
    guard !isStopped else {
      // A second stop stops nothing again. It waits for the work of the first stop.
      await waitForTasks()
      return
    }
    isStopped = true
    for root in roots.values {
      root.findCancel.cancel()
      root.watch?.stop()
      root.eventInput.finish()
    }
    for task in eventTasks.values {
      task.cancel()
    }
    for worker in workers.values {
      worker.cancel()
    }
    deferral?.task.cancel()
    deferral = nil
    await waitForTasks()
    for (agent, root) in roots where root.unsavedCount > 0 {
      save(agent)
    }
    await waitForTasks()
    resumeIdleWaiters()
  }

  /// Waits until no worker and no task of the index runs. A task can start an other task, thus
  /// the wait looks again after each end.
  private func waitForTasks() async {
    while let task = workers.values.first ?? tasks.values.first {
      await task.value
    }
  }

  // MARK: - Idle

  /// True when the index has no find, load, write, read or event to do now. A deferred read
  /// whose time did not come does not count.
  private var isIdle: Bool {
    let now = clock.now
    guard tasks.isEmpty, workers.isEmpty, inFlight.isEmpty else { return false }
    // After a stop, the queue and the timer do no more work.
    return isStopped
      || (queue.isEmpty && pendingEvents.withLock({ $0 }) == 0
        && !deferred.values.contains { $0 <= now })
  }

  /// Waits until the index has no find, load, write, read or event to do. A one-shot client,
  /// for example a test or a command that needs the full index, calls it. A query never calls
  /// it.
  func waitUntilIdle() async {
    guard !isIdle else { return }
    let token = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          idleWaiters[token] = continuation
        }
      }
    } onCancel: {
      Task { await self.resumeIdleWaiter(token) }
    }
  }

  /// Resumes each task that waits for the end of the read of a file.
  private func resumeReadWaiters(of key: ExternalSessionFileKey) {
    for waiter in readWaiters.removeValue(forKey: key) ?? [] {
      waiter.resume()
    }
  }

  /// Resumes one waiter of ``waitUntilIdle()`` whose task was cancelled.
  private func resumeIdleWaiter(_ token: UUID) {
    idleWaiters.removeValue(forKey: token)?.resume()
  }

  /// Resumes each waiter of ``waitUntilIdle()`` when the index is idle.
  private func resumeIdleWaiters() {
    guard !idleWaiters.isEmpty, isIdle else { return }
    let waiters = idleWaiters.values
    idleWaiters = [:]
    for waiter in waiters {
      waiter.resume()
    }
  }
}

// MARK: - Queries

extension ExternalSessionIndex {
  /// The progress of the index: the files that it found, the files that it read or cannot
  /// read, and true when it read each file that it found after a find of each root.
  var indexState: ExternalSessionIndexState {
    let found = roots.values.reduce(0) { $0 + $1.entries.count }
    let notRead = roots.values.reduce(0) { $0 + $1.foundCount }
    return ExternalSessionIndexState(
      filesFound: found, filesRead: found - notRead,
      isComplete: notRead == 0 && roots.values.allSatisfy(\.isFound))
  }

  /// The progress of the index for the files of one folder: the files of the project folder of
  /// the folder, or, for a source with no project folders, the files whose `cwd` is the folder.
  /// It is complete when the index read each such file, and no find that can add a file of
  /// the folder runs or is still to come.
  ///
  /// - Parameter match: The folder.
  /// - Returns: The progress of the folder.
  func folderIndexState(of match: ExternalSessionFolderMatch?) -> ExternalSessionIndexState? {
    match.map(folderIndexState(of:))
  }

  /// The progress of the index for the files of one folder (``folderIndexState(of:)``).
  ///
  /// - Parameter match: The folder.
  /// - Returns: The progress of the folder.
  func folderIndexState(of match: ExternalSessionFolderMatch) -> ExternalSessionIndexState {
    folderIndexState(of: match, agents: nil)
  }

  /// The progress of the index for the files of one folder, for some source agents.
  ///
  /// - Parameters:
  ///   - match: The folder.
  ///   - agents: The source agents, or `nil` for each source agent.
  /// - Returns: The progress of the folder.
  private func folderIndexState(
    of match: ExternalSessionFolderMatch, agents: Set<ImportSourceAgent>?
  ) -> ExternalSessionIndexState {
    var found = 0
    var notRead = 0
    var isComplete = true
    for (agent, root) in roots where agents?.contains(agent) ?? true {
      if agent.layout.hasProjectFolders {
        for key in match.projectKeys {
          let counts = root.counts(ofProject: key)
          found += counts.entries
          notRead += counts.found
          if root.isFinding(project: key) || (!root.isFound && counts.entries == 0) {
            isComplete = false
          }
        }
      } else {
        let entries = root.entries.values.filter(match.matches)
        found += entries.count
        notRead += entries.filter { $0.summary.state == .found }.count
        if !root.isFound { isComplete = false }
      }
    }
    return ExternalSessionIndexState(
      filesFound: found, filesRead: found - notRead, isComplete: isComplete && notRead == 0)
  }

  /// One page of the external sessions, the newest first (`ExternalSessionHost`).
  ///
  /// The page holds the entries in the state `read` that the index has now. A query with a
  /// folder puts the files of the project folder of the folder at level 1 of the read queue,
  /// and starts a find of that one project folder when the index has no entry of it. The
  /// other sessions of the folder come later through ``externalSessionChanges(folder:)``. A
  /// query whose task is cancelled moves those files back to level 2.
  ///
  /// - Parameter query: The filter and the page.
  /// - Returns: The page.
  /// - Throws: ``ExternalSessionIndexError/unknownSource(_:)`` for an unknown source,
  ///   `ExternalSessionError.invalidCursor(_:)` for a cursor that is not a cursor of the index,
  ///   and `CancellationError` when the task is cancelled.
  nonisolated func externalSessions(_ query: ExternalSessionQuery) async throws
    -> ExternalSessionPage
  {
    let agents = try query.source.map { [try Self.agent(named: $0)] } ?? ImportSourceAgent.allCases
    let match = query.folder.map(ExternalSessionFolderMatch.init(folder:))
    return try await page(query, agents: agents, match: match)
  }

  /// The rows of some source agents, the newest first. A query with a folder puts the files
  /// of the folder at level 1 of the read queue (``externalSessions(_:)``).
  ///
  /// - Parameters:
  ///   - agents: The source agents.
  ///   - folder: The working folder of the rows, or `nil` for each folder.
  ///   - automated: True to include the automated sessions.
  /// - Returns: The rows.
  /// - Throws: `CancellationError` when the task is cancelled: the files of the folder then go
  ///   back to level 2.
  nonisolated func sessions(
    of agents: [ImportSourceAgent], folder: URL?, automated: Bool
  ) async throws -> [LocatedExternalSession] {
    let match = folder.map(ExternalSessionFolderMatch.init(folder:))
    return try await rows(of: agents, match: match, automated: automated)
  }

  /// The counts of the typed and of the automated sessions that the index has now, with no
  /// paging (`ExternalSessionHost`). The counts hold only the entries in the state `read`, as
  /// a page does. A count of each folder reads the totals of each root; a count of one folder
  /// checks each entry in memory with the same match as a page of that folder. The call reads
  /// no file and changes no level of the read queue. It starts a find of a root with no watch
  /// or a partial watch, as a page does.
  ///
  /// - Parameters:
  ///   - source: The source agent, or `nil` for each source agent.
  ///   - folder: The working folder, or `nil` for each folder.
  /// - Returns: The counts, and the progress of the index for the same scope.
  /// - Throws: ``ExternalSessionIndexError/unknownSource(_:)`` for an unknown source, and
  ///   `CancellationError` when the task is cancelled.
  nonisolated func externalSessionCounts(source: String?, folder: URL?) async throws
    -> ExternalSessionCounts
  {
    try Task.checkCancellation()
    let agents = try source.map { [try Self.agent(named: $0)] } ?? ImportSourceAgent.allCases
    let match = folder.map(ExternalSessionFolderMatch.init(folder:))
    return await counts(of: agents, match: match)
  }

  /// The counts of some source agents (``externalSessionCounts(source:folder:)``).
  private func counts(
    of agents: [ImportSourceAgent], match: ExternalSessionFolderMatch?
  ) -> ExternalSessionCounts {
    requestFinds(of: agents)
    let scoped = agents.compactMap { roots[$0] }
    guard let match else {
      let found = scoped.reduce(0) { $0 + $1.entries.count }
      let notRead = scoped.reduce(0) { $0 + $1.foundCount }
      return ExternalSessionCounts(
        typedCount: scoped.reduce(0) { $0 + $1.typedCount },
        automatedCount: scoped.reduce(0) { $0 + $1.automatedCount },
        indexState: ExternalSessionIndexState(
          filesFound: found, filesRead: found - notRead,
          isComplete: notRead == 0 && scoped.allSatisfy(\.isFound)))
    }
    var typed = 0
    var automated = 0
    for root in scoped {
      for entry in root.entries.values where entry.summary.state == .read && match.matches(entry) {
        if entry.summary.isAutomated { automated += 1 } else { typed += 1 }
      }
    }
    return ExternalSessionCounts(
      typedCount: typed, automatedCount: automated,
      indexState: folderIndexState(of: match, agents: Set(agents)))
  }

  /// The typed sessions of each root in the state `read`, for the search items of the
  /// transcript search (D212, design section 5.2). The call reads only the memory of the index:
  /// it starts no find, changes no level of the read queue, and reads no file.
  ///
  /// - Returns: The sessions, in no order.
  func typedReadSessions() -> [ExternalSessionSummary] {
    roots.values.flatMap { root in
      root.entries.values.lazy.map(\.summary).filter { $0.state == .read && !$0.isAutomated }
    }
  }

  /// The source agent of a name.
  ///
  /// - Parameter name: The name, for example `claude-code`.
  /// - Returns: The agent.
  /// - Throws: ``ExternalSessionIndexError/unknownSource(_:)`` for a name of no agent.
  static func agent(named name: String) throws -> ImportSourceAgent {
    guard let agent = ImportSourceAgent(rawValue: name) else {
      throw ExternalSessionIndexError.unknownSource(name)
    }
    return agent
  }

  /// One page of a query.
  private func page(
    _ query: ExternalSessionQuery, agents: [ImportSourceAgent], match: ExternalSessionFolderMatch?
  ) throws -> ExternalSessionPage {
    let rows = try rows(of: agents, match: match, automated: query.automated)
    guard let page = ExternalSessionPaging.page(of: rows, limit: query.limit, cursor: query.cursor)
    else {
      throw ExternalSessionError.invalidCursor(query.cursor ?? "")
    }
    return ExternalSessionPage(
      sessions: page.rows.map(\.summary), indexState: indexState, nextCursor: page.nextCursor,
      unreadableSources: agents.filter { roots[$0] == nil }.map(\.rawValue),
      folderIndexState: match.map(folderIndexState(of:)))
  }

  /// The rows of some source agents in the state `read`, the newest first. Each query comes
  /// here, thus each query with a folder puts the files of the folder at level 1, and each
  /// cancelled query moves them back to level 2.
  ///
  /// - Throws: `CancellationError` when the task is cancelled.
  private func rows(
    of agents: [ImportSourceAgent], match: ExternalSessionFolderMatch?, automated: Bool
  ) throws -> [LocatedExternalSession] {
    requestFinds(of: agents)
    if let match { prioritize(projectKey: match.projectKey, of: agents) }
    if Task.isCancelled {
      if let match { release(projectKey: match.projectKey) }
      throw CancellationError()
    }
    return agents.flatMap { agent -> [LocatedExternalSession] in
      guard let root = roots[agent] else { return [] }
      return root.entries.values.compactMap { entry in
        let summary = entry.summary
        guard summary.state == .read, automated || !summary.isAutomated,
          match.map({ $0.matches(entry) }) ?? true
        else { return nil }
        return LocatedExternalSession(summary: summary, root: root.url)
      }
    }
    .sorted(by: LocatedExternalSession.isNewer)
  }

  /// Puts the queued files of a project folder at level 1, and starts a find of that folder
  /// when the index has no entry of it.
  private func prioritize(projectKey: String, of agents: [ImportSourceAgent]) {
    for agent in agents where agent.layout.hasProjectFolders {
      guard let root = roots[agent] else { continue }
      queue.move(projectKey: projectKey, of: agent, to: .folder) { key in
        root.entries[key.path]?.summary.modified ?? .distantPast
      }
      if !isStopped, !root.hasEntries(ofProject: projectKey),
        !root.isFinding(project: projectKey)
      {
        let generation = root.generation
        spawn { index in
          await index.find(agent, scope: .project(projectKey), generation: generation, level: .folder)
        }
      }
    }
    startWorkers()
  }

  /// Moves the queued files of a project folder back to level 2, when no client follows the
  /// folder.
  private func release(projectKey: String) {
    guard !follows.values.contains(projectKey) else { return }
    for agent in ImportSourceAgent.allCases where agent.layout.hasProjectFolders {
      guard let root = roots[agent] else { continue }
      queue.move(projectKey: projectKey, of: agent, to: .background) { key in
        root.entries[key.path]?.summary.modified ?? .distantPast
      }
    }
  }

  /// The number of queued files at each level, for a test of the read queue.
  var queuedCounts: (folder: Int, background: Int) {
    (queue.count(at: .folder), queue.count(at: .background))
  }

  // MARK: - Follows

  /// Runs an operation while the files of a folder are at level 1 of the read queue. The end
  /// of the operation, also by a cancellation, moves them back to level 2 when no other client
  /// follows the folder.
  ///
  /// - Parameters:
  ///   - folder: The folder.
  ///   - operation: The operation.
  /// - Returns: The value of the operation.
  /// - Throws: The error of the operation.
  nonisolated func whileFollowing<Value: Sendable>(
    folder: URL, _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    let projectKey = ExternalSessionFolderMatch(folder: folder).projectKey
    let token = await follow(projectKey: projectKey)
    do {
      let value = try await operation()
      await unfollow(token)
      return value
    } catch {
      await unfollow(token)
      throw error
    }
  }

  /// Starts a follow of a project folder.
  private func follow(projectKey: String) -> UUID {
    let token = UUID()
    follows[token] = projectKey
    prioritize(projectKey: projectKey, of: ImportSourceAgent.allCases)
    return token
  }

  /// Ends a follow.
  private func unfollow(_ token: UUID) {
    guard let projectKey = follows.removeValue(forKey: token) else { return }
    release(projectKey: projectKey)
  }

  // MARK: - Changes

  /// The changes of the index for one folder, or for each folder (`ExternalSessionHost`).
  ///
  /// The first element holds no session and the progress of the index now. Each next element
  /// holds the sessions that a read added or changed, the sessions whose files are gone, and
  /// the progress. A stream of a folder also gives the progress of that folder
  /// (``folderIndexState(of:)``) in each element. A stream of a folder holds only the sessions of that folder, and keeps the
  /// files of the folder at level 1 of the read queue until it ends.
  ///
  /// - Parameter folder: The working folder to follow, or `nil` for each folder.
  /// - Returns: The stream. It ends when the task that reads it is cancelled.
  nonisolated func externalSessionChanges(folder: URL?) -> AsyncStream<ExternalSessionChange> {
    let events = feed.subscribe()
    let match = folder.map(ExternalSessionFolderMatch.init(folder:))
    let (stream, output) = AsyncStream.makeStream(
      of: ExternalSessionChange.self, bufferingPolicy: .bufferingNewest(feed.bufferLimit))
    let relay: @Sendable () async -> Void = {
      output.yield(
        ExternalSessionChange(
          changed: [], indexState: await self.indexState,
          folderIndexState: await self.folderIndexState(of: match)))
      for await event in events {
        guard var change = event.change(for: match) else { continue }
        change.folderIndexState = await self.folderIndexState(of: match)
        output.yield(change)
      }
    }
    let task = Task {
      if let folder {
        try? await self.whileFollowing(folder: folder) { await relay() }
      } else {
        await relay()
      }
      output.finish()
    }
    output.onTermination = { _ in task.cancel() }
    return stream
  }

  /// Publishes one change to the subscribers.
  ///
  /// - Parameters:
  ///   - changed: The entries that a read added or changed.
  ///   - removed: The entries whose files are gone.
  private func publish(
    changed: [ExternalSessionIndexEntry] = [], removed: [ExternalSessionIndexEntry] = []
  ) {
    let state = indexState
    let completesBuild = state.isComplete && !wasComplete
    wasComplete = state.isComplete
    feed.publish([
      ExternalSessionIndexEvent(
        changed: changed.filter { $0.summary.state == .read },
        removed: removed.filter { $0.summary.state == .read }, indexState: state,
        completesBuild: completesBuild)
    ])
  }

  // MARK: - The source of a copy

  /// The session of a source agent whose id or file path is `source`, for a copy. A session
  /// that the index has not read yet is read now. When the index has no such session, a find
  /// of the root runs first.
  ///
  /// - Parameters:
  ///   - source: The id of the session, or the path of its file.
  ///   - agent: The source agent.
  /// - Returns: The session, or `nil` when the root holds no such session.
  func session(matching source: String, of agent: ImportSourceAgent) async
    -> LocatedExternalSession?
  {
    if let path = path(matching: source, of: agent) {
      return await located(path, of: agent)
    }
    guard let generation = roots[agent]?.generation else { return nil }
    await find(agent, scope: .root, generation: generation, level: .background)
    guard let path = path(matching: source, of: agent) else { return nil }
    return await located(path, of: agent)
  }

  /// The path of the entry whose id or file path is `source`.
  private func path(matching source: String, of agent: ImportSourceAgent) -> String? {
    guard let root = roots[agent] else { return nil }
    let filePath = URL(fileURLWithPath: source).standardizedFileURL.path
    if let prefix = root.prefixes.first(where: filePath.hasPrefix) {
      let path = String(filePath.dropFirst(prefix.count))
      if root.entries[path] != nil { return path }
    }
    return root.entries.values.first { $0.summary.sourceID == source }?.summary.path
  }

  /// The row of an entry, after a read of the entry when it is in the state `found`. When a
  /// worker reads the file now, the call waits for that read and makes no second read.
  private func located(_ path: String, of agent: ImportSourceAgent) async -> LocatedExternalSession? {
    guard let root = roots[agent], let entry = root.entries[path] else { return nil }
    let key = ExternalSessionFileKey(agent: agent, path: path)
    if inFlight.contains(key) {
      // A worker reads the file now: wait for its read, and make no second read.
      await withCheckedContinuation { readWaiters[key, default: []].append($0) }
    } else if entry.summary.state == .found {
      queue.remove(key)
      inFlight.insert(key)
      let job = ExternalSessionReadJob(
        key: key, root: root.url, projectKey: entry.summary.projectKey, prior: entry.summary,
        generation: root.generation)
      let outcome = await Task.detached(priority: .userInitiated) { [fileSystem] in
        ExternalSessionScan.read(job, fileSystem: fileSystem)
      }.value
      finish(job, outcome: outcome)
    }
    guard let current = roots[agent], let summary = current.entries[path]?.summary else { return nil }
    return LocatedExternalSession(summary: summary, root: current.url)
  }
}
