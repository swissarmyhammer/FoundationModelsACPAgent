import Foundation
import FoundationModelsAgents
import FoundationModelsRouter

/// Saves the scheduled agents of each session in its recording folder:
/// `<recording root>/<session>/schedules.json`.
///
/// FoundationModelsAgents keeps the tasks and fires them, and it gives only the
/// store protocol, because that package reads no file. A task belongs to its
/// session, so the file stands beside the recording of the session, and a
/// restart or a resume of the session reads it back
/// (`AgentRunner.restoreSchedules(of:workSite:)`).
struct ScheduleFileStore: AgentScheduleStore {
  /// The name of the file of the tasks of one session.
  static let fileName = "schedules.json"

  /// The root of the recordings of the sessions.
  let recordingRoot: URL

  /// The file of the tasks of `owner`.
  ///
  /// - Parameters:
  ///   - owner: The session.
  ///   - recordingRoot: The root of the recordings of the sessions.
  /// - Returns: The file.
  static func file(of owner: ULID, in recordingRoot: URL) -> URL {
    recordingRoot.appendingPathComponent(owner.description, isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  /// Writes the tasks of `owner` in place of its saved tasks. An empty list
  /// removes the file.
  ///
  /// - Parameters:
  ///   - tasks: The tasks.
  ///   - owner: The session.
  /// - Throws: The error of the encoder or of the file system.
  func save(_ tasks: [AgentScheduledTask], of owner: ULID) async throws {
    let file = Self.file(of: owner, in: recordingRoot)
    guard !tasks.isEmpty else {
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      return
    }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(tasks).write(to: file, options: .atomic)
  }

  /// Reads the saved tasks of `owner`.
  ///
  /// - Parameter owner: The session.
  /// - Returns: The tasks, or none when the session has no file.
  /// - Throws: The error of the decoder or of the file system.
  func load(of owner: ULID) async throws -> [AgentScheduledTask] {
    let file = Self.file(of: owner, in: recordingRoot)
    // A missing file is expected: the session has no scheduled agent.
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try JSONDecoder().decode([AgentScheduledTask].self, from: Data(contentsOf: file))
  }
}
