import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The reader that gives a tool the recorded events of a session, from the
/// session folders on disk. The agent gives one reader to each session that
/// it makes or restores, so a tool reads a transcript through
/// ``ToolContext/transcript(of:)``.
///
/// **Risk.** Any tool that runs in a session of the agent can read the
/// transcript of every session that this reader reaches. MCP tools are
/// included. This reader applies no tree rule and checks no owner: a tool
/// reads a session that is not its own, and a session of another project. A
/// transcript holds the prompts, the answers, the tool calls and their
/// results. So it can hold a secret, for example a token that a user typed or
/// that a tool printed. Give a tool to a session only when you trust it with
/// every transcript of the registered projects.
///
/// **Disk only.** The reader gives what is on disk. It does not flush, so a
/// running session can lack its latest events, and the reader gives no error
/// for that.
///
/// **How it finds a session.** Each session has one folder, named by its id,
/// under the recording root of its project. The reader gets the roots of the
/// registered projects from `recordingRoots`, looks for the folder of the id
/// in each, and keeps the folder of the id after the first hit. A later read
/// of the same id reads that one folder with
/// ``TranscriptEvent/read(sessionDirectory:)``, and it neither resolves the
/// roots nor merges the events of a whole project. An id that no root holds
/// throws ``SessionTranscriptError/notFound(_:)``; the roots are resolved
/// again at the next read of that id, so a session that a new project holds
/// is found. A project that the reader cannot resolve gives no root, so its
/// sessions are not found.
struct RecordedSessionTranscriptReader: SessionTranscriptReader {
  /// Gives the recording roots to search, one for each registered project.
  typealias RecordingRoots = @Sendable () async -> [URL]

  /// The ids that the reader found, and the folder of each.
  private actor FolderCache {
    /// The folder of each id that was found.
    private var folders: [ULID: URL] = [:]

    /// The folder that was found for `id`, or `nil`.
    func folder(for id: ULID) -> URL? {
      folders[id]
    }

    /// Keeps the folder of `id`.
    func remember(_ folder: URL, for id: ULID) {
      folders[id] = folder
    }

    /// Drops the folder of `id`, for example when the folder is gone.
    func forget(_ id: ULID) {
      folders.removeValue(forKey: id)
    }
  }

  /// Gives the recording roots to search.
  private let recordingRoots: RecordingRoots

  /// The folders that were found.
  private let cache = FolderCache()

  /// Makes a reader.
  ///
  /// - Parameter recordingRoots: Gives the recording roots to search, one
  ///   for each registered project. The reader calls it only for an id
  ///   that it has no folder for.
  init(recordingRoots: @escaping RecordingRoots) {
    self.recordingRoots = recordingRoots
  }

  /// Gives the transcript of a session from its folder.
  ///
  /// - Parameter sessionID: The session to read.
  /// - Returns: One entry for each recorded event, in the `(ts, seq)` order
  ///   of the recorder. A session with no event on disk gives no entry.
  /// - Throws: ``SessionTranscriptError/notFound(_:)`` when no recording
  ///   root holds a folder for `sessionID`, and the error of the read of the
  ///   folder: a recording from a newer Router, or a file that cannot be
  ///   read.
  func transcript(of sessionID: ULID) async throws -> SessionTranscript {
    let folder = try await folder(of: sessionID)
    let events = try TranscriptEvent.read(sessionDirectory: folder)
    return SessionTranscript(
      sessionID: sessionID, entries: try events.map(TranscriptEntryMapping.entry(from:)))
  }

  /// The folder of a session: the kept folder when it still exists, else
  /// the first folder that a recording root holds.
  private func folder(of sessionID: ULID) async throws -> URL {
    if let kept = await cache.folder(for: sessionID) {
      if Self.isDirectory(kept) {
        return kept
      }
      await cache.forget(sessionID)
    }
    for root in await recordingRoots() {
      let candidate = root.appendingPathComponent(sessionID.description, isDirectory: true)
      if Self.isDirectory(candidate) {
        await cache.remember(candidate, for: sessionID)
        return candidate
      }
    }
    throw SessionTranscriptError.notFound(sessionID)
  }

  /// Whether a folder exists at `url`.
  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
