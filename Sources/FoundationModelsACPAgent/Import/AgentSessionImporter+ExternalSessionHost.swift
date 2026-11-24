import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool

/// The importer is the host of the external sessions of the `sessions` endpoint and tool
/// (D212, sections 4.5, 5.3 and 5.4): the query and the changes read the index, the updates read
/// one file as a stream, and the continue is the copy of
/// ``AgentSessionImporter/copySession(of:folder:name:)``.
extension AgentSessionImporter: ExternalSessionHost {
  /// The number of bytes of each read of the stream of a read-only view: 1 MB (section 5.3).
  static let updateBlockSize = 1_048_576

  func externalSessions(_ query: ExternalSessionQuery) async throws -> ExternalSessionPage {
    var page = try await index.externalSessions(query)
    page.sessions = await decorated(page.sessions)
    return page
  }

  /// The changes of the index, with the fields of ``decorated(_:)`` on each changed session.
  /// The end of the iteration stops the stream of the index.
  func externalSessionChanges(folder: URL?) -> AsyncStream<ExternalSessionChange> {
    let changes = index.externalSessionChanges(folder: folder)
    let (stream, continuation) = AsyncStream.makeStream(of: ExternalSessionChange.self)
    let relay = Task {
      for await change in changes {
        var change = change
        change.changed = await decorated(change.changed)
        continuation.yield(change)
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in relay.cancel() }
    return stream
  }

  /// The summary of one external session, as a row of a page gives it, with the fields of
  /// ``decorated(_:)``. The call reads no file and does not wait for the index.
  ///
  /// - Throws: ``ExternalSessionError/sourceUnreadable(source:)`` for an unknown source or a
  ///   source with no root, and `CancellationError` when the task is cancelled.
  func externalSession(_ session: ExternalSessionID) async throws -> ExternalSessionSummary? {
    try Task.checkCancellation()
    guard let agent = ImportSourceAgent(rawValue: session.source), await index.sources.contains(agent)
    else {
      throw ExternalSessionError.sourceUnreadable(source: session.source)
    }
    guard let summary = await index.readSummary(matching: session.sourceID, of: agent) else {
      return nil
    }
    return await decorated([summary]).first
  }

  func externalSessionCounts(source: String?, folder: URL?) async throws -> ExternalSessionCounts {
    try await index.externalSessionCounts(source: source, folder: folder)
  }

  /// Builds the index of one source again (``ExternalSessionIndex/rebuild(_:)``). The call
  /// returns when the new find starts.
  ///
  /// - Throws: ``ExternalSessionError/sourceUnreadable(source:)`` for an unknown source or a
  ///   source with no root, and `CancellationError` when the task is cancelled.
  func rebuildExternalSessionIndex(source: String) async throws {
    try Task.checkCancellation()
    guard let agent = ImportSourceAgent(rawValue: source), await index.rebuild(agent) else {
      throw ExternalSessionError.sourceUnreadable(source: source)
    }
  }

  /// The history of one external session, in batches. The read runs in a task of the stream: the
  /// end of the iteration, or the cancel of the task that reads the stream, cancels the read
  /// before its next block.
  func externalSessionUpdates(of session: ExternalSessionID) -> AsyncThrowingStream<
    ExternalSessionUpdateBatch, any Error
  > {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: ExternalSessionUpdateBatch.self, throwing: (any Error).self)
    let read = Task {
      do {
        try await streamUpdates(of: session, into: continuation)
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in read.cancel() }
    return stream
  }

  func continueExternalSession(_ request: ExternalSessionContinueRequest) async throws
    -> SessionSummary
  {
    do {
      try Task.checkCancellation()
      return try await copySession(of: request.session, folder: request.folder, name: request.name)
    } catch let error as AgentSessionImportError {
      throw Self.externalError(of: error, session: request.session)
    }
  }

  // MARK: - The fields of the host

  /// The summaries with the fields that the index does not keep: the earlier copies of each
  /// session (``ExternalSessionContinuations``), and the absolute file URL
  /// (``fileURL(of:roots:)``).
  ///
  /// - Parameter summaries: The summaries of the index.
  /// - Returns: The summaries with the fields.
  func decorated(_ summaries: [ExternalSessionSummary]) async -> [ExternalSessionSummary] {
    guard !summaries.isEmpty else { return summaries }
    let roots = await index.rootURLs.mapValues {
      URL(fileURLWithPath: $0.canonicalPath, isDirectory: true)
    }
    let copies = await continuations.continuations(of: summaries.map(\.id))
    return summaries.map { summary in
      var summary = summary
      summary.continuedSessions = copies[summary.id] ?? []
      summary.fileURL = Self.fileURL(of: summary, roots: roots)
      return summary
    }
  }

  /// The absolute URL of the file of a session: the root, with its symbolic links resolved,
  /// plus the path of the session. A path that leaves the root (for example with `..`) gives
  /// no URL, so a client never gets a file outside the grant of the root.
  ///
  /// - Parameters:
  ///   - summary: The summary.
  ///   - roots: The resolved root of each source agent.
  /// - Returns: The file URL, or `nil` for a source with no root or a path outside the root.
  static func fileURL(of summary: ExternalSessionSummary, roots: [ImportSourceAgent: URL]) -> URL? {
    guard let agent = ImportSourceAgent(rawValue: summary.source), let root = roots[agent] else {
      return nil
    }
    let file = root.appendingPathComponent(summary.path).standardizedFileURL
    guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
    return file
  }

  // MARK: - The stream

  /// Reads the file of one external session and gives each batch of its updates.
  ///
  /// - Parameters:
  ///   - session: The external session.
  ///   - continuation: The input of the stream.
  /// - Throws: ``ExternalSessionError/unknownSession(_:)`` for an unknown source agent or a
  ///   session that the index does not hold, ``ExternalSessionError/sourceUnreadable(source:)``
  ///   for a source with no root, a `CancellationError`, and the error of the read.
  private func streamUpdates(
    of session: ExternalSessionID,
    into continuation: AsyncThrowingStream<ExternalSessionUpdateBatch, any Error>.Continuation
  ) async throws {
    guard let agent = ImportSourceAgent(rawValue: session.source) else {
      throw ExternalSessionError.unknownSession(session)
    }
    guard await index.sources.contains(agent) else {
      throw ExternalSessionError.sourceUnreadable(source: session.source)
    }
    guard let located = await index.session(matching: session.sourceID, of: agent) else {
      throw ExternalSessionError.unknownSession(session)
    }
    let source = try FileByteSource(forReadingFrom: located.file)
    let date = located.summary.lastDate ?? located.summary.modified
    let batches = agent.updates(
      from: source, fileNamed: located.file.lastPathComponent, blockSize: Self.updateBlockSize)
    for try await batch in batches {
      let entries = batch.compactMap { Self.entry(of: $0, at: date) }
      guard !entries.isEmpty else { continue }
      continuation.yield(ExternalSessionUpdateBatch(entries: entries))
    }
  }

  /// The key of the kind of an update in its ACP JSON form.
  private static let updateKindKey = "sessionUpdate"

  /// One entry of the history of a read-only view: the kind is the ACP name of the update (for
  /// example `agent_message_chunk`), and the payload is each other field of the update, with the
  /// changes of ``TranscriptEntryMapping/operationValue(from:doubleFields:key:)``.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - date: The time of the entry. A session file gives no time for each update, so each entry
  ///     of a session has the last date of the session.
  /// - Returns: The entry, or `nil` when the update does not encode as a JSON object with a kind.
  static func entry(of update: SessionUpdate, at date: Date) -> SessionTranscriptEntry? {
    guard let data = try? JSONEncoder().encode(update),
      var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let kind = fields.removeValue(forKey: updateKindKey) as? String
    else {
      return nil
    }
    let payload =
      TranscriptEntryMapping.operationValue(from: fields, doubleFields: []) ?? .object([:])
    return SessionTranscriptEntry(kind: kind, timestamp: date, payload: payload)
  }

  // MARK: - The errors

  /// The error of the external sessions for an error of the copy. An error with no case of
  /// ``ExternalSessionError`` stays as it is.
  ///
  /// - Parameters:
  ///   - error: The error of the copy.
  ///   - session: The external session of the continue.
  /// - Returns: The error to throw.
  private static func externalError(
    of error: AgentSessionImportError, session: ExternalSessionID
  ) -> any Error {
    switch error {
    case .unknownAgent, .unknownSource:
      ExternalSessionError.unknownSession(session)
    case .sourceUnreadable:
      ExternalSessionError.sourceUnreadable(source: session.source)
    case .folderUnavailable(let folder):
      ExternalSessionError.folderUnavailable(folder)
    case .noFolder:
      error
    }
  }
}
