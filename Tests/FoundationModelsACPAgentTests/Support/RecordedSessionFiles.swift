import Foundation
import Testing

/// The layout of the recording root of Router and the walk over it.
///
/// Router records each session in a folder of its own, `<root>/<sessionId>/`,
/// with files of fixed names inside it. The readers of those files
/// (``RecordedTranscriptFile``, ``RecordedSessionIndexFile``) share this one
/// home for the folder layout and for the walk, so a change of the layout is
/// one change.
enum RecordedSessionFiles {
  /// The file of one session: `<root>/<sessionId>/<fileName>`.
  ///
  /// - Parameters:
  ///   - fileName: The name of the file inside the session folder.
  ///   - sessionId: The session, whose id names its folder.
  ///   - root: The recording root that holds the folder.
  /// - Returns: The file URL, whether or not anything stands there.
  static func fileURL(named fileName: String, ofSession sessionId: String, under root: URL) -> URL {
    root
      .appendingPathComponent(sessionId, isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  /// Every file named `fileName` under `root`, at any depth.
  ///
  /// - Parameters:
  ///   - fileName: The name of the files to keep.
  ///   - root: The recording root to walk.
  /// - Returns: The file URLs, in walk order.
  /// - Throws: A failed requirement when `root` cannot be walked, so an
  ///   unreadable root never reads as a root with no files.
  static func files(named fileName: String, under root: URL) throws -> [URL] {
    let walker = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return walker.compactMap { $0 as? URL }.filter { $0.lastPathComponent == fileName }
  }
}
