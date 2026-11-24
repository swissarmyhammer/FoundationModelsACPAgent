import FoundationModelsACP

/// The reads of a host on the changes of a transcript search index (D207 (i), ^twh8ceh): the
/// change stream, the turns of one session, and all turns.
///
/// The agent keeps its index of the server sessions internal. A host (for example the Mac app,
/// for its Spotlight items) gets this value from ``RoutedACPAgent/transcriptSearchChanges`` or
/// ``ComposedAgent/transcriptSearchChanges``. The value holds the index privately, so the host
/// cannot write to the index (`index`, `update`, `remove`, `load`) and cannot cast the value to
/// the index.
public struct TranscriptSearchChanges: Sendable {
  /// The index that this value reads.
  private let index: TranscriptSearchIndex

  /// Makes the reads of an index.
  ///
  /// - Parameter index: The index to read.
  init(index: TranscriptSearchIndex) {
    self.index = index
  }

  /// Makes a new stream of the changes of the index. Each call gives a new stream of its own.
  /// See ``TranscriptSearchIndex/changes()``.
  ///
  /// - Returns: The stream of the changes after this call.
  public func changes() -> AsyncStream<TranscriptSearchChange> {
    index.changes()
  }

  /// The turns of one session. See ``TranscriptSearchIndex/turns(of:)``.
  ///
  /// - Parameter session: The session.
  /// - Returns: The turns of the session, in the order of the turns.
  public func turns(of session: SessionId) async -> [TranscriptSearchTurn] {
    await index.turns(of: session)
  }

  /// The stamp of the turns of each session (``TranscriptSearchIndex/turnStamps()``, D214). The
  /// host compares each stamp with the stamp that it keeps, and reads ``turns(of:)`` only for a
  /// session whose stamp changed. A session with no stamp is not in the index.
  ///
  /// - Returns: The stamp of each session.
  public func stamps() async -> [SessionId: ContentStamp] {
    await index.turnStamps()
  }

  /// The turns of each session that the index holds. See ``TranscriptSearchIndex/allTurns()``.
  ///
  /// - Returns: The turns.
  public func allTurns() async -> [TranscriptSearchTurn] {
    await index.allTurns()
  }
}

extension RoutedACPAgent {
  /// The reads of a host on the changes of the transcript search index of the server
  /// (``transcriptSearchIndex``): the change stream, the turns of one session, and all turns.
  /// The host cannot write to the index through this value.
  public nonisolated var transcriptSearchChanges: TranscriptSearchChanges {
    TranscriptSearchChanges(index: transcriptSearchIndex)
  }
}
