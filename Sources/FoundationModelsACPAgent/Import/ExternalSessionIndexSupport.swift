import ACPImport
import Foundation
import FoundationModelsExtras

/// One row of a query of ``ExternalSessionIndex``: the summary of a session and the root of
/// its source.
struct LocatedExternalSession: Sendable, Equatable {
  /// The summary of the session.
  let summary: ExternalSessionSummary

  /// The root of the source agent of the session.
  let root: URL

  /// The session file.
  var file: URL { root.appendingPathComponent(summary.path) }

  /// True when the first row comes before the second row: the newer date first
  /// (``ExternalSessionSummary/displayDate``), and the path decides between two rows of the
  /// same date.
  ///
  /// - Parameters:
  ///   - first: The first row.
  ///   - second: The second row.
  /// - Returns: True when `first` comes first.
  static func isNewer(_ first: LocatedExternalSession, than second: LocatedExternalSession)
    -> Bool
  {
    let firstDate = first.summary.displayDate
    let secondDate = second.summary.displayDate
    return firstDate == secondDate ? first.summary.path < second.summary.path : firstDate > secondDate
  }
}

/// The test of a query with a folder (D212, section 4.5): an entry matches when its `cwd` is
/// the folder, or when it has no `cwd` and its project folder is the project folder of the
/// folder. The project key loses information, thus the `cwd` decides when an entry has one.
///
/// Claude Code names a project folder from the working folder of its process, which has no
/// symbolic link (`/private/tmp/proj`, not `/tmp/proj`). Thus the project key of the match
/// comes from the `realpath` of the folder. `URL.resolvingSymlinksInPath()` is not that path:
/// it removes the `/private` prefix, and it does not resolve a folder that does not exist.
struct ExternalSessionFolderMatch: Sendable, Equatable {
  /// The paths of the folder: the standardized path and the path with the symbolic links
  /// resolved.
  let paths: Set<String>

  /// The project key of the folder, from its resolved path. The read queue and the find of
  /// one project folder use it.
  let projectKey: String

  /// The project keys that an entry with no `cwd` can have: the keys of the resolved path and
  /// of the standardized path.
  let projectKeys: Set<String>

  /// Makes the match of a folder. The init resolves the symbolic links of the folder, thus it
  /// runs before a call into the index, never in its isolation.
  ///
  /// - Parameter folder: The folder.
  init(folder: URL) {
    let resolved = URL(fileURLWithPath: Self.realPath(of: folder), isDirectory: true)
    self.paths = [folder.standardizedFileURL.path, folder.canonicalPath, resolved.path]
    self.projectKey = ImportSourceAgent.projectKey(of: resolved)
    self.projectKeys = [projectKey, ImportSourceAgent.projectKey(of: folder)]
  }

  /// The `realpath` of a folder: the symbolic links of its nearest folder that exists are
  /// resolved, and the components that do not exist follow with no change.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The resolved path.
  static func realPath(of folder: URL) -> String {
    let standardized = folder.standardizedFileURL
    let components = standardized.pathComponents
    for count in stride(from: components.count, to: 0, by: -1) {
      let existing = NSString.path(withComponents: Array(components.prefix(count)))
      guard let resolved = realpath(existing, nil) else { continue }
      defer { free(resolved) }
      let rest = components.dropFirst(count)
      return ([String(cString: resolved)] + rest).joined(separator: "/")
        .replacingOccurrences(of: "//", with: "/")
    }
    return standardized.path
  }

  /// True when an entry matches the folder.
  ///
  /// - Parameter entry: The entry.
  /// - Returns: True for a match.
  func matches(_ entry: ExternalSessionIndexEntry) -> Bool {
    matches(cwdPath: entry.cwdPath, projectKey: entry.summary.projectKey)
  }

