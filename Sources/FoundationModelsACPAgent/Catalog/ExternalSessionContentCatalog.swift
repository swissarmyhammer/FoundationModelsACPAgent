import ACPImport
import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The record of one typed session of another agent for the content catalog of a host (D214,
/// part 5).
public struct ExternalSessionContentRecord: Sendable, Equatable, Codable, Identifiable {
  /// The id of the session: its source agent and its id in the source.
  public let id: ExternalSessionID

  /// The name of the session: its title, else its first prompt, else its last prompt.
  public let name: String?

  /// The working folder of the session, or `nil`.
  public let cwd: URL?

  /// The git branch of the session, or `nil`.
  public let gitBranch: String?

  /// The first prompt of the session, or `nil`.
  public let firstPrompt: String?

  /// The last prompt of the session, or `nil`.
  public let lastPrompt: String?

  /// The time of the first record, or `nil`.
  public let firstDate: Date?

  /// The time of the last record, or `nil`.
  public let lastDate: Date?

  /// The time of the last change of the file.
  public let modified: Date

  /// The record of a summary of the index.
  ///
  /// - Parameter summary: The summary.
  init(_ summary: ExternalSessionSummary) {
    id = summary.id
    name = summary.displayText
    cwd = summary.cwd
    gitBranch = summary.gitBranch
    firstPrompt = summary.firstPrompt
    lastPrompt = summary.lastPrompt
    firstDate = summary.firstDate
    lastDate = summary.lastDate
    modified = summary.modified
  }

  /// The stamp of the record: the hash of its JSON form with sorted keys and dates in
  /// milliseconds.
  var stampText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}

/// The external sessions part of the content catalog (D214, part 5). A domain is one source
/// agent. Its records are the typed sessions of its root that the index read (state `read`).
/// An automated session has no record.
public struct ExternalSessionContentCatalog: Sendable {
  /// The index of the external sessions.
  private let index: ExternalSessionIndex

  /// Makes the part.
  ///
  /// - Parameter index: The index of the external sessions.
  init(index: ExternalSessionIndex) {
    self.index = index
  }

  /// The stamp of each source that has a root. A stamp changes when a record of the source is
  /// added, changed or removed.
  ///
  /// - Returns: The stamp of each source.
  public func stamps() async -> [ImportSourceAgent: ContentStamp] {
    let records = await allRecords()
    var stamps: [ImportSourceAgent: ContentStamp] = [:]
    for source in await index.sources {
      stamps[source] = ContentStamp.hashing(
        (records[source] ?? []).map(\.stampText))
    }
    return stamps
  }

  /// The records of one source, in the order of their source ids.
  ///
  /// - Parameter source: The source agent.
  /// - Returns: The records.
  public func records(of source: ImportSourceAgent) async -> [ExternalSessionContentRecord] {
    await allRecords()[source] ?? []
  }

  /// The record of one session.
  ///
  /// - Parameter id: The session.
  /// - Returns: The record, or `nil` when the session is not a typed session that the index read.
  public func record(_ id: ExternalSessionID) async -> ExternalSessionContentRecord? {
    guard let source = ImportSourceAgent(rawValue: id.source) else { return nil }
    return await records(of: source).first { $0.id == id }
  }

  /// Makes a new stream of the changes of the external sessions. Each call gives a new stream
  /// of its own.
  ///
  /// - A typed session that the index read or read again gives `changed`.
  /// - A session that became automated, or whose file is gone, gives `removed`.
  /// - A source whose root the index removed gives `domainRemoved`: a Remove Access, a new root
  ///   of the source, or a rebuild of its index. After a new root or a rebuild, the records of
  ///   the source come again as `changed`.
  ///
  /// The stream holds the newest changes that its subscriber did not read, and it drops the
  /// oldest ones. It ends when the subscriber stops it.
  ///
  /// - Returns: The stream of the changes after this call.
  public func changes()
    -> AsyncStream<ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>>
  {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>.self,
      bufferingPolicy: .bufferingNewest(SubscriberFeed<ULID>.defaultBufferLimit))
    let events = index.indexEvents()
    let task = Task {
      for await event in events {
        for gone in event.removedSources.sorted(by: { $0.rawValue < $1.rawValue }) {
          continuation.yield(.domainRemoved(gone))
        }
        for change in Self.changes(of: event) {
          continuation.yield(change)
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// The changes that one event of the index gives, for each source in the order of its name.
  ///
  /// - Parameter event: The event.
  /// - Returns: The changes: the typed sessions as `changed`, the automated and the removed
  ///   sessions as `removed`.
  private static func changes(of event: ExternalSessionIndexEvent)
    -> [ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>]
  {
    let changed = event.changed.map(\.summary)
    let typed = changed.filter { !$0.isAutomated }
    let gone = changed.filter(\.isAutomated) + event.removed.map(\.summary)
    var result: [ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>] = []
    for source in ImportSourceAgent.allCases {
      let records = typed.filter { $0.source == source.rawValue }.map(ExternalSessionContentRecord.init)
      if !records.isEmpty {
        result.append(.changed(source, records))
      }
      let ids = gone.filter { $0.source == source.rawValue }.map(\.id)
      if !ids.isEmpty {
        result.append(.removed(source, ids))
      }
    }
    return result
  }

  /// The records of each source, each list in the order of the source ids.
  ///
  /// - Returns: The records by source.
  private func allRecords() async -> [ImportSourceAgent: [ExternalSessionContentRecord]] {
    let sessions = await index.typedReadSessions()
    var records: [ImportSourceAgent: [ExternalSessionContentRecord]] = [:]
    for summary in sessions.sorted(by: { $0.sourceID < $1.sourceID }) {
      guard let source = ImportSourceAgent(rawValue: summary.source) else { continue }
      records[source, default: []].append(ExternalSessionContentRecord(summary))
    }
    return records
  }
}
