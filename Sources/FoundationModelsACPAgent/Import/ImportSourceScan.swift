import ACPImport
import Foundation

/// Where the session files of one source agent are in its root, and how to read their metadata
/// (D209 (d)). The importer reads only these files, and never writes to a root.
struct ImportSourceLayout: Sendable {
  /// The folders of the session files, relative to the root.
  let folders: [String]

  /// The depth of a session file under its folder, or `nil` for each depth. A Claude Code
  /// session file is `projects/<project>/<id>.jsonl`, depth 2. A file at a different depth,
  /// such as the file of a sub-agent in a folder of a session, is not a session.
  let fileDepth: Int?

  /// The start of the name of a session file, or an empty text for each name.
  let namePrefix: String

  /// The extension of each session file.
  static let fileExtension = "jsonl"

  /// The depth of a Claude Code session file under `projects`: `<project>/<id>.jsonl`.
  static let claudeCodeFileDepth = 2

  /// True when `file`, at `depth` under its folder, is a session file of this layout.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - depth: The number of path components from the folder to the file.
  /// - Returns: True for a session file.
  func holds(_ file: URL, atDepth depth: Int) -> Bool {
    file.pathExtension == Self.fileExtension && file.lastPathComponent.hasPrefix(namePrefix)
      && (fileDepth.map { $0 == depth } ?? true)
  }
}

extension ImportSourceAgent {
  /// The layout of the session files of the agent in its root.
  var layout: ImportSourceLayout {
    switch self {
    case .claudeCode:
      ImportSourceLayout(
        folders: ["projects"], fileDepth: ImportSourceLayout.claudeCodeFileDepth, namePrefix: "")
    case .codex:
      ImportSourceLayout(
        folders: ["sessions", "archived_sessions"], fileDepth: nil, namePrefix: "rollout-")
    }
  }

  /// Reads the metadata of one session file of the agent, with the reader of `ACPImport`.
  ///
  /// - Parameters:
  ///   - data: The bytes of the file.
  ///   - file: The file. A Claude Code session has the name of its file as its id.
  /// - Returns: The metadata.
  /// - Throws: `ImportReadError` when the file is not a session of the agent.
  func metadata(of data: Data, in file: URL) throws -> ImportedSessionMetadata {
    switch self {
    case .claudeCode:
      try ClaudeCodeSessionReader(sourceID: file.deletingPathExtension().lastPathComponent)
        .metadata(data)
    case .codex:
      try CodexSessionReader().metadata(data)
    }
  }
}

/// The size and the modification date of a session file. The importer reads a file again only
/// when its stamp changes.
struct ImportFileStamp: Sendable, Equatable {
  /// The resource keys that a stamp reads.
  static let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]

  /// The size of the file, in bytes.
  ///
  /// The synthesized `Equatable` conformance reads it; periphery sees no reader.
  // periphery:ignore
  let size: Int

  /// The modification date of the file.
  ///
  /// The synthesized `Equatable` conformance reads it; periphery sees no reader.
  // periphery:ignore
  let modified: Date

  /// Makes the stamp of a file, from the resource values of its enumeration.
  ///
  /// - Parameter file: The file.
  /// - Returns: The stamp, or `nil` when the file system gives no size or no date.
  static func makeStamp(of file: URL) -> ImportFileStamp? {
    let values = try? file.resourceValues(forKeys: Set(resourceKeys))
    guard let size = values?.fileSize, let modified = values?.contentModificationDate else {
      return nil
    }
    return ImportFileStamp(size: size, modified: modified)
  }
}

/// The result of the read of one session file: its stamp, and its metadata, or `nil` when the
/// file is not a session that the reader can list.
struct ImportFileScan: Sendable {
  /// The stamp of the file at the read.
  let stamp: ImportFileStamp

  /// The metadata of the file, or `nil` when the reader refused the file.
  let metadata: ImportedSessionMetadata?
}

/// The metadata of one session, with its file.
struct LocatedSessionMetadata: Sendable {
  /// The session file.
  let file: URL

  /// The metadata of the session.
  let metadata: ImportedSessionMetadata

  /// The working folder of the session, or `nil` when the file does not give it.
  var cwd: URL? { metadata.cwd }
}
