import ACPImport
import Foundation
import FoundationModelsExtras
import Synchronization

/// The state of one root in ``ExternalSessionIndex``: the entries of its session files, and
/// the state of its find, its watch and its index file.
struct ExternalSessionRoot: Sendable {
  /// The root.
  let url: URL

  /// The number of the root in the index. A new root of the same source agent gets a new
  /// number, and the index drops each result of an older number.
  let generation: Int

  /// The prefixes of the absolute path of each file of the root: the standardized path of the
  /// root and its path with the symbolic links resolved, each with a `/` at its end. An
  /// FSEvents path is a resolved path.
  let prefixes: [String]

  /// The entry of each session file, by its path relative to the root.
  private(set) var entries: [String: ExternalSessionIndexEntry] = [:]

  /// The number of entries in the state `found`.
  private(set) var foundCount = 0

  /// The number of entries of each project key.
  private var projectCounts: [String: Int] = [:]

  /// The number of entries in the state `found` (not read yet) of each project key.
  private var projectFoundCounts: [String: Int] = [:]

  /// The time of the last read of each file, by its path.
  var lastRead: [String: ContinuousClock.Instant] = [:]

  /// True after the first find of the whole root.
  var isFound = false

  /// The time of the last find of the whole root, or `nil` before the first find.
  var lastFind: ContinuousClock.Instant?

  /// The number of finds of the whole root that run now. Two finds can run at one time (an
  /// import runs its own find), so the end of one find does not end the state of the other.
  var rootFindCount = 0

  /// True while a find of the whole root runs.
  var isFinding: Bool { rootFindCount > 0 }

  /// The number of one-folder finds that run now, by project key.
  var projectFindCounts: [String: Int] = [:]

  /// The watch of the root, or `nil` when the file system gives no watch.
  var watch: (any ExternalSessionWatch)?

  /// True when a folder of the layout did not exist when the watch started, so the watch does
  /// not see that folder. A query then runs finds, as for a root with no watch.
  var isWatchPartial = false

  /// The cancel of the finds of the root. A removal of the root and a stop of the index set it,
  /// and a find checks it before each folder read.
  let findCancel = ExternalSessionFindCancel()

  /// The input of the events of the watch.
  let eventInput: AsyncStream<[URL]>.Continuation

  /// The number of entries that changed after the last write of the index file.
  var unsavedCount = 0

  /// Makes the state of a new root.
  ///
  /// - Parameters:
  ///   - url: The root.
  ///   - prefixes: The prefixes of the paths of the files of the root
  ///     (``prefixes(of:)``).
  ///   - generation: The number of the root in the index.
  ///   - eventInput: The input of the events of the watch.
  init(
    url: URL, prefixes: [String], generation: Int, eventInput: AsyncStream<[URL]>.Continuation
  ) {
    self.url = url
    self.prefixes = prefixes
    self.generation = generation
    self.eventInput = eventInput
  }

  /// The prefixes of the absolute paths of the files of a root. The call resolves the symbolic
  /// links of the root, thus it runs before a call into the index, never in its isolation.
  ///
  /// - Parameter root: The root.
  /// - Returns: The prefixes, each with a `/` at its end.
  static func prefixes(of root: URL) -> [String] {
    Array(Set([root.standardizedFileURL.path, root.canonicalPath])).sorted().map { $0 + "/" }
  }

  /// True while a one-folder find of the project key runs.
  ///
  /// - Parameter projectKey: The project key.
  /// - Returns: True when a find of the project runs now.
  func isFinding(project projectKey: String) -> Bool {
    (projectFindCounts[projectKey] ?? 0) > 0
  }

  /// True when an entry of the project key exists.
  ///
  /// - Parameter projectKey: The project key.
  /// - Returns: True when the root holds an entry of the project.
  func hasEntries(ofProject projectKey: String) -> Bool {
    (projectCounts[projectKey] ?? 0) > 0
  }

  /// The path of a file relative to a root, or `nil` for a file outside the root.
  ///
  /// - Parameters:
  ///   - file: The absolute URL of the file.
  ///   - prefixes: The prefixes of the paths of the files of the root (``prefixes(of:)``).
  /// - Returns: The relative path.
  static func relativePath(of file: URL, prefixes: [String]) -> String? {
    let path = file.standardizedFileURL.path
    return prefixes.first { path.hasPrefix($0) }.map { String(path.dropFirst($0.count)) }
  }

  /// Replaces all the entries, for example with the entries of the index file.
  ///
  /// - Parameter newEntries: The entries, by path.
  mutating func replaceEntries(_ newEntries: [String: ExternalSessionIndexEntry]) {
    entries = [:]
    foundCount = 0
    projectCounts = [:]
    projectFoundCounts = [:]
    for entry in newEntries.values {
      set(entry)
    }
  }

  /// Sets the entry of a file.
  ///
  /// - Parameter entry: The entry.
  mutating func set(_ entry: ExternalSessionIndexEntry) {
    let old = entries.updateValue(entry, forKey: entry.summary.path)
    count(old, by: -1)
    count(entry, by: 1)
  }

  /// Removes the entry of a file.
  ///
  /// - Parameter path: The path of the file.
  /// - Returns: The removed entry, or `nil` when the root holds no entry of the path.
  @discardableResult
  mutating func removeEntry(at path: String) -> ExternalSessionIndexEntry? {
    let old = entries.removeValue(forKey: path)
    count(old, by: -1)
    lastRead[path] = nil
    return old
  }

  /// Adds the counts of an entry.
  private mutating func count(_ entry: ExternalSessionIndexEntry?, by step: Int) {
    guard let summary = entry?.summary else { return }
    if summary.state == .found { foundCount += step }
    if let projectKey = summary.projectKey {
      projectCounts[projectKey, default: 0] += step
      if summary.state == .found { projectFoundCounts[projectKey, default: 0] += step }
    }
  }

  /// The number of entries of a project key, and the number of them in the state `found`.
  ///
  /// - Parameter projectKey: The project key.
  /// - Returns: The counts.
  func counts(ofProject projectKey: String) -> (entries: Int, found: Int) {
    (projectCounts[projectKey] ?? 0, projectFoundCounts[projectKey] ?? 0)
  }
}

/// The cancel of the finds of one root. A find runs in a detached task and reads folders, so it
/// cannot read the state of the actor: it checks this flag before each folder read.
final class ExternalSessionFindCancel: Sendable {
  /// True after the cancel.
  private let state = Mutex(false)

  /// True after ``cancel()``.
  var isCancelled: Bool { state.withLock { $0 } }

  /// Cancels each find of the root, the finds that run now and the finds that start later.
  func cancel() {
    state.withLock { $0 = true }
  }
}
