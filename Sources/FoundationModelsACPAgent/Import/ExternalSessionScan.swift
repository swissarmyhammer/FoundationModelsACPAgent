import ACPImport
import Foundation
import FoundationModelsExtras
import Logging

/// One session file of a root: its source agent and its path relative to the root.
struct ExternalSessionFileKey: Hashable, Sendable {
  /// The source agent of the file.
  let agent: ImportSourceAgent

  /// The path of the file, relative to the root of the agent.
  let path: String
}

/// The part of a root that one find reads.
enum ExternalSessionFindScope: Sendable, Equatable {
  /// Each folder of the layout of the root.
  case root

  /// One project folder of a Claude Code root, by its project key.
  case project(String)
}

/// One session file that a find found: the fields of the directory read. No file is opened.
struct ExternalSessionFoundFile: Sendable, Hashable {
  /// The path of the file, relative to the root.
  let path: String

  /// The name of the project folder of the file, or `nil` for a layout with none.
  let projectKey: String?

  /// The size of the file, in bytes.
  let size: Int64

  /// The modification date of the file.
  let modified: Date
}

/// One entry of the index, with the JSON line that the index file holds for it.
///
/// The worker that reads a file encodes the line, so a write of the index file only joins the
/// lines, and the actor never encodes. The worker also keeps the standardized path of the
/// working folder, so a query with a folder compares texts only.
struct ExternalSessionIndexEntry: Sendable {
  /// The summary of the session.
  let summary: ExternalSessionSummary

  /// The JSON line of the summary in the index file, with no line break.
  let line: Data

  /// The standardized path of the working folder of the session, or `nil` when the summary
  /// has no working folder.
  let cwdPath: String?

  /// Makes an entry and encodes its line.
  ///
  /// - Parameter summary: The summary.
  init(summary: ExternalSessionSummary) {
    self.init(summary: summary, line: ExternalSessionIndexFile.line(of: summary))
  }

  /// Makes an entry from a line that the index file holds.
  ///
  /// - Parameters:
  ///   - summary: The summary that the line holds.
  ///   - line: The line.
  init(summary: ExternalSessionSummary, line: Data) {
    self.summary = summary
    self.line = line
    self.cwdPath = summary.cwd?.standardizedFileURL.path
  }
}

/// One read of Step B: the file, its root, and the entry of the last read.
struct ExternalSessionReadJob: Sendable {
  /// The file.
  let key: ExternalSessionFileKey

  /// The root of the agent of the file.
  let root: URL

  /// The project key of the file, or `nil`.
  let projectKey: String?

  /// The entry of the file before the read.
  let prior: ExternalSessionSummary?

  /// The generation of the root when the read started. A result of an older generation is
  /// dropped.
  let generation: Int
}

/// The result of one read of Step B.
enum ExternalSessionReadOutcome: Sendable {
  /// The new entry of the file: state `read`, or state `unreadable`.
  case read(ExternalSessionIndexEntry)

  /// The stamp of the file is the stamp of the entry. The read read no byte.
  case unchanged

  /// The file is gone.
  case gone
}

/// The two steps of a build of the index (D212, section 4.3): Step A finds the session files
/// with directory reads, and Step B reads the metadata windows of one file. Each function runs
/// in a worker task, never in the isolation of ``ExternalSessionIndex``.
enum ExternalSessionScan {
  /// The size over which a file that grew and whose head the index knows gets a read of its
  /// tail only: the long tail window of the reader of `ACPImport` (256 KB). The reader reads
  /// the head of a larger file at offset 0 only, thus a source that gives no byte at offset 0
  /// keeps the reader on the tail.
  static let tailOnlyMinimumSize: Int64 = 262_144

  // MARK: - Step A

  /// Finds the session files of one scope of a root.
  ///
  /// - Parameters:
  ///   - agent: The source agent of the root.
  ///   - root: The root.
  ///   - scope: The part of the root to read.
  ///   - fileSystem: The file system.
  ///   - cancel: The cancel of the finds of the root, checked before each folder read. After
  ///     the cancel, the find reads no more folders and its result is not complete.
  /// - Returns: The files. A folder that the read cannot read gives a warning and no file.
  static func find(
    _ agent: ImportSourceAgent, under root: URL, scope: ExternalSessionFindScope,
    fileSystem: any ExternalSessionFileSystem, cancel: ExternalSessionFindCancel? = nil
  ) -> [ExternalSessionFoundFile] {
    let starts: [[String]] =
      switch scope {
      case .root: agent.layout.folders.map { [$0] }
      case .project(let key): agent.layout.folders.map { [$0, key] }
      }
    return starts.flatMap { components in
      files(of: agent, under: root, at: components, fileSystem: fileSystem, cancel: cancel)
    }
  }

