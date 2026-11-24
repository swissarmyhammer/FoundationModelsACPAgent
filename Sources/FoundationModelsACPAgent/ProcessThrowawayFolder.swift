import Darwin
import Foundation
import Synchronization

/// The folder of the throwaway directories of this process: `<temporary directory>/acp-agent/<pid>`.
///
/// Each composition makes a recordings root, and a stub composition also makes a cache
/// directory (``ComposedAgent``). Before, each one was at the top of the temporary directory and
/// nothing removed it: a test process that composes thousands of agents left thousands of folders.
///
/// - The directories of this process are in one folder.
/// - The first use removes the folder of each process that does not run now. So the folders of
///   a process stay only until the next process that composes an agent.
enum ProcessThrowawayFolder {
  /// The name of the parent of the folders of each process.
  static let parentName = "acp-agent"

  /// The folder of this process, once the first use made it.
  private static let made = Mutex<URL?>(nil)

  /// The folder of this process. The first call makes it and removes the folders of the
  /// processes that do not run now.
  ///
  /// - Returns: The folder.
  /// - Throws: The error of the creation of the folder.
  static func current() throws -> URL {
    try made.withLock { made in
      if let made { return made }
      let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(parentName, isDirectory: true)
      removeFoldersOfEndedProcesses(in: parent)
      let folder = parent.appendingPathComponent(String(getpid()), isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      made = folder
      return folder
    }
  }

  /// Removes the folder of each process that does not run now. A process that this process
  /// cannot signal (`EPERM`) runs, so its folder stays.
  ///
  /// - Parameter parent: The parent of the folders of each process.
  static func removeFoldersOfEndedProcesses(in parent: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names {
      guard let pid = pid_t(name), pid > 0, pid != getpid() else { continue }
      if kill(pid, 0) != 0 && errno == ESRCH {
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
      }
    }
  }
}