  /// True when a summary matches the folder.
  ///
  /// - Parameter summary: The summary.
  /// - Returns: True for a match.
  func matches(_ summary: ExternalSessionSummary) -> Bool {
    matches(cwdPath: summary.cwd?.standardizedFileURL.path, projectKey: summary.projectKey)
  }

  /// True when a working folder path, or else a project key, matches the folder.
  private func matches(cwdPath: String?, projectKey: String?) -> Bool {
    guard let cwdPath else { return projectKey.map(projectKeys.contains) ?? false }
    return paths.contains(cwdPath)
  }
}

/// One item of a batch of a watch, as the task of the events of a root reads it.
struct ExternalSessionEventItem: Sendable {
  /// The path of the item, relative to the root.
  let path: String

  /// The components of ``path``.
  let components: [String]

  /// The kind of the item, or `nil` when the item is gone.
  let kind: ExternalSessionItemKind?

  /// The entry in the state `found` of a session file that exists, or `nil` for each other
  /// item.
  let entry: ExternalSessionIndexEntry?
}

/// One change of the index, for the subscribers of ``ExternalSessionIndex``.
struct ExternalSessionIndexEvent: Sendable {
  /// The entries that a read added or changed, in the state `read`.
  let changed: [ExternalSessionIndexEntry]

  /// The entries whose files are gone.
  let removed: [ExternalSessionIndexEntry]

  /// The progress of the index after the change.
  let indexState: ExternalSessionIndexState

  /// True when the change completed the build: the index read each file that it found.
  let completesBuild: Bool

  /// The sources whose root the change removed with each of its entries: a Remove Access, a new
  /// root of the source, or a rebuild.
  var removedSources: Set<ImportSourceAgent> = []

  /// The change for a subscriber of one folder, or of each folder.
  ///
  /// - Parameter match: The folder of the subscriber, or `nil` for each folder.
  /// - Returns: The change, or `nil` when it holds nothing for the folder and does not
  ///   complete the build.
  func change(for match: ExternalSessionFolderMatch?) -> ExternalSessionChange? {
    let changedRows = match.map { changed.filter($0.matches) } ?? changed
    let removedRows = match.map { removed.filter($0.matches) } ?? removed
    guard match == nil || !changedRows.isEmpty || !removedRows.isEmpty || completesBuild else {
      return nil
    }
    return ExternalSessionChange(
      changed: changedRows.map(\.summary), removed: removedRows.map(\.summary.id),
      indexState: indexState)
  }
}

/// An error of a query of ``ExternalSessionIndex``.
enum ExternalSessionIndexError: Error, Equatable, CustomStringConvertible {
  /// The query names a source agent that the index does not know.
  case unknownSource(String)

  /// The text of the error.
  var description: String {
    switch self {
    case .unknownSource(let source):
      let known = ImportSourceAgent.allCases.map(\.rawValue).joined(separator: ", ")
      return "the source \(source) is not a source of external sessions. The sources are: \(known)"
    }
  }
}

/// The pages of an ordered list of rows. The cursor of a page is the place of its first row in
/// the list.
enum ExternalSessionPaging {
  /// One page of an ordered list.
  ///
  /// - Parameters:
  ///   - rows: The ordered rows.
  ///   - limit: The most rows of the page. A page has at least one row when rows follow the
  ///     cursor.
  ///   - cursor: The cursor of the page, or `nil` for the first page.
  /// - Returns: The rows of the page and the cursor of the next page (`nil` when no row
  ///   follows), or `nil` when the cursor is not a place in the list.
  static func page<Row>(of rows: [Row], limit: Int, cursor: String?) -> (
    rows: [Row], nextCursor: String?
  )? {
    let start: Int
    if let cursor {
      guard let place = Int(cursor), (0...rows.count).contains(place) else { return nil }
      start = place
    } else {
      start = 0
    }
    let end = start + min(max(limit, 1), rows.count - start)
    return (Array(rows[start..<end]), end < rows.count ? String(end) : nil)
  }
}
