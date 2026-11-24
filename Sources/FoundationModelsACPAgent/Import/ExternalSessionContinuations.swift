import Foundation
import FoundationModelsExtras

/// The earlier copies of each external session: the sessions of the directory that a continue
/// made from it, the oldest first.
///
/// The first call reads each session of the directory one time, also the sessions that are on
/// disk only, and keeps the sessions whose `importedFrom` names an external session. Each copy
/// of the importer after that adds its new session (``add(_:)``). A read that fails keeps
/// nothing, so the next call reads again.
actor ExternalSessionContinuations {
  /// The copies of each external session, the oldest first, or `nil` before the first read.
  private var copies: [ExternalSessionID: [ExternalSessionContinuation]]?

  /// The session directory.
  private let directory: any SessionDirectory

  /// Makes the record.
  ///
  /// - Parameter directory: The session directory.
  init(directory: any SessionDirectory) {
    self.directory = directory
  }

  /// The copies of some external sessions.
  ///
  /// - Parameter sessions: The external sessions.
  /// - Returns: The copies of each session that has a copy, the oldest first.
  func continuations(of sessions: [ExternalSessionID]) async
    -> [ExternalSessionID: [ExternalSessionContinuation]]
  {
    guard !sessions.isEmpty else { return [:] }
    if copies == nil { await load() }
    let all = copies ?? [:]
    return Dictionary(uniqueKeysWithValues: sessions.compactMap { id in all[id].map { (id, $0) } })
  }

  /// Adds a session of the directory that a continue made.
  ///
  /// - Parameter summary: The summary of the new session.
  func add(_ summary: SessionSummary) {
    guard copies != nil, let entry = Self.entry(of: summary) else { return }
    copies = Self.merging([entry], into: copies ?? [:])
  }

  /// Reads the copies from the directory. A copy that ``add(_:)`` added while the read ran
  /// stays.
  private func load() async {
    do {
      let summaries = try await directory.sessions(
        matching: SessionQuery(includesRecorded: true, limit: .max))
      copies = Self.merging(summaries.compactMap(Self.entry(of:)), into: copies ?? [:])
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The importer cannot read the sessions of the directory for the earlier copies.",
        metadata: ["error": "\(error)"])
    }
  }

  /// The external session and the copy of a session of the directory, or `nil` for a session
  /// that no continue made.
  private static func entry(of summary: SessionSummary)
    -> (ExternalSessionID, ExternalSessionContinuation)?
  {
    guard let provenance = summary.importedFrom else { return nil }
    return (
      ExternalSessionID(source: provenance.agent, sourceID: provenance.sourceID),
      ExternalSessionContinuation(sessionID: summary.id, createdAt: summary.createdAt)
    )
  }

  /// Adds copies to a record, with no copy two times, the oldest first.
  private static func merging(
    _ entries: [(ExternalSessionID, ExternalSessionContinuation)],
    into record: [ExternalSessionID: [ExternalSessionContinuation]]
  ) -> [ExternalSessionID: [ExternalSessionContinuation]] {
    var record = record
    for (id, copy) in entries where !(record[id] ?? []).contains(where: { $0.sessionID == copy.sessionID }) {
      record[id, default: []].append(copy)
    }
    for id in Set(entries.map(\.0)) {
      record[id]?.sort { ($0.createdAt, $0.sessionID.description) < ($1.createdAt, $1.sessionID.description) }
    }
    return record
  }
}
