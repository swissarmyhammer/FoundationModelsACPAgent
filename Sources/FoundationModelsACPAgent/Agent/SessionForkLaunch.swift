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

/// The id of one `session/fork` request while the session directory builds its fork (D205).
///
/// The handler of the request sets the id as a task local around its call of
/// `RouterSessionDirectory.fork(_:)` (``RoutedACPAgent/whileForkRequestWaits(_:_:)``). The
/// Router calls the launcher of the fork (`SessionLauncher.forkSession(_:)`) in the task of that
/// caller, with no new task between them, so the launcher reads the id of the request that it
/// builds (``AgentSessionLauncher/forkSession(_:)``). A fork that the agent did not ask for (the
/// `fork session` operation of the `sessions` tool, or a fork that a client asks for through the
/// `sessions` endpoint) runs in another task, so it has no id and cannot take the request.
struct ForkLaunchID: RawRepresentable, Hashable, Sendable {
  /// The `session/fork` request that the current task waits for, or `nil` for none.
  @TaskLocal static var current: ForkLaunchID?

  /// The unique value of the id.
  let rawValue: UUID
}

/// The error of a fork with no `session/fork` request whose source history does not hold the
/// tool call that forked (D205).
///
/// The launcher throws it, so the session directory refuses the fork, removes its recording
/// folder and registers nothing. The `sessions` tool puts the text of this error in its
/// corrective.
enum ToolForkHistoryError: Error, CustomStringConvertible {
  /// The retained history of the source did not record the calling tool call in the time limit.
  case callingToolCallNotRecorded(source: SessionId, timeLimit: Duration)

  /// The text of the error, which tells the model what to do.
  var description: String {
    switch self {
    case .callingToolCallNotRecorded(let source, let timeLimit):
      "The history of the session \(source.rawValue) did not record the tool call that forks it "
        + "in \(timeLimit), so no fork was made. Try the call again."
    }
  }
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

extension RoutedACPAgent {
  /// The default of ``forkCallRecordTimeLimit``. The record of a tool call is one step of the
  /// projector of the source and one step of this actor, so it comes in much less time. The
  /// limit leaves room for a projector that waits on a slow send to the client.
  static let defaultForkCallRecordTimeLimit = Duration.seconds(
    defaultForkCallRecordTimeLimitSeconds)

  /// The length of ``defaultForkCallRecordTimeLimit``, in seconds.
  private static let defaultForkCallRecordTimeLimitSeconds = 10

  /// The time between two looks at the retained history of the source while the launcher waits
  /// for the record of the calling tool call (``forkCallRecordTimeLimit``).
  static let forkCallRecordLookInterval = Duration.milliseconds(
    forkCallRecordLookIntervalMilliseconds)

  /// The length of ``forkCallRecordLookInterval``, in milliseconds.
  private static let forkCallRecordLookIntervalMilliseconds = 10

