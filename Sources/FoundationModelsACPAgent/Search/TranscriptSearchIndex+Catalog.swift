import Foundation
import FoundationModelsACP
import FoundationModelsMetadataRegistry

extension TranscriptSearchIndex {
  /// The sessions that the index makes from a stored catalog.
  struct RestoredSessions: Sendable {
    /// The items of each session that has a session item, by session id.
    let sessions: [SessionId: IndexedSession]

    /// The ids of the chunk items whose session has no session item. The index removes them
    /// from the searcher, because no change of the index can remove them later.
    let strayIDs: [String]
  }

  /// The items that one change of the catalog gives to the searcher.
  struct CatalogChange: Sendable {
    /// The new and the changed items, in the order of the session ids and then of the items of
    /// each session.
    let upserting: [TranscriptSearchItem]

    /// The ids of the items that are gone.
    let removing: [String]
  }

  /// Makes the list of sessions of the index from the items of a stored catalog.
  ///
  /// The items of a session are its session item and its chunk items. The chunk items go in
  /// the order of their chunk ordinals, because the registry adds a new item at the end of its
  /// catalog. A session with no session item is not restored: its chunk items are stray.
  ///
  /// - Parameter items: The items of the stored catalog, in the order of the catalog.
  /// - Returns: The sessions and the stray ids.
  static func restoredSessions(from items: [TranscriptSearchItem]) -> RestoredSessions {
    var sessions: [SessionId: IndexedSession] = [:]
    var strayIDs: [String] = []
    for (session, sessionItems) in Dictionary(grouping: items, by: \.sessionId) {
      guard let metadata = sessionItems.lazy.compactMap(\.storedSessionMetadata).first else {
        strayIDs += sessionItems.map(\.id)
        continue
      }
      let chunkItems = sessionItems.filter { $0.storedChunkOrdinal != nil }.sorted {
        ($0.storedChunkOrdinal ?? .zero) < ($1.storedChunkOrdinal ?? .zero)
      }
      sessions[session] = IndexedSession(
        session: session, metadata: metadata, chunkItems: chunkItems)
    }
    return RestoredSessions(sessions: sessions, strayIDs: strayIDs.sorted())
  }

  /// The items that a change of the catalog gives to the searcher: for each indexed session,
  /// each item that the index does not hold with the same content, and the id of each held item
  /// that the new items do not have; for each removed session, the id of each held item.
  ///
  /// - Parameters:
  ///   - held: The sessions that the index holds before the change.
  ///   - indexed: The new items of each indexed session.
  ///   - removed: The held sessions to remove.
  /// - Returns: The changed items and the removed ids.
  static func catalogChange(
    from held: [SessionId: IndexedSession], indexing indexed: [SessionId: IndexedSession],
    removing removed: Set<SessionId>
  ) -> CatalogChange {
    var upserting: [TranscriptSearchItem] = []
    var removing: [String] = []
    for session in indexed.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      let newItems = indexed[session]?.items ?? []
      let heldItems = held[session]?.items ?? []
      let heldByID = Dictionary(heldItems.map { ($0.id, $0) }) { first, _ in first }
      let newIDs = Set(newItems.map(\.id))
      upserting += newItems.filter { heldByID[$0.id] != $0 }
      removing += heldItems.map(\.id).filter { !newIDs.contains($0) }
    }
    for session in removed.sorted(by: { $0.rawValue < $1.rawValue }) {
      removing += held[session]?.items.map(\.id) ?? []
    }
    return CatalogChange(upserting: upserting, removing: removing)
  }
}

extension TranscriptSearchItem {
  /// The facts of a session item, or `nil` for a chunk item.
  fileprivate var storedSessionMetadata: TranscriptSessionMetadata? {
    guard case .session(let metadata) = content else {
      return nil
    }
    return metadata
  }

  /// The ordinal of a chunk item, or `nil` for a session item.
  fileprivate var storedChunkOrdinal: Int? {
    guard case .chunk(let chunk) = content else {
      return nil
    }
    return chunk.ordinal
  }
}

/// The log of the diagnostics of the searcher of the transcript search index.
enum TranscriptSearchDiagnostics {
  /// Logs one diagnostic of the registry with ``ACPAgentTelemetry``. A dropped stored catalog,
  /// a failed save and a duplicate id are warnings. The other diagnostics (no embedder, an embed
  /// that catches up) are normal states, and are debug records. The record holds the case name
  /// and counts only, never the content of an item.
  ///
  /// - Parameter diagnostic: The diagnostic.
  static func log(_ diagnostic: MetadataDiagnostic) {
    let logger = ACPAgentTelemetry.logger(.transcriptSearch)
    switch diagnostic {
    case .storedCatalogDropped(let reason):
      logger.warning(
        "The stored transcript search catalog was dropped. The next changes build it again.",
        metadata: [diagnosticCaseKey: "storedCatalogDropped", dropReasonKey: "\(reason.rawValue)"])
    case .catalogSaveFailed:
      logger.warning(
        "The transcript search catalog was not saved. The stored catalog keeps its last state.",
        metadata: [diagnosticCaseKey: "catalogSaveFailed"])
    case .duplicateId:
      logger.warning(
        "The transcript search catalog got a duplicate item id. The first item stays.",
        metadata: [diagnosticCaseKey: "duplicateId"])
    case .embedCatchUp(let pending, let total):
      logger.debug(
        "The transcript search embeds its new items.",
        metadata: [
          diagnosticCaseKey: "embedCatchUp", pendingCountKey: "\(pending)",
          catalogSizeKey: "\(total)",
        ])
    case .embeddingUnavailable:
      logger.debug(
        "The transcript search ranks with the keyword signals only.",
        metadata: [diagnosticCaseKey: "embeddingUnavailable"])
    case .unknownSelectedId, .retrievalCut:
      // The `.retrieval` mode of the index runs no selection tier, so these never come.
      logger.debug(
        "The transcript search searcher reported a selection diagnostic.",
        metadata: [diagnosticCaseKey: "selection"])
    }
  }

  /// The log metadata key of the case of a diagnostic.
  private static let diagnosticCaseKey = "registry.diagnostic"

  /// The log metadata key of the reason of a dropped stored catalog.
  private static let dropReasonKey = "registry.drop_reason"

  /// The log metadata key of the number of items that wait for an embed.
  private static let pendingCountKey = "registry.embed_pending"

  /// The log metadata key of the number of items of the catalog.
  private static let catalogSizeKey = "registry.catalog_size"
}
