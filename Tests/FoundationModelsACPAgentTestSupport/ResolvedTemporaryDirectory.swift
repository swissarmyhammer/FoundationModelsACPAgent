import Darwin
import Foundation

/// The folder of the test folders of this process: `/private/tmp/acpa-tests/<pid>`.
///
/// Each test folder goes into this folder, not into `/private/tmp` itself. A full suite makes
/// thousands of folders, and millions of entries at the top of `/private/tmp` make Finder and
/// `fseventsd` use much memory and CPU.
///
/// - The process removes its folder when it exits (`atexit`).
/// - A process that was stopped before its exit leaves its folder. The next process that makes
///   a test folder removes each folder whose process does not run now.
public enum TestRunFolder {
  /// The parent of the folders of each process.
  public static let parent = URL(fileURLWithPath: "/private/tmp/acpa-tests", isDirectory: true)

  /// The folder of this process. The first use makes it, removes the folders of the processes
  /// that do not run now, and registers the removal at the exit.
  public static let current: URL = {
    let folder = parent.appendingPathComponent(String(getpid()), isDirectory: true)
    removeFoldersOfEndedProcesses()
    try? FileManager.default.removeItem(at: folder)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    atexit {
      try? FileManager.default.removeItem(at: TestRunFolder.current)
    }
    return folder
  }()

  /// Removes the folder of each process that does not run now.
  private static func removeFoldersOfEndedProcesses() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names {
      guard let pid = pid_t(name), pid != getpid() else { continue }
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
