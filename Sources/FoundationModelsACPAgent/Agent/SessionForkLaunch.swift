import Foundation
import FoundationModelsACP
import FoundationModelsRouter

// The build of a fork through the launcher of the session directory (D205).
//
// `RouterSessionDirectory.fork(_:)` maps the cut and chooses the id of the fork. Then it asks the
// launcher of the agent for the fork (`AgentSessionLauncher.forkSession(_:)`). The agent builds
// the fork with a surface of its own and puts it in its session table. Only after that does the
// directory register the fork and mail its first prompt. Thus the first prompt runs on the
// surface of the agent, and the agent holds the fork from its start: a `session/resume` of the
// fork takes the live fork, and nothing stops and restores it.

/// The key of one `session/fork` request while the launcher builds its fork: the source of the
/// fork, and the connection that asked for it. The session directory gives the launcher the same
/// two values (`SessionLaunchForkRequest.sourceID` and `requestedByClient`).
struct ForkLaunchKey: Hashable, Sendable {
  /// The id of the source of the fork.
  let source: ULID

  /// The raw value of the connection of the `session/fork` request.
  let client: String
}

/// What one `session/fork` request gives its fork. The launcher reads it when it builds the
/// fork, and it writes the activation of the fork back.
struct RequestedFork: Sendable {
  /// Where the fork works, its user presence, and the MCP servers of the request.
  let placement: SessionPlacement

  /// The history that the fork copies from its source, at the cut of the request.
  let copiedHistory: SessionMergeEngine

  /// The connection of the request, which owns the fork.
  let caller: ConnectionId

  /// The activation of the mounted fork, or `nil` until the launcher mounted it.
  var activation: SessionActivation?
}

/// The `session/fork` requests whose forks the launcher of the session directory builds now
/// (D205).
///
/// The directory calls the launcher with the source and the client of the fork, not with the
/// request of the agent. So the agent keeps each request by its key (``ForkLaunchKey``) until the
/// launcher reads it. The directory can call the launchers of two forks in any order, so one key
/// holds one request at a time: a second request with the same key waits until the first one
/// ends (``RoutedACPAgent/reserveForkLaunch(_:)``).
struct ForkLaunchBook: Sendable {
  /// The keys that a `session/fork` request holds now.
  var reserved: Set<ForkLaunchKey> = []

  /// The request of each held key, from the time that the request knows its surface.
  var requests: [ForkLaunchKey: RequestedFork] = [:]

  /// The requests that wait for a key, in the order that they came.
  var waiters: [ForkLaunchKey: [CheckedContinuation<Void, Never>]] = [:]
}

extension RoutedACPAgent {
  /// Waits until no other `session/fork` request holds `key`, and then holds it. The caller
  /// releases the key with ``releaseForkLaunch(_:)``.
  ///
  /// - Parameter key: The source and the client of the fork.
  func reserveForkLaunch(_ key: ForkLaunchKey) async {
    while forkLaunches.reserved.contains(key) {
      await withCheckedContinuation { continuation in
        forkLaunches.waiters[key, default: []].append(continuation)
      }
    }
    forkLaunches.reserved.insert(key)
  }

  /// Releases a key that ``reserveForkLaunch(_:)`` held, removes its request, and lets the
  /// requests that wait for the key go on.
  ///
  /// - Parameter key: The source and the client of the fork.
  func releaseForkLaunch(_ key: ForkLaunchKey) {
    forkLaunches.reserved.remove(key)
    forkLaunches.requests[key] = nil
    for waiter in forkLaunches.waiters.removeValue(forKey: key) ?? [] {
      waiter.resume()
    }
  }

  /// Builds the fork of `request` with a surface of this agent, and puts it in the session table:
  /// the work of ``AgentSessionLauncher/forkSession(_:)``.
  ///
  /// The surface:
  ///
  /// - For a `session/fork` request of this agent (``RequestedFork``): the MCP servers and the
  ///   additional directories of that request, and the user presence of its connection. An
  ///   omitted list gives none (ACP).
  /// - For each other fork (the `fork session` operation of the `sessions` tool, or a fork that a
  ///   client asks for through the `sessions` endpoint): the MCP servers, the additional
  ///   directories and the user presence of the source (``sourceForkPlacement(of:)``).
  ///
  /// The fork has the agent of its source (``recordForkAgent(of:for:in:)``). The agent builds the
  /// fork through `request` one time (`SessionLaunchForkRequest.makeFork(tools:)`). The session
  /// directory made the cut, so the agent does not map it again. Then the agent mounts the fork
  /// (``mountFork(_:composition:placement:history:owner:)``).
  ///
  /// The session directory registers the fork and mails its first prompt after this call. The
  /// record of the additional directories of a `session/fork` comes after the registration
  /// (``forkSession(_:from:)``).
  ///
  /// - Parameter request: The fork request of the session directory.
  /// - Returns: The fork, mounted and not registered.
  /// - Throws: Whatever the load of the configuration, the composition, the build, the write of
  ///   the history or the mount throws. A throw after the composition releases the surface. The
  ///   session directory then refuses the fork and removes its recording folder.
  func launchFork(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
    let forkId = SessionId(rawValue: request.forkID.description)
    let key = request.requestedByClient.map { ForkLaunchKey(source: request.sourceID, client: $0) }
    let requested = key.flatMap { forkLaunches.requests[$0] }
    let placement = requested?.placement ?? sourceForkPlacement(of: request)
    let context = try await loadSessionContext(workingDirectory: placement.workingDirectory)
    recordForkAgent(of: request.sourceID, for: forkId, in: context.transcriptRoot)
    let composition = try await composeSession(
      from: context, workingDirectory: placement.workingDirectory,
      additionalRoots: placement.additionalRoots, clientMCPServers: placement.clientMCPServers,
      userPresence: placement.userPresence, resuming: forkId)
    do {
      let fork = try await request.makeFork(tools: composition.surface.tools)
      let history: SessionMergeEngine
      if let requested {
        history = requested.copiedHistory
      } else {
        history = await toolForkHistory(of: fork, source: request.sourceID)
      }
      let activation = try await mountFork(
        fork, composition: composition, placement: placement, history: history,
        owner: requested?.caller)
      if let key {
        forkLaunches.requests[key]?.activation = activation
      }
      return fork
    } catch {
      composition.surface.shellOutput?.finish()
      await composition.surface.shutdown()
      throw error
    }
  }

