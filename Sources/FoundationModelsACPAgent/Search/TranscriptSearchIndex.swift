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
/// of other agents that it showed. The two indexes share nothing. The index keeps no file in its
/// folder yet: the searcher keeps its catalog in memory.
///
/// The host gives the chunks of each session (`SessionSearchChunker.chunks(of:dates:)` of
/// FoundationModelsACP) and the facts of the session. Each change gives the whole catalog to
/// the searcher (`update(items:)`), and the registry embeds only the items whose text changed.
public actor TranscriptSearchIndex {
  /// The items of one indexed session.
  private struct IndexedSession: Sendable {
    /// The session item.
    let sessionItem: TranscriptSearchItem

    /// The chunk items, in the order of the chunks.
    let chunkItems: [TranscriptSearchItem]

    /// The session item, then the chunk items.
    var items: [TranscriptSearchItem] {
      [sessionItem] + chunkItems
    }
  }

  /// The folder of the index: the server folder or the client folder of the session search.
  public nonisolated let folder: URL

  /// The id of the embedding model of the embedder, or `nil` with no embedder. A change of the
  /// model makes the stored vectors of a catalog of no use.
  public nonisolated let modelID: String?

  /// Tells whether the process can read a folder now with no prompt. The host gives the rule,
  /// so this package keeps no app path.
  public nonisolated let readableFolder: @Sendable (URL) -> Bool

  /// The one searcher over the catalog: the `.retrieval` mode with the default weights.
  private let searcher: MetadataSearcher<TranscriptSearchItem>

  /// The items of each indexed session, by session id.
  private var sessions: [SessionId: IndexedSession] = [:]

  /// The number of changes of ``sessions``. A change of the catalog that a later change overtook
  /// gives the catalog to the searcher again (``publishCatalog()``).
  private var catalogVersion = 0

  /// Makes an empty index. The call embeds nothing and starts no task.
  ///
  /// - Parameters:
  ///   - folder: The folder of the index.
  ///   - embedder: The embedder of the items and the queries: the `embedding` slot of the
  ///     profile, or `nil` for the keyword signals only.
  ///   - modelID: The id of the embedding model of `embedder`, or `nil` with no embedder.
  ///   - readableFolder: Tells whether the process can read a folder now with no prompt.
  public init(
    folder: URL,
    embedder: (any PooledEmbedding)?,
    modelID: String?,
    readableFolder: @escaping @Sendable (URL) -> Bool
  ) {
    self.folder = folder
    self.modelID = modelID
    self.readableFolder = readableFolder
    searcher = MetadataSearcher(items: [], mode: .retrieval, embedder: embedder)
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
    sessions[session] = IndexedSession(
      sessionItem: TranscriptSearchItem(session: session, metadata: metadata),
      chunkItems: chunks.map { TranscriptSearchItem(chunk: $0, session: session) })
    await publishCatalog()
  }

  /// Removes each item of one session. A session that the index does not hold changes nothing.
  ///
  /// - Parameter session: The session.
  public func remove(session: SessionId) async {
    guard sessions.removeValue(forKey: session) != nil else {
      return
    }
    await publishCatalog()
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
  private var catalog: [TranscriptSearchItem] {
    sessions.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { sessions[$0]?.items ?? [] }
  }

  /// Gives the catalog to the searcher after a change.
  ///
  /// An actor runs another call while this one waits for the searcher, so a later change can
  /// give its catalog first, and this call then gives an older catalog. Thus each call gives the
  /// catalog again until no change came while it waited: the last call that returns gives the
  /// newest catalog. The registry does no work for a catalog with the same content.
  private func publishCatalog() async {
    catalogVersion += 1
    var publishedVersion: Int
    repeat {
      publishedVersion = catalogVersion
      await searcher.update(items: catalog)
    } while publishedVersion != catalogVersion
  }
}
