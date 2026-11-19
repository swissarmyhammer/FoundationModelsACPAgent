import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMetadataRegistry

/// The reusable index of the transcript search (D207 (b), Q66): the chunk items and the session
/// items of a set of sessions in one `MetadataSearcher` of the registry.
///
/// The searcher is the engine, as it is: the `.retrieval` mode with the default weights. Its
/// BM25, trigram and cosine signals, fused with RRF, decide which items match and their order.
/// This type makes no store, no candidate step, no cosine and no fusion of its own. With no
/// embedder, the searcher ranks with the keyword signals only.
///
/// One code serves two folders. The agent owns one index over
/// ``AgentHome/serverSessionSearchDirectory`` for the sessions that its server records. The Mac
/// app makes a second index over ``AgentHome/clientSessionSearchDirectory`` for the transcripts
/// of other agents that it showed. The two indexes share nothing.
///
/// The searcher keeps its catalog and its vectors in the folder of the index, with the
/// persistence option of the registry (`CatalogPersistence`, D207 step 5). The index keeps no
/// other file. At its start, the index reads the stored catalog with no embed, and makes its
/// list of sessions from the stored items, so a new process searches at once. A stored catalog
/// of an old format, of another embedding model or that is damaged is dropped by the registry:
/// the index then starts empty, and the next change of each session builds it again. Only one
/// index may use a folder at a time.
///
/// The host gives the chunks of each session (`SessionSearchChunker.chunks(of:dates:)` of
/// FoundationModelsACP) and the facts of the session. Each change gives the searcher only the
/// items that changed (`update(upserting:removing:)`): the new and changed items of the
/// session, and the ids of its items that are gone. The registry embeds only the new texts.
public actor TranscriptSearchIndex {
  /// The content of one session that the host gives to the index: the chunks of its transcript
  /// and its facts.
  public struct SessionContent: Sendable {
    /// The chunks of the transcript of the session, from `SessionSearchChunker.chunks(of:dates:)`.
    public let chunks: [SessionSearchChunk]

    /// The facts of the session.
    public let metadata: TranscriptSessionMetadata

    /// Makes the content of a session.
    ///
    /// - Parameters:
    ///   - chunks: The chunks of the transcript of the session.
    ///   - metadata: The facts of the session.
    public init(chunks: [SessionSearchChunk], metadata: TranscriptSessionMetadata) {
      self.chunks = chunks
      self.metadata = metadata
    }
  }

  /// The items of one indexed session.
  struct IndexedSession: Sendable {
    /// The session item.
    let sessionItem: TranscriptSearchItem

    /// The facts of the session that ``sessionItem`` holds.
    let metadata: TranscriptSessionMetadata

    /// The chunk items, in the order of the chunks.
    let chunkItems: [TranscriptSearchItem]

    /// The session item, then the chunk items.
    var items: [TranscriptSearchItem] {
      [sessionItem] + chunkItems
    }

    /// The turns of the session, from its chunk items.
    var turns: [TranscriptSearchTurn] {
      let chunks = chunkItems.compactMap { item -> SessionSearchChunk? in
        guard case .chunk(let chunk) = item.content else {
          return nil
        }
        return chunk
      }
      return TranscriptSearchTurn.turns(of: sessionItem.sessionId, chunks: chunks)
    }

    /// Makes the items of one session from its content.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - content: The chunks and the facts of the session.
    init(session: SessionId, content: SessionContent) {
      self.init(
        session: session, metadata: content.metadata,
        chunkItems: content.chunks.map { TranscriptSearchItem(chunk: $0, session: session) })
    }

    /// Makes the items of one session from its facts and its chunk items.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - metadata: The facts of the session.
    ///   - chunkItems: The chunk items of the session.
    init(
      session: SessionId, metadata: TranscriptSessionMetadata, chunkItems: [TranscriptSearchItem]
    ) {
      sessionItem = TranscriptSearchItem(session: session, metadata: metadata)
      self.metadata = metadata
      self.chunkItems = chunkItems
    }

    /// The same chunk items with a new session item.
    ///
    /// - Parameter metadata: The new facts of the session.
    /// - Returns: The items with the new session item.
    func replacingMetadata(with metadata: TranscriptSessionMetadata) -> IndexedSession {
      IndexedSession(session: sessionItem.sessionId, metadata: metadata, chunkItems: chunkItems)
    }
  }

  /// The folder of the index: the server folder or the client folder of the session search.
  public nonisolated let folder: URL

  /// The id of the embedding model of the stored catalog of an index with no embedder. Such a
  /// catalog has no vector, and an index with an embedder drops it.
  public static let keywordOnlyModelID = "keyword-only"

  /// The id of the embedding model of the embedder, or `nil` with no embedder. A change of the
  /// model makes the stored vectors of a catalog of no use, so the registry drops the stored
  /// catalog.
  public nonisolated let modelID: String?

  /// Tells whether the process can read a folder now with no prompt. The host gives the rule,
  /// so this package keeps no app path.
  public nonisolated let readableFolder: @Sendable (URL) -> Bool

  /// The subscribers of the changes of the index.
  private nonisolated let feed = TranscriptSearchChangeFeed()

  /// The one searcher over the catalog: the `.retrieval` mode with the default weights.
  private let searcher: MetadataSearcher<TranscriptSearchItem>

  /// The items of each indexed session, by session id.
  private var sessions: [SessionId: IndexedSession] = [:]

  /// The last write of a change to the searcher. Each write waits for the write before it, so
  /// the changes reach the searcher in the order of the changes of ``sessions``.
  private var lastWrite: Task<Void, Never>?

  /// Makes an index over the stored catalog of its folder. The call embeds nothing: the searcher
  /// reads the stored items and vectors, and the index makes its list of sessions from the
  /// stored items. A folder with no stored catalog gives an empty index.
  ///
  /// Each diagnostic of the registry is logged with ``ACPAgentTelemetry`` (a dropped stored
  /// catalog, a failed save), and then goes to `onDiagnostic`.
  ///
  /// - Parameters:
  ///   - folder: The folder of the index. The searcher keeps its catalog in it.
  ///   - embedder: The embedder of the items and the queries: the `embedding` slot of the
  ///     profile, or `nil` for the keyword signals only.
  ///   - modelID: The id of the embedding model of `embedder`, or `nil` with no embedder.
  ///   - readableFolder: Tells whether the process can read a folder now with no prompt.
  ///   - onDiagnostic: Gets each diagnostic of the registry after the log, or `nil` for none.
  public init(
    folder: URL,
    embedder: (any PooledEmbedding)?,
    modelID: String?,
    readableFolder: @escaping @Sendable (URL) -> Bool,
    onDiagnostic: (@Sendable (MetadataDiagnostic) -> Void)? = nil
  ) async {
    self.folder = folder
    self.modelID = modelID
    self.readableFolder = readableFolder
    searcher = await MetadataSearcher(
      persistence: CatalogPersistence(
        folder: folder, embeddingModelID: modelID ?? Self.keywordOnlyModelID),
      mode: .retrieval, embedder: embedder,
      onDiagnostic: { diagnostic in
        TranscriptSearchDiagnostics.log(diagnostic)
        onDiagnostic?(diagnostic)
      })
    let restored = Self.restoredSessions(from: await searcher.items())
    sessions = restored.sessions
    await write(upserting: [], removing: restored.strayIDs)
  }

  /// Returns when each change that the index got before this call is written to its folder, or
  /// the write failed. The shutdown of the agent calls it, so a quit keeps the last change.
  public func waitForSaves() async {
    await lastWrite?.value
    await searcher.waitForSaves()
  }

  /// Indexes one session: its session item and the chunk items of its chunks. The items replace
  /// the items that the index held for the session.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - chunks: The chunks of the transcript of the session, from
  ///     `SessionSearchChunker.chunks(of:dates:)`.
  ///   - metadata: The facts of the session.
  public func index(
    session: SessionId, chunks: [SessionSearchChunk], metadata: TranscriptSessionMetadata
  ) async {
    await index([session: SessionContent(chunks: chunks, metadata: metadata)])
  }

  /// Indexes a set of sessions and removes the items of other sessions, with one change of the
  /// catalog. The items of each session in `contents` replace the items that the index held for
  /// it. The searcher gets only the items that changed: each new item and each item whose
  /// content is not the held content, and the id of each held item that is gone. A session whose
  /// items did not change gives the searcher nothing. A reconcile gives each session of a folder
  /// in one call, so the searcher gets one update and not one update for each session.
  ///
  /// - Parameters:
  ///   - contents: The content of each session to index, by session id.
  ///   - removed: The sessions whose items to remove. A session that the index does not hold
  ///     changes nothing.
  public func index(_ contents: [SessionId: SessionContent], removing removed: Set<SessionId> = [])
    async
  {
    let removedHeld = removed.filter { sessions[$0] != nil && contents[$0] == nil }
    guard !contents.isEmpty || !removedHeld.isEmpty else {
      return
    }
    let indexed = Dictionary(
      uniqueKeysWithValues: contents.map {
        ($0.key, IndexedSession(session: $0.key, content: $0.value))
      })
    let changedTurns = Set(
      indexed.filter { session, new in sessions[session]?.chunkItems != new.chunkItems }.keys)
    let change = Self.catalogChange(
      from: sessions, indexing: indexed, removing: removedHeld)
    sessions.merge(indexed) { _, new in new }
    for session in removedHeld {
      sessions.removeValue(forKey: session)
    }
    await write(upserting: change.upserting, removing: change.removing)
    publishChanges(of: changedTurns.union(removedHeld))
  }

  /// Replaces only the session item of a session that the index holds: its chunk items stay as
  /// they are. A change of the session directory (a rename, the tags, the recap, an archive or
  /// an unarchive) gives the new facts here. A session that the index does not hold changes
  /// nothing, because a session with no indexed transcript gets its items from its history.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - metadata: The new facts of the session.
  public func update(session: SessionId, metadata: TranscriptSessionMetadata) async {
    guard let held = sessions[session], held.metadata != metadata else {
      return
    }
    let replaced = held.replacingMetadata(with: metadata)
    sessions[session] = replaced
    await write(upserting: [replaced.sessionItem], removing: [])
  }

  /// Removes each item of one session. A session that the index does not hold changes nothing.
  ///
  /// - Parameter session: The session.
  public func remove(session: SessionId) async {
    await index([:], removing: [session])
  }

  /// The items that the index holds for one session: the session item, then the chunk items in
  /// the order of the chunks. A session that the index does not hold has none.
  ///
  /// - Parameter session: The session.
  /// - Returns: The items of the session.
  public func items(of session: SessionId) -> [TranscriptSearchItem] {
    sessions[session]?.items ?? []
  }

  /// The facts of each session that the index holds, by session id. A reconcile reads the
  /// working folder of each session here, to find the sessions of a folder that it read.
  ///
  /// - Returns: The facts of each held session.
  public func indexedSessions() -> [SessionId: TranscriptSessionMetadata] {
    sessions.mapValues(\.metadata)
  }

  /// Makes a new stream of the changes of the index (D207 (i)). Each call gives a new stream of
  /// its own: the turns of each session whose chunks the index changed, and each session that
  /// the index removed, after the index applied the change. New facts of a session (a rename,
  /// the tags, the recap, an archive) change no turn, so they give no change. The stream ends
  /// when the index goes away.
  ///
  /// The index never waits for a subscriber. The stream holds the newest
  /// ``TranscriptSearchChangeFeed/defaultBufferLimit`` changes that its subscriber did not
  /// read, and it drops the oldest ones. A subscriber that lost changes reads ``allTurns()``.
  ///
  /// - Returns: The stream of the changes after this call.
  public nonisolated func changes() -> AsyncStream<TranscriptSearchChange> {
    feed.subscribe()
  }

  /// The turns of one session, from its chunk items: the same turns that a change of the
  /// session gives. A session that the index does not hold has none.
  ///
  /// - Parameter session: The session.
  /// - Returns: The turns of the session, in the order of the turns.
  public func turns(of session: SessionId) -> [TranscriptSearchTurn] {
    sessions[session]?.turns ?? []
  }

  /// The turns of each session that the index holds, for a new index of the host (for
  /// example a new Spotlight index): the sessions in the order of their ids, and the turns of
  /// each session in their order.
  ///
  /// - Returns: The turns.
  public func allTurns() -> [TranscriptSearchTurn] {
    sortedSessionIDs.flatMap { sessions[$0]?.turns ?? [] }
  }

  /// The matches of the searcher for a query: one match for each item that a signal ranked, in
  /// the order of the fused score, highest first. The searcher has no filter, so the search asks
  /// for as many matches as the catalog has items, and the caller filters the matches.
  ///
  /// - Parameter query: The search text.
  /// - Returns: The matches of the registry.
  /// - Throws: An error of the searcher. The `.retrieval` mode gives none.
  public func matches(for query: String) async throws -> [Match<TranscriptSearchItem>] {
    try await searcher.search(intent: query, limit: catalog.count)
  }

  /// The items of the catalog: the items of each session, in the order of the session ids.
  var catalog: [TranscriptSearchItem] {
    sortedSessionIDs.flatMap { sessions[$0]?.items ?? [] }
  }

  /// The ids of the indexed sessions, in their order.
  private var sortedSessionIDs: [SessionId] {
    Self.sorted(sessions.keys)
  }

  /// Session ids in their order.
  ///
  /// - Parameter ids: The session ids.
  /// - Returns: The ids, in the order of their raw values.
  private static func sorted(_ ids: some Sequence<SessionId>) -> [SessionId] {
    ids.sorted { $0.rawValue < $1.rawValue }
  }

  /// Gives the subscribers the change of each session that a change of the catalog touched, in
  /// the order of the session ids. The change gives the state of the session now: a later change
  /// can have come while the catalog went to the searcher, so an older state never comes after
  /// a newer one. A session that the index holds gives its turns, and another session gives
  /// its removal.
  ///
  /// - Parameter touched: The sessions whose chunk items the change of the catalog changed.
  private func publishChanges(of touched: Set<SessionId>) {
    feed.publish(
      Self.sorted(touched).map { session in
        guard let held = sessions[session] else {
          return .removed(session: session)
        }
        return .indexed(session: session, turns: held.turns)
      })
  }

  /// Gives the changed items of one change to the searcher (`update(upserting:removing:)`), and
  /// returns when the searcher applied them. A change with no item does nothing.
  ///
  /// An actor runs another call while this one waits for the searcher. Thus each write waits
  /// for the write before it, and the searcher gets the changes in the order that the index
  /// made them: a later change of an item never comes before an earlier one.
  ///
  /// - Parameters:
  ///   - upserting: The new and the changed items.
  ///   - removing: The ids of the items that are gone.
  private func write(upserting: [TranscriptSearchItem], removing: [String]) async {
    guard !upserting.isEmpty || !removing.isEmpty else {
      return
    }
    let previous = lastWrite
    let searcher = searcher
    let write = Task {
      await previous?.value
      await searcher.update(upserting: upserting, removing: removing)
    }
    lastWrite = write
    await write.value
  }
}
