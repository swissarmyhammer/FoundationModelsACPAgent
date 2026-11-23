import ACPImport
import Foundation

/// Where the session files of one source agent are in its root (D209 (d)). The index reads only
/// these files, and never writes to a root.
struct ImportSourceLayout: Sendable {
  /// The folders of the session files, relative to the root.
  let folders: [String]

  /// The depth of a session file under its folder, or `nil` for each depth. A Claude Code
  /// session file is `projects/<project>/<id>.jsonl`, depth 2. A file at a different depth,
  /// such as the file of a sub-agent in a folder of a session, is not a session.
  let fileDepth: Int?

  /// The start of the name of a session file, or an empty text for each name.
  let namePrefix: String

  /// True when the session files of the layout are in project folders, one for each working
  /// folder (Claude Code): `<folder>/<project>/<file>`.
  let hasProjectFolders: Bool

  /// The place of the project folder in the path components of a file, relative to the root.
  static let projectComponentIndex = 1

  /// The extension of each session file.
  static let fileExtension = "jsonl"

  /// The depth of a Claude Code session file under `projects`: `<project>/<id>.jsonl`.
  static let claudeCodeFileDepth = 2

  /// True when a file is a session file of this layout.
  ///
  /// - Parameter components: The path components of the file, relative to the root. The first
  ///   component is the folder of the layout.
  /// - Returns: True for a session file.
  func holds(_ components: [String]) -> Bool {
    guard let folder = components.first, let name = components.last, folders.contains(folder)
    else { return false }
    let depth = components.count - 1
    return (name as NSString).pathExtension == Self.fileExtension && name.hasPrefix(namePrefix)
      && !components.contains { $0.hasPrefix(".") } && (fileDepth.map { $0 == depth } ?? (depth > 0))
  }
}

extension ImportSourceAgent {
  /// The layout of the session files of the agent in its root.
  var layout: ImportSourceLayout {
    switch self {
    case .claudeCode:
      ImportSourceLayout(
        folders: ["projects"], fileDepth: ImportSourceLayout.claudeCodeFileDepth, namePrefix: "",
        hasProjectFolders: true)
    case .codex:
      ImportSourceLayout(
        folders: ["sessions", "archived_sessions"], fileDepth: nil, namePrefix: "rollout-",
        hasProjectFolders: false)
    }
  }

  /// The number of characters of a UUID in its text form.
  private static let uuidTextLength = 36

  /// The id of a session from the name of its file, before a read of the file: the name with
  /// no extension for Claude Code, and the UUID at the end of the name for Codex
  /// (`rollout-<time>-<id>.jsonl`). A Codex name with no UUID at its end gives the name with
  /// no extension.
  ///
  /// - Parameter name: The name of the file.
  /// - Returns: The id.
  func sourceID(ofFileNamed name: String) -> String {
    let stem = (name as NSString).deletingPathExtension
    switch self {
    case .claudeCode:
      return stem
    case .codex:
      let suffix = String(stem.suffix(Self.uuidTextLength))
      return UUID(uuidString: suffix) == nil ? stem : suffix
    }
  }

  /// The project key of a session file: the name of its project folder, or `nil` for a layout
  /// with no project folders (Codex).
  ///
  /// - Parameter components: The path components of the file, relative to the root.
  /// - Returns: The project key, or `nil`.
  func projectKey(ofFile components: [String]) -> String? {
    guard layout.hasProjectFolders, components.count == ImportSourceLayout.claudeCodeFileDepth + 1
    else { return nil }
    return components[ImportSourceLayout.projectComponentIndex]
  }

  /// The project key of a working folder: the name that Claude Code gives the project folder
  /// of the folder. Each character that is not an ASCII letter or digit becomes `-` (D209 (b)).
  /// The rule loses information, thus a query also compares the `cwd` of each session. The
  /// rule does not resolve symbolic links: a query gives the resolved folder
  /// (``ExternalSessionFolderMatch``).
  ///
  /// - Parameter folder: The working folder.
  /// - Returns: The project key.
  static func projectKey(of folder: URL) -> String {
    String(
      folder.standardizedFileURL.path.unicodeScalars.map { scalar in
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
      })
  }

  /// Reads the metadata of one session file with the bounded reader of `ACPImport`: at most
  /// 384 KB of the file, never the full file.
  ///
  /// - Parameters:
  ///   - source: The bytes of the file.
  ///   - name: The name of the file. A Claude Code session has the name of its file as its id.
  /// - Returns: The metadata.
  /// - Throws: `ImportReadError` when the file is not a session of the agent, and the error of
  ///   a read.
  func metadata(from source: some SessionByteSource, fileNamed name: String) throws
    -> SessionFileMetadata
  {
    switch self {
    case .claudeCode:
      try ClaudeCodeSessionReader(sourceID: sourceID(ofFileNamed: name)).metadata(from: source)
    case .codex:
      try CodexSessionReader().metadata(from: source)
    }
  }

  /// Reads one session file of the agent in full, one block at a time, with the reader of
  /// `ACPImport`: its metadata, its updates and the count of the records that the reader did
  /// not read. Only the copy of a session reads a full file. The memory never holds the bytes
  /// of the whole file.
  ///
  /// - Parameters:
  ///   - source: The bytes of the file.
  ///   - name: The name of the file. A Claude Code session has the name of its file as its id.
  /// - Returns: The session.
  /// - Throws: `ImportReadError` when the file is not a session of the agent, a
  ///   `CancellationError` when the task is cancelled, and the error of a read.
  func session(from source: some SessionByteSource, fileNamed name: String) throws
    -> ImportedSession
  {
    switch self {
    case .claudeCode:
      try ClaudeCodeSessionReader(sourceID: sourceID(ofFileNamed: name)).read(from: source)
    case .codex:
      try CodexSessionReader().read(from: source)
    }
  }

  /// The updates of one session file of the agent in batches, for a read-only view (D212,
  /// section 5.3). The reader reads one block at a time when the consumer asks for the next
  /// batch, so the first batches come while the read continues.
  ///
  /// - Parameters:
  ///   - source: The bytes of the file.
  ///   - name: The name of the file. A Claude Code session has the name of its file as its id.
  ///   - blockSize: The number of bytes of each read.
  /// - Returns: The batches.
  func updates(
    from source: some SessionByteSource, fileNamed name: String, blockSize: Int
  ) -> SessionUpdateBatches {
    switch self {
    case .claudeCode:
      ClaudeCodeSessionReader(sourceID: sourceID(ofFileNamed: name))
        .updates(from: source, blockSize: blockSize)
    case .codex:
      CodexSessionReader().updates(from: source, blockSize: blockSize)
    }
  }
}
