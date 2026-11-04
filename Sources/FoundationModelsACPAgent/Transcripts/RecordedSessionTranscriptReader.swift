import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The reader that gives a tool the recorded events of a session, from the session folders on
/// disk. The agent gives one reader to every session that it makes or restores, so a tool reads a
/// transcript through ``ToolContext/transcript(of:)``.
///
/// **Risk.** Any tool that runs in a session of the agent can read the transcript of every session
/// that this reader reaches. MCP tools are included. The reader applies no tree rule and checks no
/// owner: a tool reads a session that is not its own, and a session of another project. A
/// transcript holds the prompts, the answers, the tool calls and their results. So it can hold a
/// secret, for example a token that a user typed or that a tool printed.
///
/// **No switch, no redaction.** The agent gives the reader to every session. There is no setting
/// that turns it off, so a user cannot keep a tool from reading. The agent also redacts nothing:
/// Router has a redact hook for the recorder (`GatingRecorder`), and no code of the agent sets it.
/// So the reader gives the text as the recorder wrote it. Add a tool to a session only when you
/// trust it with every transcript of the registered projects and of the composed sessions.
///
/// **Disk only.** The reader gives what is on disk. It does not flush, so a running session can
/// lack its latest events, and the reader gives no error for that.
///
/// **How it finds a session.** Each session has one folder, named by its id, under a recording
/// root. The reader gets the roots from `recordingRoots`, looks for the folder of the id in each,
/// and keeps the folder of the id after the first hit. A later read of the same id reads that one
/// folder with ``TranscriptEvent/read(sessionDirectory:)``, and it neither resolves the roots nor
/// merges the events of a whole project. Reads of one id at the same time share one search. An id
/// that no root holds is not kept, so a session of a new project is found at the next read.
///
/// **What is not found.** ``SessionTranscriptError/notFound(_:)`` is the error for an id that no
/// root holds, for a folder that was deleted, and for a folder that holds no `transcript.jsonl`
/// (a session that had no prompt yet). A root that cannot be resolved gives no folder, so the
/// sessions under it are not found.
struct RecordedSessionTranscriptReader: SessionTranscriptReader {
  /// Gives the recording roots to search.
  typealias RecordingRoots = @Sendable () async -> [URL]

  /// The name of the file of the events in a session folder.
  private static let transcriptFileName = "transcript.jsonl"

  /// The folders that were found, and the searches that run now.
  private actor FolderCache {
    /// The folder of each id that was found.
    private var folders: [ULID: URL] = [:]

    /// The search of each id that runs now.
    private var searches: [ULID: Task<URL?, Never>] = [:]

    /// The folder of `id`: the kept folder while it exists, else the result of one search.
    /// A search that runs for `id` is shared by every caller.
    ///
    /// - Parameters:
    ///   - id: The session.
    ///   - search: Finds the folder, or gives `nil`.
    func folder(for id: ULID, search: @escaping @Sendable () async -> URL?) async -> URL? {
      if let kept = folders[id] {
        if RecordedSessionTranscriptReader.isDirectory(kept) {
          return kept
        }
        folders.removeValue(forKey: id)
      }
      let running = searches[id] ?? Task { await search() }
      searches[id] = running
      let found = await running.value
      searches.removeValue(forKey: id)
      if let found {
        folders[id] = found
      }
      return found
    }
  }

  /// Gives the recording roots to search.
  private let recordingRoots: RecordingRoots

  /// The folders that were found.
  private let cache = FolderCache()

  /// Makes a reader.
  ///
  /// - Parameter recordingRoots: Gives the recording roots to search. The reader calls it only for
  ///   an id that it has no folder for.
  init(recordingRoots: @escaping RecordingRoots) {
    self.recordingRoots = recordingRoots
  }

  /// Gives the transcript of a session from its folder.
  ///
  /// - Parameter sessionID: The session to read.
  /// - Returns: One entry for each recorded event, in the `(ts, seq)` order of the recorder.
  /// - Throws: ``SessionTranscriptError/notFound(_:)`` when no recording root holds a folder for
  ///   `sessionID`, when the folder holds no `transcript.jsonl`, or when the folder is deleted
  ///   during the read. It also throws the error of the read of the folder: a recording from a newer
  ///   Router, or a file that cannot be read.
  func transcript(of sessionID: ULID) async throws -> SessionTranscript {
    let folder = try await folder(of: sessionID)
    let events = try TranscriptEvent.read(sessionDirectory: folder)
    guard Self.hasTranscript(in: folder) else {
      throw SessionTranscriptError.notFound(sessionID)
    }
    return SessionTranscript(
      sessionID: sessionID, entries: try events.map(TranscriptEntryMapping.entry(from:)))
  }

  /// The folder of a session that holds a transcript file.
  private func folder(of sessionID: ULID) async throws -> URL {
    let roots = recordingRoots
    let found = await cache.folder(for: sessionID) {
      for root in await roots() {
        let candidate = root.appendingPathComponent(sessionID.description, isDirectory: true)
        if Self.isDirectory(candidate) {
          return candidate
        }
      }
      return nil
    }
    guard let found, Self.hasTranscript(in: found) else {
      throw SessionTranscriptError.notFound(sessionID)
    }
    return found
  }

  /// Whether the folder holds the transcript file.
  private static func hasTranscript(in folder: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: folder.appendingPathComponent(transcriptFileName, isDirectory: false).path)
  }

  /// Whether a folder exists at `url`.
  fileprivate static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
