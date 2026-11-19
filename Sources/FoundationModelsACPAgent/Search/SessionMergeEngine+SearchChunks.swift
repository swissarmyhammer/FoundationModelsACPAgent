import FoundationModelsACP

extension SessionMergeEngine {
  /// The search chunks of this retained history (D207 (a)): the chunks that the
  /// `SessionSearchChunker` of FoundationModelsACP makes of its entries, with the date that the
  /// history recorded for each entry (``recordedEntryDates``). This package makes no chunk of
  /// its own, and the same history always gives the same chunks.
  var searchChunks: [SessionSearchChunk] {
    SessionSearchChunker.chunks(of: entries, dates: recordedEntryDates)
  }
}