  /// The session files under one folder of a root, at each depth that the layout allows.
  ///
  /// - Parameters:
  ///   - agent: The source agent.
  ///   - root: The root.
  ///   - components: The path components of the folder, relative to the root.
  ///   - fileSystem: The file system.
  ///   - cancel: The cancel of the finds of the root.
  /// - Returns: The files.
  private static func files(
    of agent: ImportSourceAgent, under root: URL, at components: [String],
    fileSystem: any ExternalSessionFileSystem, cancel: ExternalSessionFindCancel?
  ) -> [ExternalSessionFoundFile] {
    guard cancel?.isCancelled != true else { return [] }
    let folder = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    let items: [ExternalSessionDirectoryItem]
    do {
      items = try fileSystem.items(in: folder)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The index of external sessions cannot read a folder of a root. It skips the folder.",
        metadata: ["path": "\(folder.path)", "error": "\(error)"])
      return []
    }
    return items.flatMap { item in
      let itemComponents = components + [item.name]
      switch item.kind {
      case .directory where descends(agent, into: itemComponents):
        return files(of: agent, under: root, at: itemComponents, fileSystem: fileSystem, cancel: cancel)
      case .file where agent.layout.holds(itemComponents):
        return [
          ExternalSessionFoundFile(
            path: itemComponents.joined(separator: "/"),
            projectKey: agent.projectKey(ofFile: itemComponents), size: item.size,
            modified: item.modified)
        ]
      default:
        return []
      }
    }
  }

  /// True when a find reads a folder: a folder at a depth that can hold a session file. The
  /// first component is the folder of the layout, thus a folder of `n` components holds the
  /// files at depth `n` under that folder.
  ///
  /// - Parameters:
  ///   - agent: The source agent.
  ///   - components: The path components of the folder, relative to the root.
  /// - Returns: True when the find reads the folder.
  private static func descends(_ agent: ImportSourceAgent, into components: [String]) -> Bool {
    agent.layout.fileDepth.map { components.count <= $0 } ?? true
  }

  // MARK: - Step B

  /// Reads the metadata windows of one file (at most 384 KB, never the full file). A file
  /// that grew, and whose head the index knows, gets a read of its tail only. The read of all
  /// the windows follows the tail read when the tail gives no record (for example, one new line
  /// that is longer than the tail windows), and when the tail gives a title: the entry keeps no
  /// rank of its title, and only a read of all the windows chooses the title of the higher
  /// rank.
  ///
  /// - Parameters:
  ///   - job: The read.
  ///   - fileSystem: The file system.
  /// - Returns: The new entry, ``ExternalSessionReadOutcome/unchanged`` when the stamp did not
  ///   change, or ``ExternalSessionReadOutcome/gone`` when the file is gone.
  static func read(_ job: ExternalSessionReadJob, fileSystem: any ExternalSessionFileSystem)
    -> ExternalSessionReadOutcome
  {
    let file = job.root.appendingPathComponent(job.key.path)
    guard let item = fileSystem.item(at: file), item.kind == .file else { return .gone }
    if let prior = job.prior, prior.state != .found, prior.size == item.size,
      prior.modified == item.modified
    {
      return .unchanged
    }
    let found = foundSummary(of: job, item: item)
    do {
      let source = try fileSystem.openForReading(file)
      if let prior = job.prior, isTailOnly(prior, size: item.size),
        let tail = try? job.key.agent.metadata(
          from: HeadlessByteSource(base: source), fileNamed: item.name),
        tail.title == nil
      {
        return .read(ExternalSessionIndexEntry(summary: merged(tail, into: prior, stamp: found)))
      }
      let metadata = try job.key.agent.metadata(from: source, fileNamed: item.name)
      return .read(ExternalSessionIndexEntry(summary: summary(of: metadata, stamp: found)))
    } catch let error as ImportReadError {
      ACPAgentTelemetry.logger(.session).debug(
        "A file of a root is not a session that the index can read.",
        metadata: ["path": "\(file.path)", "error": "\(error)"])
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The index of external sessions cannot read a session file of a root.",
        metadata: ["path": "\(file.path)", "error": "\(error)"])
    }
    var unreadable = found
    unreadable.state = .unreadable
    return .read(ExternalSessionIndexEntry(summary: unreadable))
  }

  /// The summary of a file that a find found and that no read read yet.
  ///
  /// - Parameters:
  ///   - agent: The source agent.
  ///   - file: The found file.
  /// - Returns: The summary, in the state `found`.
  static func foundSummary(of agent: ImportSourceAgent, file: ExternalSessionFoundFile)
    -> ExternalSessionSummary
  {
    ExternalSessionSummary(
      source: agent.rawValue,
      sourceID: agent.sourceID(ofFileNamed: (file.path as NSString).lastPathComponent),
      path: file.path, projectKey: file.projectKey, size: file.size, modified: file.modified,
      state: .found)
  }

  /// The summary of the file of a job with the stamp of its item, in the state `found`.
  private static func foundSummary(
    of job: ExternalSessionReadJob, item: ExternalSessionDirectoryItem
  ) -> ExternalSessionSummary {
    foundSummary(
      of: job.key.agent,
      file: ExternalSessionFoundFile(
        path: job.key.path, projectKey: job.projectKey, size: item.size, modified: item.modified))
  }

  /// True when a read of a file reads only its tail: the file grew, it is larger than
  /// ``tailOnlyMinimumSize``, and the index read its head before.
  private static func isTailOnly(_ prior: ExternalSessionSummary, size: Int64) -> Bool {
    prior.state == .read && size > prior.size && size > tailOnlyMinimumSize
  }

  /// The summary of a full read of the windows.
  ///
  /// - Parameters:
  ///   - metadata: The metadata of the reader.
  ///   - stamp: The summary of the directory fields of the file.
  /// - Returns: The summary, in the state `read`.
  private static func summary(of metadata: SessionFileMetadata, stamp: ExternalSessionSummary)
    -> ExternalSessionSummary
  {
    var summary = stamp
    summary.sourceID = metadata.sourceID.isEmpty ? stamp.sourceID : metadata.sourceID
    summary.cwd = metadata.cwd
    summary.gitBranch = metadata.gitBranch
    summary.isAutomated = metadata.isAutomated
    summary.title = metadata.title
    summary.firstPrompt = metadata.firstPrompt
    summary.lastPrompt = metadata.lastPrompt
    summary.firstDate = metadata.firstDate
    summary.lastDate = metadata.lastDate
    summary.state = .read
    return summary
  }

  /// The summary of a tail read: the fields of the head and the title come from the entry of
  /// the last read, and each other field that the tail gives is new. A tail with a title does
  /// not come here (``read(_:fileSystem:)``).
  ///
  /// - Parameters:
  ///   - tail: The metadata of the tail read.
  ///   - prior: The entry of the last read.
  ///   - stamp: The summary of the directory fields of the file now.
  /// - Returns: The summary, in the state `read`.
  private static func merged(
    _ tail: SessionFileMetadata, into prior: ExternalSessionSummary,
    stamp: ExternalSessionSummary
  ) -> ExternalSessionSummary {
    var summary = prior
    summary.size = stamp.size
    summary.modified = stamp.modified
    summary.cwd = tail.cwd ?? prior.cwd
    summary.gitBranch = tail.gitBranch ?? prior.gitBranch
    summary.isAutomated = prior.isAutomated || tail.isAutomated
    summary.lastPrompt = tail.lastPrompt ?? prior.lastPrompt
    summary.lastDate = tail.lastDate ?? prior.lastDate
    summary.state = .read
    return summary
  }
}

/// A byte source that gives no byte at offset 0: the read of the head window of the bounded
/// reader of `ACPImport` gives nothing, and each read of a tail window reads the file.
///
/// The index uses it only for a file larger than ``ExternalSessionScan/tailOnlyMinimumSize``,
/// where a tail window never starts at offset 0.
struct HeadlessByteSource: SessionByteSource {
  /// The source of the file.
  let base: any SessionByteSource

  /// The number of bytes of the file.
  var size: Int { base.size }

  /// Reads the bytes of a range of the file, or gives no byte for a read at offset 0.
  ///
  /// - Parameters:
  ///   - offset: The place of the first byte.
  ///   - length: The number of bytes.
  /// - Returns: The bytes, or no byte for a read at offset 0.
  /// - Throws: The error of the read of the base.
  func read(offset: Int, length: Int) throws -> Data {
    guard offset > 0 else { return Data() }
    return try base.read(offset: offset, length: length)
  }
}
