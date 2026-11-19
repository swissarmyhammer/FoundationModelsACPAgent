import Foundation

/// The facts of a session that the session directory shows now, for the filters of a search of
/// the transcripts (D207 (e)). The directory gives them at search time, so an archive changes
/// the results at once, with no change to the items of the index.
public struct TranscriptSearchVisibleSession: Hashable, Sendable {
  /// The working folder of the session.
  public let folder: URL

  /// True when the session is archived (D204).
  public let isArchived: Bool

  /// Makes the facts of a visible session.
  ///
  /// - Parameters:
  ///   - folder: The working folder of the session.
  ///   - isArchived: True when the session is archived.
  public init(folder: URL, isArchived: Bool) {
    self.folder = folder
    self.isArchived = isArchived
  }
}
