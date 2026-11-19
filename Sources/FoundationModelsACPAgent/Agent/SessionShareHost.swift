import ACPMarkdown
import Foundation
import FoundationModelsMultitool
import FoundationModelsRouter

// The share of a session as a link (D208 (g), (k)).
//
// The agent makes the snapshot of a session from its retained history. The host keeps the share:
// it saves the snapshot where the people of the share can open it, and gives the link. This
// package does not know where the host keeps a share. The host gives its share calls as a
// ``SessionShareHost``, and ``HostSessionSharer`` joins them to the snapshot of the agent. The
// `sessions` tool of each session gets that sharer through ``CatalogContext/sessionSharer``.

/// A source of the snapshot of a session: the session updates after the content rules of a
/// share, and their Markdown (`SessionSnapshot` of `ACPMarkdown`).
///
/// ``RoutedACPAgent`` is the source of the agent: it makes the snapshot from the retained
/// history of the session.
public protocol SessionSnapshotSource: Sendable {
  /// The snapshot of a session.
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - options: The content rules of the share.
  /// - Returns: The snapshot.
  /// - Throws: An error when the source has no history of the session.
  func snapshot(of session: ULID, options: SessionSnapshot.Options) async throws -> SessionSnapshot
}

/// The share calls of a host: the calls that save, update, read and stop the share of a session.
///
/// The host gives one to the `sessionShareHost` parameter of the initializer of
/// ``RoutedACPAgent``, or of the `compose` call of ``ComposedAgent``. The agent then gives a
/// ``HostSessionSharer`` over these calls to the `sessions` tool of each session. The agent does not update a share at the
/// end of a turn: a host with Keep Updated reads ``RoutedACPAgent/turnEnds()``.
public struct SessionShareHost: Sendable {
  /// A call that saves the snapshot of a session as its share, and gives the share.
  ///
  /// The arguments are the id of the session, the snapshot and the options of the share.
  public typealias Save =
    @Sendable (ULID, SessionSnapshot, SessionShareOptions) async throws -> SessionShare

  /// Saves the snapshot of a session as a new share, and gives the new share.
  public let share: Save

  /// Replaces the snapshot of the share of a session, keeps the options with the share, and
  /// gives the updated share. The link of the share does not change.
  public let update: Save

  /// Stops the share of a session: its link then opens nothing.
  public let stop: @Sendable (ULID) async throws -> Void

  /// The share of a session, or `nil` when the session has no share.
  public let currentShare: @Sendable (ULID) async throws -> SessionShare?

  /// A new stream of the id of each session whose share changed outside a call of the agent,
  /// for example on a different device.
  public let shareChanges: @Sendable () -> AsyncStream<ULID>

  /// Makes the share calls of a host.
  ///
  /// - Parameters:
  ///   - share: Saves the snapshot of a session as a new share.
  ///   - update: Replaces the snapshot of the share of a session.
  ///   - stop: Stops the share of a session.
  ///   - currentShare: Reads the share of a session.
  ///   - shareChanges: Makes a stream of the changes of the shares from outside the agent. The
  ///     default makes a stream that finishes at once, for a host with no such change.
  public init(
    share: @escaping Save,
    update: @escaping Save,
    stop: @escaping @Sendable (ULID) async throws -> Void,
    currentShare: @escaping @Sendable (ULID) async throws -> SessionShare?,
    shareChanges: @escaping @Sendable () -> AsyncStream<ULID> = { AsyncStream { $0.finish() } }
  ) {
    self.share = share
    self.update = update
    self.stop = stop
    self.currentShare = currentShare
    self.shareChanges = shareChanges
  }
}

/// The sharer of the sessions of the `sessions` tool over the share calls of a host: each share
/// and each update saves a new snapshot of the session from a ``SessionSnapshotSource``.
public struct HostSessionSharer: SessionSharer {
  /// The source of the snapshots.
  private let source: any SessionSnapshotSource

  /// The share calls of the host.
  private let host: SessionShareHost

  /// Makes the sharer.
  ///
  /// - Parameters:
  ///   - source: The source of the snapshots, for example the agent.
  ///   - host: The share calls of the host.
  public init(source: any SessionSnapshotSource, host: SessionShareHost) {
    self.source = source
    self.host = host
  }

  /// Saves a snapshot of the session now as a new share.
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - options: The content and the state of the share.
  /// - Returns: The new share.
  /// - Throws: The error of the snapshot or of the host.
  public func share(_ session: ULID, options: SessionShareOptions) async throws -> SessionShare {
    try await host.share(session, try await snapshot(of: session, options: options), options)
  }

  /// Replaces the snapshot of the share of the session with a snapshot of the session now.
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - options: The options of the share after the update.
  /// - Returns: The updated share.
  /// - Throws: The error of the snapshot or of the host.
  public func update(_ session: ULID, options: SessionShareOptions) async throws -> SessionShare {
    try await host.update(session, try await snapshot(of: session, options: options), options)
  }

  /// Stops the share of the session.
  ///
  /// - Parameter session: The id of the session.
  /// - Throws: The error of the host.
  public func stop(_ session: ULID) async throws {
    try await host.stop(session)
  }

  /// The share of the session.
  ///
  /// - Parameter session: The id of the session.
  /// - Returns: The share, or `nil` when the session has no share.
  /// - Throws: The error of the host.
  public func share(of session: ULID) async throws -> SessionShare? {
    try await host.currentShare(session)
  }

  /// The ids of the sessions whose share changed outside a call of the agent.
  ///
  /// - Returns: The stream of the host.
  public func shareChanges() -> AsyncStream<ULID> {
    host.shareChanges()
  }

  /// The snapshot of a session with the content rules of the options of a share.
  ///
  /// - Parameters:
  ///   - session: The id of the session.
  ///   - options: The options of the share.
  /// - Returns: The snapshot.
  /// - Throws: The error of the source.
  private func snapshot(of session: ULID, options: SessionShareOptions) async throws
    -> SessionSnapshot
  {
    try await source.snapshot(
      of: session,
      options: SessionSnapshot.Options(
        includeThoughts: options.includeThoughts, includeToolOutput: options.includeToolOutput))
  }
}

extension RoutedACPAgent {
  /// The sharer of the `sessions` tool of a session: a ``HostSessionSharer`` over the share calls
  /// of the host (``sessionShareHost``), or `nil` for a host with no share calls. Its source is an
  /// ``AgentTranscriptExporter``, which holds the agent weakly, so the sharer makes no cycle.
  ///
  /// - Returns: The sharer, or `nil`.
  nonisolated func sessionSharer() -> HostSessionSharer? {
    sessionShareHost.map {
      HostSessionSharer(source: AgentTranscriptExporter(agent: self), host: $0)
    }
  }
}
