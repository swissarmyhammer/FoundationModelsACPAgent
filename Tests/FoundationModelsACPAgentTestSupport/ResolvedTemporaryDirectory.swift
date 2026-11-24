import Darwin
import Foundation
import Synchronization

/// The folders of the test folders of this process.
///
/// Each test folder goes into a folder of this process, not into the top of `/private/tmp` or of
/// the temporary directory. A full suite makes thousands of folders, and millions of entries at
/// the top of `/private/tmp` make Finder and `fseventsd` use much memory and CPU.
///
/// - The process removes its folders when it exits (`atexit`).
/// - A process that was stopped before its exit leaves its folders. The first use in the next
///   process removes each folder whose process does not run now.
public enum TestRunFolder {
  /// The parent of the folders of each process in `/private/tmp`.
  public static let parent = URL(fileURLWithPath: "/private/tmp/acpa-tests", isDirectory: true)

  /// The parent of the folders of each process in the temporary directory.
  public static let temporaryParent = FileManager.default.temporaryDirectory
    .appendingPathComponent("acpa-tests", isDirectory: true)

  /// The folder of this process in `/private/tmp`: `/private/tmp/acpa-tests/<pid>`. Its
  /// resolved path is its written path.
  public static let current: URL = makeFolder(in: parent)

  /// The folder of this process in the temporary directory: `<temporary directory>/acpa-tests/<pid>`.
  /// Use it in place of `FileManager.default.temporaryDirectory` in a test.
  public static let temporary: URL = makeFolder(in: temporaryParent)

  /// Makes the folder of this process in `parent`, removes the folders of the processes that do
  /// not run now, and registers the removal at the exit.
  ///
  /// - Parameter parent: The parent of the folders of each process.
  /// - Returns: The folder.
  private static func makeFolder(in parent: URL) -> URL {
    let folder = parent.appendingPathComponent(String(getpid()), isDirectory: true)
    removeFoldersOfEndedProcesses(in: parent)
    try? FileManager.default.removeItem(at: folder)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    folders.withLock { $0.append(folder) }
    registerRemovalAtExit
    return folder
  }

  /// The folders that the removal at the exit removes.
  private static let folders = Mutex<[URL]>([])

  /// Registers the removal at the exit one time.
  private static let registerRemovalAtExit: Void = {
    atexit {
      for folder in TestRunFolder.folders.withLock({ $0 }) {
        try? FileManager.default.removeItem(at: folder)
      }
    }
  }()

  /// Removes the folder of each process that does not run now.
  ///
  /// - Parameter parent: The parent of the folders of each process.
  private static func removeFoldersOfEndedProcesses(in parent: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names {
      guard let pid = pid_t(name), pid > 0, pid != getpid() else { continue }
      if kill(pid, 0) != 0 && errno == ESRCH {
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
      }
    }
  }
}

/// Makes a throwaway directory that already sits under `/private/tmp`, so
/// its resolved path equals its written path and equality checks stay
/// exact. The directory is in the folder of this process
/// (``TestRunFolder/current``), which the process removes when it exits.
///
/// - Parameter label: The prefix that names the calling suite and the
///   directory's role, so a leftover directory says where it came from.
/// - Returns: The created directory.
public func makeResolvedDirectory(label: String) -> URL {
  let directory = TestRunFolder.current
    .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true)
  return directory
}
