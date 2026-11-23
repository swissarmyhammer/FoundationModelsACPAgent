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

  /// The text of the user message of each Claude Code session file.
  static let claudeCodeQuestion = "Fix the test."

  /// The command of the tool call of the answer of a Claude Code session file.
  static let claudeCodeToolCommand = "swift test"

  /// The text output of the tool call of the answer of a Claude Code session file.
  static let claudeCodeToolOutput = "All tests passed."

  /// The thought of the answer of a Claude Code session file. No transcript of an import
  /// holds it.
  static let claudeCodeThought = "The timer is the cause."

  /// The last agent message of the answer of a Claude Code session file. It holds the word
  /// ``claudeCodeAnswerWord``, which no other text of the fixtures holds.
  static let claudeCodeAnswer = "The zanzibar test passes now."

  /// A word of ``claudeCodeAnswer`` that no other text of the fixtures holds.
  static let claudeCodeAnswerWord = "zanzibar"

  /// The time of the last record of the answer of a Claude Code session file, in ISO 8601
  /// form: the time of the record of ``claudeCodeAnswer``.
  static let claudeCodeLastRecordTimestamp = "2026-11-01T10:00:04.000Z"

  /// The bytes of a Claude Code session file: one user record, the records of an answer when
  /// `withAnswer` is true, and a custom title record when a title is given. The user record has
  /// an `entrypoint` when one is given.
  ///
  /// The answer is a thought, a tool call of `Bash` with its result, and an agent message
  /// (``claudeCodeAnswer``).
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - folder: The working folder of the session.
  ///   - title: The custom title, or `nil` for no title record.
  ///   - withAnswer: True to add the records of the answer.
  ///   - entrypoint: The `entrypoint` of the user record, for example `sdk-cli` for an
  ///     automated session, or `nil` for none.
  /// - Returns: The bytes of the file.
  static func claudeCode(
    id: String, folder: URL, title: String? = nil, withAnswer: Bool = false,
    entrypoint: String? = nil
  ) -> Data {
    let entrypointMember = entrypoint.map { #""entrypoint":"\#($0)","# } ?? ""
    let user = """
      {"type":"user","uuid":"u-1","sessionId":"\(id)","timestamp":"2026-11-01T10:00:01.000Z","cwd":"\(folder.path)",\(entrypointMember)"message":{"role":"user","content":"\(claudeCodeQuestion)"}}
      """
    let answer = withAnswer ? claudeCodeAnswerRecords(id: id) : []
    let titleLine = title.map {
      #"{"type":"custom-title","customTitle":"\#($0)","sessionId":"\#(id)"}"#
    }
    return Data(
      ([user] + answer + [titleLine].compactMap { $0 } + [""]).joined(separator: "\n").utf8)
  }

  /// The records of the answer of a Claude Code session file: an assistant record with a
  /// thought and a tool call, the user record with the result of the call, and an assistant
  /// record with the last agent message.
  ///
  /// - Parameter id: The id of the session.
  /// - Returns: The records, one JSON line each.
  private static func claudeCodeAnswerRecords(id: String) -> [String] {
    [
      """
      {"type":"assistant","uuid":"a-1","sessionId":"\(id)","timestamp":"2026-11-01T10:00:02.000Z","message":{"id":"msg-1","role":"assistant","content":[{"type":"thinking","thinking":"\(claudeCodeThought)"},{"type":"tool_use","id":"toolu-1","name":"Bash","input":{"command":"\(claudeCodeToolCommand)"}}]}}
      """,
      """
      {"type":"user","uuid":"u-2","sessionId":"\(id)","timestamp":"2026-11-01T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu-1","content":"\(claudeCodeToolOutput)"}]}}
      """,
      """
      {"type":"assistant","uuid":"a-2","sessionId":"\(id)","timestamp":"\(claudeCodeLastRecordTimestamp)","message":{"id":"msg-2","role":"assistant","content":[{"type":"text","text":"\(claudeCodeAnswer)"}]}}
      """,
    ]
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
  ///   - withAnswer: True to add the records of an answer
  ///     (``claudeCode(id:folder:title:withAnswer:entrypoint:)``).
  ///   - entrypoint: The `entrypoint` of the user record, or `nil` for none.
  ///   - root: The Claude Code root (`~/.claude`).
  /// - Returns: The file.
  /// - Throws: The error of the write.
  @discardableResult
  static func writeClaudeCode(
    id: String, folder: URL, title: String? = nil, withAnswer: Bool = false,
    entrypoint: String? = nil, in root: URL
  ) throws -> URL {
    let file = claudeCodeFile(of: id, folder: folder, in: root)
    try write(
      claudeCode(id: id, folder: folder, title: title, withAnswer: withAnswer, entrypoint: entrypoint),
      to: file)
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
