import Foundation

/// The session files of the source agents of an import (D209), for the fixture roots of the
/// import tests.
///
/// Each suite gives the root, the session id and the working folder. Thus the suites share one
/// form of each session file, and a change of the format is made in one place.
enum ImportSessionFiles {
  /// The month of the records of a Codex session file, `<year>-<month>`.
  private static let codexMonth = "2026-11"

  /// The folder of the Codex session files in the Codex root.
  private static let codexSessionsFolder = "sessions"

  /// The folder of the archived Codex session files in the Codex root.
  private static let codexArchiveFolder = "archived_sessions"

  // MARK: - Claude Code

  /// The bytes of a Claude Code session file: one user record, and a custom title record when
  /// a title is given.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - folder: The working folder of the session.
  ///   - title: The custom title, or `nil` for no title record.
  /// - Returns: The bytes of the file.
  static func claudeCode(id: String, folder: URL, title: String? = nil) -> Data {
    let user = """
      {"type":"user","uuid":"u-1","sessionId":"\(id)","timestamp":"2026-11-01T10:00:01.000Z","cwd":"\(folder.path)","message":{"role":"user","content":"Fix the test."}}
      """
    let titleLine = title.map {
      #"{"type":"custom-title","customTitle":"\#($0)","sessionId":"\#(id)"}"#
    }
    return Data(([user] + [titleLine].compactMap { $0 } + [""]).joined(separator: "\n").utf8)
  }

  /// The file of a Claude Code session in a root: `projects/<project>/<id>.jsonl`. The name of
  /// the project folder is the path of the working folder with each `/` changed to `-`, as
  /// Claude Code names it.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - folder: The working folder of the session.
  ///   - root: The Claude Code root (`~/.claude`).
  /// - Returns: The file.
  static func claudeCodeFile(of id: String, folder: URL, in root: URL) -> URL {
    let project = folder.path.replacingOccurrences(of: "/", with: "-")
    return root.appendingPathComponent("projects/\(project)/\(id).jsonl")
  }

  /// Writes a Claude Code session file into a root.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - folder: The working folder of the session.
  ///   - title: The custom title, or `nil` for no title record.
  ///   - root: The Claude Code root (`~/.claude`).
  /// - Returns: The file.
  /// - Throws: The error of the write.
  @discardableResult
  static func writeClaudeCode(id: String, folder: URL, title: String? = nil, in root: URL)
    throws -> URL
  {
    let file = claudeCodeFile(of: id, folder: folder, in: root)
    try write(claudeCode(id: id, folder: folder, title: title), to: file)
    return file
  }

  // MARK: - Codex

  /// The bytes of a Codex session file: the `session_meta` record and one user message.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - day: The day of the records, `2026-11-<day>`.
  ///   - folder: The working folder of the session.
  /// - Returns: The bytes of the file.
  static func codex(id: String, day: String, folder: URL) -> Data {
    let date = "\(codexMonth)-\(day)"
    return Data(
      """
      {"timestamp":"\(date)T09:00:00.000Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(date)T09:00:00.000Z","cwd":"\(folder.path)"}}
      {"timestamp":"\(date)T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"List the files."}]}}

      """.utf8)
  }

  /// Writes a Codex session file into a root: `sessions/<year>/<month>/<day>/rollout-….jsonl`,
  /// or `archived_sessions/rollout-….jsonl` for an archived session.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - day: The day of the records, `2026-11-<day>`.
  ///   - folder: The working folder of the session.
  ///   - isArchived: True for an archived session.
  ///   - root: The Codex root (`~/.codex`).
  /// - Returns: The file.
  /// - Throws: The error of the write.
  @discardableResult
  static func writeCodex(
    id: String, day: String, folder: URL, isArchived: Bool = false, in root: URL
  ) throws -> URL {
    let date = "\(codexMonth)-\(day)"
    let name = "rollout-\(date)T09-00-00-\(id).jsonl"
    let place =
      isArchived
      ? codexArchiveFolder
      : "\(codexSessionsFolder)/\(date.replacingOccurrences(of: "-", with: "/"))"
    let file = root.appendingPathComponent("\(place)/\(name)")
    try write(codex(id: id, day: day, folder: folder), to: file)
    return file
  }

  // MARK: - The write

  /// Writes a file and makes its folder.
  ///
  /// - Parameters:
  ///   - data: The bytes.
  ///   - file: The file.
  /// - Throws: The error of the write.
  static func write(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
  }
}
