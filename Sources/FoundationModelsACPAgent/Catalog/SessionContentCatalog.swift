import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The record of one session for the content catalog of a host (D214, part 1): the session item
/// of D207 (b)(1), given to the host.
public struct SessionContentRecord: Sendable, Equatable, Codable, Identifiable {
  /// The id of the session.
  public let id: ULID

  /// The short id of the session.
  public let shortID: String

  /// The slug of the session.
  public let slug: String

  /// The name of the session, or `nil` when it has none.
  public let name: String?

  /// The working folder of the session.
  public let folder: URL

  /// The tags of the session, sorted.
  public let tags: [String]

  /// The name of the agent of the session, or `nil`.
  public let agentName: String?

  /// The kind of the session: a root, a child agent run, or a fork.
  public let kind: SessionKind

  /// What made the session.
  public let origin: SessionDirectoryOrigin

  /// The date when the session was made.
  public let createdAt: Date

  /// The date of the last use by a client, or `nil`.
  public let lastUsedAt: Date?

  /// The date of the archive, or `nil` for a session that is not archived.
  public let archivedAt: Date?

  /// True when the session is pinned.
  public let isPinned: Bool

  /// The one-sentence recap of the session, or `nil`.
  public let recap: String?

  /// The last final message of the session, or `nil`.
  public let lastSummary: String?

  /// The record of a summary of the session directory.
  ///
  /// - Parameter summary: The summary.
  init(_ summary: SessionSummary) {
    id = summary.id
    shortID = summary.shortID
    slug = summary.slug
    name = summary.title
    folder = summary.workingDirectory
    tags = summary.tags.sorted()
    agentName = summary.agentName
    kind = summary.kind
    origin = summary.origin
    createdAt = summary.createdAt
    lastUsedAt = summary.lastUsedAt
    archivedAt = summary.archivedAt
    isPinned = summary.isPinned
    recap = summary.recap
    lastSummary = summary.lastSummary
  }

  /// The stamp of the record: the hash of its JSON form with sorted keys and dates in
  /// milliseconds.
  var stamp: ContentStamp {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let text = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return ContentStamp.hashing([text])
  }
}

/// The sessions part of the content catalog (D214, part 1). A domain is one session, and it has
/// one record. The part reads the sessions that the session directory lists, live and recorded,
/// and only those of a folder that the `readableFolder` rule of the host permits (D207 (b)(7)).
public struct SessionContentCatalog: Sendable {
  /// The session directory of the server.
  private let directory: any SessionDirectory

  /// Tells whether the process can read a folder now with no prompt.
  private let readableFolder: @Sendable (URL) -> Bool

  /// The sessions that `session/delete` removed.
  private let removals: SubscriberFeed<ULID>

  /// Makes the part.
  ///
  /// - Parameters:
  ///   - directory: The session directory of the server.
  ///   - readableFolder: The folder rule of the host.
  ///   - removals: The feed of the sessions that `session/delete` removed.
  init(
    directory: any SessionDirectory, readableFolder: @escaping @Sendable (URL) -> Bool,
    removals: SubscriberFeed<ULID>
  ) {
    self.directory = directory
    self.readableFolder = readableFolder
    self.removals = removals
  }

  /// The stamp of each session. A stamp changes when a field of the record of the session
  /// changes.
  ///
  /// - Returns: The stamp of each session of a readable folder.
  /// - Throws: The error of the session directory.
  public func stamps() async throws -> [ULID: ContentStamp] {
    let summaries = try await directory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    return summaries.reduce(into: [:]) { stamps, summary in
      guard readableFolder(summary.workingDirectory) else { return }
      stamps[summary.id] = SessionContentRecord(summary).stamp
    }
  }

  /// The records of one session: its one record, or none.
  ///
  /// - Parameter session: The session.
  /// - Returns: The record in an array, or an empty array for a session that the directory does
  ///   not know or whose folder the rule refuses.
  /// - Throws: The error of the session directory.
  public func records(of session: ULID) async throws -> [SessionContentRecord] {
    try await record(session).map { [$0] } ?? []
  }

  /// The record of one session.
  ///
  /// - Parameter id: The session.
  /// - Returns: The record, or `nil` for a session that the directory does not know or whose
  ///   folder the rule refuses.
  /// - Throws: The error of the session directory.
  public func record(_ id: ULID) async throws -> SessionContentRecord? {
    guard let summary = try await directory.summary(of: id),
      readableFolder(summary.workingDirectory)
    else {
      return nil
    }
    return SessionContentRecord(summary)
  }

  /// Makes a new stream of the changes of the sessions. Each call gives a new stream of its own.
  ///
  /// - A start, a change of the facts (a name, the tags, the pin, the last use), a change of the
  ///   state (the last summary), an archive and an unarchive give `changed` with the record.
  /// - `session/delete` gives `domainRemoved` for the session and for each session in its
  ///   folder (its children and its forks).
  ///
  /// The stream holds the newest changes that its subscriber did not read, and it drops the
  /// oldest ones. It ends when the subscriber stops it.
  ///
  /// - Returns: The stream of the changes after this call.
  public func changes() -> AsyncStream<ContentCatalogChange<ULID, SessionContentRecord>> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ContentCatalogChange<ULID, SessionContentRecord>.self,
      bufferingPolicy: .bufferingNewest(SubscriberFeed<ULID>.defaultBufferLimit))
    let events = directory.events()
    let removed = removals.subscribe()
    let part = self
    let task = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await event in events {
            if let change = await part.change(for: event) {
              continuation.yield(change)
            }
          }
        }
        group.addTask {
          for await id in removed {
            continuation.yield(.domainRemoved(id))
          }
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// The change of the catalog that an event of the session directory gives.
  ///
  /// - Parameter event: The event.
  /// - Returns: The change, or `nil` for an event that changes no record, or for a session whose
  ///   folder the rule refuses.
  private func change(for event: SessionDirectoryEvent) async
    -> ContentCatalogChange<ULID, SessionContentRecord>?
  {
    let record: SessionContentRecord?
    switch event {
    case .started(let summary, _), .factsChanged(let summary):
      record = readableFolder(summary.workingDirectory) ? SessionContentRecord(summary) : nil
    case .stateChanged(let id, _, _), .archived(let id), .unarchived(let id):
      record = try? await self.record(id)
    default:
      record = nil
    }
    return record.map { .changed($0.id, [$0]) }
  }
}
