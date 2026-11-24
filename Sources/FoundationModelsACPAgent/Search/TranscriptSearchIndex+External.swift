import Foundation
import FoundationModelsExtras
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool

/// The external items of the transcript search index (D212, design sections 5.2 and 6).
///
/// The index holds one external item for each typed session of another agent, such as Claude
/// Code or Codex, that the index of the external sessions (``ExternalSessionIndex``) has read.
/// The id of the item is `external:<source>/<id>`, and its block is the index fields: the
/// title, the first prompt, the last prompt, the folder and the branch. An automated session
/// gets no item, so the embedder does not embed the many automated sessions. No item reads a
/// session file: the items hold only what the index of the external sessions holds.
///
/// The items go into the same `MetadataSearcher` as the other items, so the same BM25, trigram
/// and cosine signals rank them. They are not sessions of the index: the session filters of a
/// search never admit them, so an external item is never a session result. The search of
/// Multitool gives them in ``FoundationModelsMultitool/SessionSearchPage/externalSessions``.
extension TranscriptSearchIndex {
  /// Replaces the external items with the items of some sessions: a session that the index
  /// holds no item for gets an item, a session whose index fields changed gets a new item, and
  /// each other held external item goes. Only a typed session in the state `read` gets an item.
  ///
  /// - Parameter summaries: Each session of the index of the external sessions now.
  func replaceExternalSessions(with summaries: [ExternalSessionSummary]) async {
    let kept = Set(
      summaries.filter(Self.getsExternalItem).map { TranscriptSearchItem.externalID(of: $0.id) })
    await changeExternalSessions(
      upserting: summaries, removing: externalItems.keys.filter { !kept.contains($0) })
  }

  /// Applies one change of the index of the external sessions to the external items: each
  /// changed session gets a new item, and each removed session loses its item. A changed
  /// session that is automated, or that is not in the state `read`, loses its item.
  ///
  /// - Parameters:
  ///   - changed: The sessions that a read added or changed.
  ///   - removed: The sessions whose files are gone.
  func updateExternalSessions(changed: [ExternalSessionSummary], removed: [ExternalSessionID])
    async
  {
    let dropped = changed.filter { !Self.getsExternalItem($0) }.map(\.id) + removed
    await changeExternalSessions(
      upserting: changed, removing: dropped.map(TranscriptSearchItem.externalID(of:)))
  }

  /// The sessions of the external items that the index holds now, in the order of their item
  /// ids.
  ///
  /// - Returns: The sessions.
  func externalSessions() async -> [ExternalSessionSummary] {
    await load()
    return externalItems.keys.sorted().compactMap { externalItems[$0]?.externalSummary }
  }

  /// The external results of the matches of a search: each match of an external item that
  /// passes the filters of the facts and of the text, in the order of the matches (the best
  /// score first), at most ``FoundationModelsMultitool/ExternalSessionSearchResult/maximumCount``.
  ///
  /// - Parameters:
  ///   - matches: The matches of the registry for the ranking text of the query.
  ///   - filter: The filters of the search.
  ///   - queryTerms: The terms of the ranking text, as `Tokenizer.tokenize(text:)` gives them.
  /// - Returns: The results.
  static func externalResults(
    of matches: [Match<TranscriptSearchItem>], filter: TranscriptSearchFilter,
    queryTerms: Set<String>
  ) -> [ExternalSessionSearchResult] {
    var results: [ExternalSessionSearchResult] = []
    for match in matches where results.count < ExternalSessionSearchResult.maximumCount {
      guard let summary = match.item.externalSummary, filter.admitsFacts(of: match.item),
        filter.admitsText(of: match.item)
      else {
        continue
      }
      results.append(
        ExternalSessionSearchResult(
          session: summary, score: match.score,
          field: bestField(of: summary, queryTerms: queryTerms)))
    }
    return results
  }

  /// The index field of a session that holds the most query terms. A field with an equal count
  /// that comes first in the block wins. When no field holds a whole term, the first field
  /// whose text holds a term as a part of a word wins, for a match of the trigram signal. With
  /// no such field, the match is of the cosine signal only, and the field is `nil`.
  ///
  /// - Parameters:
  ///   - summary: The session.
  ///   - queryTerms: The query terms.
  /// - Returns: The name of the field, or `nil`.
  static func bestField(of summary: ExternalSessionSummary, queryTerms: Set<String>) -> String? {
    let fields = TranscriptSearchItem.externalFields(of: summary)
    var best: (name: String, count: Int)?
    for field in fields {
      let count = Set(Tokenizer.tokenize(text: field.text)).intersection(queryTerms).count
      if count > (best?.count ?? 0) {
        best = (field.name, count)
      }
    }
    if let best {
      return best.name
    }
    return fields.first { field in
      let text = field.text.lowercased()
      return queryTerms.contains { !$0.isEmpty && text.contains($0) }
    }?.name
  }

  /// Tells whether a session of another agent gets an external item: a typed session (not
  /// automated) in the state `read`.
  ///
  /// - Parameter summary: The session.
  /// - Returns: `true` when the session gets an item.
  static func getsExternalItem(_ summary: ExternalSessionSummary) -> Bool {
    summary.state == .read && !summary.isAutomated
  }

  /// Gives the changed external items to the searcher. Only an item whose content is not the
  /// held content goes to the searcher, so an unchanged session embeds nothing again.
  ///
  /// - Parameters:
  ///   - summaries: The sessions whose items to add or to replace. A session that gets no item
  ///     changes nothing here.
  ///   - removed: The ids of the items to remove. An id that the index does not hold changes
  ///     nothing.
  private func changeExternalSessions(
    upserting summaries: [ExternalSessionSummary], removing removed: [String]
  ) async {
    let searcher = await loadedSearcher()
    let upserting = summaries.filter(Self.getsExternalItem)
      .map(TranscriptSearchItem.init(external:))
      .filter { externalItems[$0.id] != $0 }
    let removing = removed.filter { externalItems[$0] != nil }
    for item in upserting {
      externalItems[item.id] = item
    }
    for id in removing {
      externalItems.removeValue(forKey: id)
    }
    await write(to: searcher, upserting: upserting, removing: removing)
  }
}

extension TranscriptSearchItem {
  /// True for an external item: a session of another agent.
  var isExternal: Bool {
    externalSummary != nil
  }

  /// The session of another agent of an external item, or `nil` for another item.
  var externalSummary: ExternalSessionSummary? {
    guard case .external(let summary) = content else {
      return nil
    }
    return summary
  }
}