  /// Runs `body` while `requested` waits for its launcher: the `session/fork` request gets a new
  /// id (``ForkLaunchID``), the agent keeps the request by that id, and `body` runs with the id
  /// as the task local ``ForkLaunchID/current``. The agent removes the request when `body` ends.
  ///
  /// Each request has its own id, so two requests never share an entry, also for the same source
  /// and the same client.
  ///
  /// - Parameters:
  ///   - requested: The surface and the copied history of the request.
  ///   - body: The work that forks through the session directory.
  /// - Returns: The result of `body`, and the activation of the fork that the launcher mounted
  ///   for the request, or `nil` when the launcher mounted no fork for it.
  /// - Throws: Whatever `body` throws.
  func whileForkRequestWaits<Result: Sendable>(
    _ requested: RequestedFork, _ body: @Sendable () async throws -> Result
  ) async throws -> (result: Result, activation: SessionActivation?) {
    let launch = ForkLaunchID(rawValue: UUID())
    forkLaunches[launch] = requested
    defer { forkLaunches[launch] = nil }
    let result = try await ForkLaunchID.$current.withValue(launch) {
      try await body()
    }
    return (result, forkLaunches[launch]?.activation)
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
  /// fork through `request` one time, with the tools and the additional directories of its
  /// surface (`SessionLaunchForkRequest.makeFork(tools:additionalDirectories:)`). The Router
  /// writes the directories to the `index.md` record of the fork, so the record holds them also
  /// after a restart. The session directory made the cut, so the agent does not map it again. A
  /// fork with no request copies the history of its source up to the call that forked, after the
  /// history recorded that call (``toolForkHistory(of:source:)``). Then the agent mounts the fork
  /// (``mountFork(_:composition:placement:history:owner:)``).
  ///
  /// The session directory registers the fork and mails its first prompt after this call.
  ///
  /// - Parameters:
  ///   - request: The fork request of the session directory.
  ///   - launch: The id of the `session/fork` request that the fork is for
  ///     (``ForkLaunchID/current``), or `nil` for a fork that no request of this agent asked for.
  /// - Returns: The fork, mounted and not registered.
  /// - Throws: Whatever the load of the configuration, the composition, the build, the write of
  ///   the history or the mount throws, and the error of a tool fork whose source history does
  ///   not record the calling tool call in the time limit (``ToolForkHistoryError``). A throw
  ///   after the composition releases the surface. The session directory then refuses the fork
  ///   and removes its recording folder.
  func launchFork(_ request: SessionLaunchForkRequest, for launch: ForkLaunchID?) async throws
    -> any RoutedSession
  {
    let forkId = SessionId(rawValue: request.forkID.description)
    let requested = launch.flatMap { forkLaunches[$0] }
    let placement = requested?.placement ?? sourceForkPlacement(of: request)
    let context = try await loadSessionContext(workingDirectory: placement.workingDirectory)
    recordForkAgent(of: request.sourceID, for: forkId, in: context.transcriptRoot)
    let composition = try await composeSession(
      from: context, workingDirectory: placement.workingDirectory,
      additionalRoots: placement.additionalRoots, clientMCPServers: placement.clientMCPServers,
      userPresence: placement.userPresence, resuming: forkId)
    do {
      let fork = try await request.makeFork(
        tools: composition.surface.tools, additionalDirectories: placement.additionalRoots)
      let history: SessionMergeEngine
      if let requested {
        history = requested.copiedHistory
      } else {
        history = try await toolForkHistory(of: fork, source: request.sourceID)
      }
      let activation = try await mountFork(
        fork, composition: composition, placement: placement, history: history,
        owner: requested?.caller)
      if let launch {
        forkLaunches[launch]?.activation = activation
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
  /// the agent of a new session. A failed write goes to the log, with the same result
  /// (``recordAgent(_:for:in:)``).
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
    recordAgent(choice, for: forkId, in: transcriptRoot)
  }

  /// The history that a fork copies when no `session/fork` request of this agent asked for it:
  /// the part of the retained history of its source that the fork knows.
  ///
  /// The agent does not know the cut of such a fork. The tool calls of the transcript of the fork
  /// name the tool calls that it keeps, so the part ends before the call that forked
  /// (``SessionMergeEngine/forkEnd(keepingToolCalls:)``). The Router sends the event of a tool
  /// call before it runs the tool body, but the projector of the source records that event in its
  /// own step. So the launcher first waits until the history holds the call that forked
  /// (``sourceHistoryHoldingCallingRound(of:keeping:)``). When the source left out no tool call,
  /// the fork did not fork at a call, and the agent does not know its cut: the fork then copies
  /// no entry, and never shows the whole source. The source history is the one in the table, else
  /// the one in the file of the source: a fork records in the folder of its source.
  ///
  /// - Parameters:
  ///   - fork: The fork, built.
  ///   - source: The source of the fork.
  /// - Returns: The copied history, empty when the agent does not know the cut.
  /// - Throws: ``ToolForkHistoryError/callingToolCallNotRecorded(source:timeLimit:)`` when the
  ///   history of the source does not record the call that forked in the time limit; the cancel
  ///   of the wait.
  private func toolForkHistory(of fork: any RoutedSession, source: ULID) async throws
    -> SessionMergeEngine
  {
    let sourceId = SessionId(rawValue: source.description)
    let kept = await fork.transcript.toolCallIds
    let sourceHistory =
      try await sourceHistoryHoldingCallingRound(of: sourceId, keeping: kept)
      ?? sessions[sourceId]?.history
      ?? retainedHistory(
        kept: nil, directory: fork.recordingDirectory.deletingLastPathComponent(),
        sessionId: sourceId)
    guard let end = sourceHistory.forkEnd(keepingToolCalls: kept) else {
      return SessionMergeEngine()
    }
    return sourceHistory.copiedHistory(endingAt: end)
  }

  /// The retained history of a source in the table, after it holds a tool call of the round that
  /// forked (D205).
  ///
  /// The key of the round is the ids of its tool calls. The ACP id of a tool call is the id of
  /// the call in the transcript (``ACPEventTranslator``). The transcript of the source settled at
  /// the calling tool call before the fork, so the round is each tool call of that transcript
  /// that the transcript of the fork does not keep. The cut of the Router
  /// (`SessionLaunchForkRequest.forkedAtHistoryOrdinal`) is no key: it counts the entries of the
  /// recorded Router history, and the retained history has other entries.
  ///
  /// The Router announces each call of a round before the first tool body of the round runs, so
  /// a wait for one call of the round never waits for a call that runs after the fork. The wait
  /// looks at the table again after each sleep, and a sleep suspends this actor, so the record of
  /// the projector runs while the launcher waits.
  ///
  /// - Parameters:
  ///   - sourceId: The source of the fork.
  ///   - kept: The ids of the tool calls of the transcript of the fork.
  /// - Returns: The history, or `nil` when the table does not hold the source or the fork leaves
  ///   out no tool call of the source: then no record is due.
  /// - Throws: ``ToolForkHistoryError/callingToolCallNotRecorded(source:timeLimit:)`` when the
  ///   history does not hold a call of the round in ``forkCallRecordTimeLimit``, also when the
  ///   source left the table meanwhile; the cancel of the wait.
  private func sourceHistoryHoldingCallingRound(of sourceId: SessionId, keeping kept: Set<String>)
    async throws -> SessionMergeEngine?
  {
    guard let source = sessions[sourceId]?.session else {
      return nil
    }
    let round = await source.transcript.toolCallIds.subtracting(kept)
    guard !round.isEmpty else {
      return nil
    }
    let timeLimit = forkCallRecordTimeLimit
    let deadline = ContinuousClock.now.advanced(by: timeLimit)
    while true {
      if let history = sessions[sourceId]?.history, history.holdsToolCall(among: round) {
        return history
      }
      guard ContinuousClock.now < deadline else {
        throw ToolForkHistoryError.callingToolCallNotRecorded(
          source: sourceId, timeLimit: timeLimit)
      }
      try await Task.sleep(for: Self.forkCallRecordLookInterval)
    }
  }
}