  /// Mounts a fork that the launcher built, before the session directory registers it.
  ///
  /// The agent writes the copied history to the history file of the fork first
  /// (``SessionHistoryFile``), also when the copy is empty. Thus each later restore of the fork
  /// reads the copy, also in a new process. The hooks of the fork see the key of its folder, as
  /// for each other session of the folder. The connection of a `session/fork` request owns the
  /// fork before the mount, so each update of the mount goes to it. A fork with no owner keeps
  /// its updates in its retained history until a connection takes it with `session/resume`.
  ///
  /// - Parameters:
  ///   - fork: The fork, not registered.
  ///   - composition: The composition of the fork.
  ///   - placement: Where the fork works.
  ///   - history: The history that the fork copies from its source.
  ///   - owner: The connection that owns the fork, or `nil` for none.
  /// - Returns: The activation of the fork.
  /// - Throws: Whatever the write of the history file or the mount throws.
  private func mountFork(
    _ fork: any RoutedSession, composition: SessionComposition, placement: SessionPlacement,
    history: SessionMergeEngine, owner: ConnectionId?
  ) async throws -> SessionActivation {
    let forkId = SessionId(rawValue: fork.id.description)
    try SessionHistoryFile.write(history, in: fork.recordingDirectory)
    SnapshotSessionKeys.shared.record(
      HookLineage(workingDirectory: placement.workingDirectory, origin: .forked).sessionKey,
      for: forkId)
    if let owner {
      connections.recordStart(of: forkId, by: owner)
    }
    return try await mountSession(
      fork, composition: composition, placement: placement, history: history)
  }

  /// The placement of a fork that no `session/fork` request of this agent asked for: the folder
  /// of the fork, with the additional directories, the user presence and the MCP servers of its
  /// source. A source that the table does not hold gives no additional directory, no MCP server
  /// and the presence of a user.
  ///
  /// - Parameter request: The fork request of the session directory.
  /// - Returns: The placement.
  private func sourceForkPlacement(of request: SessionLaunchForkRequest) -> SessionPlacement {
    let source = sessions[SessionId(rawValue: request.sourceID.description)]
    return SessionPlacement(
      workingDirectory: request.workingDirectory,
      additionalRoots: source?.additionalRoots ?? [],
      userPresence: source?.userPresence ?? .interactive,
      clientMCPServers: source?.clientMCPServers ?? [])
  }

  /// Records the agent of the source of a fork as the agent of the fork
  /// (``SessionAgentStore``), so the composition of the fork and each later restore of it read
  /// the agent of the source. A source with no agent record records nothing: the fork then gets
  /// the agent of a new session. A failed write goes to the log, with the same result.
  ///
  /// - Parameters:
  ///   - source: The source of the fork.
  ///   - forkId: The fork.
  ///   - transcriptRoot: The recording root of the source and of the fork.
  private func recordForkAgent(of source: ULID, for forkId: SessionId, in transcriptRoot: URL) {
    guard
      let choice = SessionAgentStore.choice(
        of: SessionId(rawValue: source.description), in: transcriptRoot)
    else {
      return
    }
    do {
      try SessionAgentStore.record(choice, for: forkId, in: transcriptRoot)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The agent of the source of a fork was not recorded for the fork. The fork gets the agent of a new session.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: forkId))
    }
  }

  /// The history that a fork copies when no `session/fork` request of this agent asked for it:
  /// the part of the retained history of its source that the fork knows.
  ///
  /// The agent does not know the cut of such a fork. The tool calls of the transcript of the fork
  /// name the tool calls that it keeps, so the part ends before the call that forked
  /// (``SessionMergeEngine/forkEnd(keepingToolCalls:)``). The Router sends the event of a tool
  /// call before it runs the tool body, and the launcher reads the history only after the
  /// composition of the fork. When the source left out no tool call,
  /// the fork did not fork at a call, and the agent does not know its cut: the fork then copies
  /// no entry, and never shows the whole source. The source history is the one in the table, else
  /// the one in the file of the source: a fork records in the folder of its source.
  ///
  /// - Parameters:
  ///   - fork: The fork, built.
  ///   - source: The source of the fork.
  /// - Returns: The copied history, empty when the agent does not know the cut.
  private func toolForkHistory(of fork: any RoutedSession, source: ULID) async
    -> SessionMergeEngine
  {
    let sourceId = SessionId(rawValue: source.description)
    let sourceHistory =
      sessions[sourceId]?.history
      ?? retainedHistory(
        kept: nil, directory: fork.recordingDirectory.deletingLastPathComponent(),
        sessionId: sourceId)
    let kept = await fork.transcript.toolCallIds
    guard let end = sourceHistory.forkEnd(keepingToolCalls: kept) else {
      return SessionMergeEngine()
    }
    return sourceHistory.copiedHistory(endingAt: end)
  }
}
