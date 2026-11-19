import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

/// The point of the history of a source session where a fork cuts it (D205), as the agent reads
/// it from a `session/fork` request.
enum SessionForkPoint: Equatable, Sendable {
  /// The end of the last completed turn of the source. A turn that runs is not copied. A request
  /// with no cut in `_meta.sah.forkCut` forks here.
  case lastCompletedTurn

  /// The end of the turn with this 0-based index (``ForkSourceHistory``): the index counts the
  /// delivered turns in the order of delivery. The fork keeps the turn. A cut after a message of
  /// the turn forks here.
  case afterTurn(Int)

  /// The start of the turn with this 0-based index. The fork does not keep the turn. A cut before
  /// a message of the turn forks here.
  case beforeTurn(Int)

  /// The index of the first turn of a history.
  static let firstTurn = 0

  /// The cut that the session directory takes for this point (`SessionForkCut`).
  var directoryCut: SessionForkCut {
    switch self {
    case .lastCompletedTurn:
      return .lastCompletedTurn
    case .afterTurn(let turn):
      return .afterTurn(turn)
    case .beforeTurn(let turn):
      return .beforeTurn(turn)
    }
  }
}

/// The side of a message where a fork cut is, for each side that the agent knows
/// (``SAH/ForkCut/Side``).
enum ForkCutSide: CaseIterable, Sendable {
  /// The fork does not keep the message. A client cuts before a user message.
  case before

  /// The fork keeps the message. A client cuts after an agent message.
  case after

  /// The wire value of the side.
  var wireValue: SAH.ForkCut.Side {
    switch self {
    case .before:
      return .before
    case .after:
      return .after
    }
  }

  /// Makes the side of a wire value.
  ///
  /// - Parameter side: The side that the request sent.
  /// - Returns: The side, or `nil` for a side that the agent does not know.
  init?(_ side: SAH.ForkCut.Side) {
    guard let known = Self.allCases.first(where: { $0.wireValue == side }) else {
      return nil
    }
    self = known
  }
}

extension RoutedACPAgent {
  /// Forks one session (ACP `session/fork`, unstable; D205).
  ///
  /// The handler runs the checks of each session method in their order: the order rule, the
  /// session in the table, and the capabilities of the session. Then it reads the cut in
  /// `_meta.sah.forkCut` and maps it to a turn of the source history
  /// (``forkPoint(of:in:sessionId:)``).
  ///
  /// The session directory of the Router makes the fork (`RouterSessionDirectory.fork(_:)`), with
  /// the source, the cut, no first prompt, and the connection of the request as the client that
  /// asked for it. The fork has the agent, the model profile and the history of the source up to
  /// the cut. The directory asks the launcher of the agent to build the fork
  /// (``launchFork(_:for:)``), and the agent keeps the surface of the request for that build
  /// (``whileForkRequestWaits(_:_:)``): the MCP servers and the additional directories of the
  /// request only. As ACP states, an omitted or empty list gives none: the fork does not get the
  /// MCP servers or the directories of the source. So the agent holds the fork as its own session from its
  /// start, and then it opens the fork for the connection (``openFork(_:activation:)``).
  /// The fork works in the folder of its source, so the `cwd` of the request must be that folder.
  ///
  /// The agent asks for no permission before a tool runs, so a fork needs no permission grant:
  /// each tool that runs in the source runs in the fork too.
  ///
  /// - Parameter params: The request naming the source session and the cut.
  /// - Returns: The id, the command list and the configuration options of the fork.
  /// - Throws: The order rule's invalid-request error, `RequestError.unknownSession` for an id no
  ///   session of the table holds, the refusal of a method that the session does not permit, the
  ///   invalid-params refusal of a cut, of a `cwd` that is not the folder of the source and of a
  ///   directory that does not exist, the refusal of the session directory
  ///   (``RequestError/forkRefusal(_:point:in:id:)``), the error of the project file save (before
  ///   the fork is made), an internal error when the agent cannot open the fork (the fork is
  ///   closed first), or whatever the build of the fork throws.
  public func forkSession(_ params: ForkSessionRequest) async throws -> ForkSessionResponse {
    try await forkSession(params, from: .direct)
  }

  /// Forks one session for one connection: the work of ``forkSession(_:)``. The connection owns
  /// the fork, and the updates of the fork go out on it.
  ///
  /// - Parameters:
  ///   - params: The request naming the source session and the cut.
  ///   - caller: The connection of the request.
  /// - Returns: The response of the fork.
  /// - Throws: The errors that ``forkSession(_:)`` names.
  func forkSession(_ params: ForkSessionRequest, from caller: ConnectionId) async throws
    -> ForkSessionResponse
  {
    try requireInitialized(before: ACPMethod.sessionFork, from: caller)
    guard let entry = sessions[params.sessionId],
      let sourceId = ULID(ulidString: params.sessionId.rawValue)
    else {
      throw RequestError.unknownSession(id: params.sessionId)
    }
    try requirePermitted(ACPMethod.sessionFork, on: params.sessionId)
    try Self.requireSourceFolder(params.cwd, of: entry, sessionId: params.sessionId)
    let placement = SessionPlacement(
      workingDirectory: entry.workingDirectory,
      additionalRoots: try SessionSetup.additionalRoots(
        fromPaths: (params.additionalDirectories ?? []).map(\.rawValue)),
      userPresence: userPresence(of: caller),
      clientMCPServers: params.mcpServers ?? [])
    try SessionSetup.requireExistingDirectories(
      workingDirectory: placement.workingDirectory, additionalRoots: placement.additionalRoots)

    let source = await forkSourceHistory(
      of: (sessions[params.sessionId] ?? entry).history, forkSource: entry.session.parentId,
      sessionId: params.sessionId)
    let point = try Self.forkPoint(of: params.meta, in: source, sessionId: params.sessionId)
    guard let end = source.end(of: point) else {
      throw RequestError.forkCutOutOfRange(point, in: source, id: params.sessionId)
    }
    // The project file goes before the fork: a failed save then makes no fork. The fork works in
    // the folder of its source, so a later refusal of the fork adds no new project.
    try registerProject(of: placement)
    let directory = sessionDirectory
    let forkRequest = SessionForkRequest(
      sourceID: sourceId, cut: point.directoryCut, firstPrompt: nil,
      requestedByClient: caller.rawValue, forker: .user(clientID: caller.rawValue))
    let fork: (result: SessionSummary, activation: SessionActivation?)
    do {
      fork = try await whileForkRequestWaits(
        RequestedFork(
          placement: placement, copiedHistory: source.copiedHistory(endingAt: end), caller: caller)
      ) { try await directory.fork(forkRequest) }
    } catch let refusal as SessionDirectoryError {
      throw RequestError.forkRefusal(refusal, point: point, in: source, id: params.sessionId)
    }
    return try await openFork(fork.result, activation: fork.activation)
  }

  /// Opens a fork that the launcher built for a `session/fork` request (``launchFork(_:for:)``) for
  /// the connection of the request. The table holds the fork already, with the copied history,
  /// and the connection owns it.
  ///
  /// The record of the fork holds the additional directories of the request from its build
  /// (``launchFork(_:for:)``), and ``forkSession(_:from:)`` recorded the folder of the fork in the
  /// project store before the fork was made (``registerProject(of:)``). The retained history
  /// keeps the commands and the options of the response, and the name of the fork goes out after
  /// the response. A later `session/resume` of the fork takes the live fork, and a resume in a
  /// new process replays the copied turns from the history file of the fork.
  ///
  /// The session directory made the fork before this call, so each failure here closes the fork
  /// first (``discardUnopenedFork(_:)``): the client gets the error, and no live fork stays.
  ///
  /// - Parameters:
  ///   - summary: The summary of the fork.
  ///   - activation: The activation of the fork that the launcher mounted, or `nil` when the
  ///     launcher mounted no fork for the request.
  /// - Returns: The response of the fork.
  /// - Throws: An internal error when the launcher mounted no fork for the request, or the table
  ///   holds no fork with the id of the summary. The fork is closed before the throw.
  private func openFork(_ summary: SessionSummary, activation: SessionActivation?) async throws
    -> ForkSessionResponse
  {
    let forkId = SessionId(rawValue: summary.id.description)
    guard let activation, let fork = sessions[forkId]?.session else {
      await discardUnopenedFork(summary.id)
      throw RequestError.unopenedFork(forkId)
    }
    let response = ForkSessionResponse(
      sessionId: forkId, availableCommands: activation.availableCommands,
      configOptions: activation.configOptions)
    // The history records the commands and the options of the response, as for `session/new`.
    sessions[forkId]?.retainedHistory.seed(
      from: NewSessionResponse(
        sessionId: forkId, availableCommands: response.availableCommands,
        configOptions: response.configOptions))
    announceName(of: fork, sessionId: forkId)
    await recordUse(of: forkId)
    ACPAgentTelemetry.logger(.session).info(
      "A session forked.", metadata: ACPAgentTelemetry.sessionMetadata(forkId))
    return response
  }

  /// Closes a fork that the session directory made for a `session/fork` request when the agent
  /// cannot open it, so no live fork stays with no response.
  ///
  /// A fork in the session table closes as a `session/delete` closes a session: the teardown
  /// closes the Router session, stops its projector and releases its surface
  /// (``tearDownSession(_:entry:isShutdown:)``), and its entry and its snapshot key go. The
  /// directory then holds no live session with the id. A fork that the table does not hold (a
  /// launcher that built the fork with no surface of the agent) closes through the directory.
  /// The record of the fork stays on disk, as for each closed session.
  ///
  /// - Parameter forkId: The id of the fork.
  private func discardUnopenedFork(_ forkId: ULID) async {
    let sessionId = SessionId(rawValue: forkId.description)
    if let entry = sessions[sessionId] {
      await tearDownSession(sessionId, entry: entry)
      sessions.removeValue(forKey: sessionId)
      recordActiveSessions()
    }
    SnapshotSessionKeys.shared.forget(sessionId)
    await sessionDirectory.session(id: forkId)?.close()
  }

  /// Checks that the `cwd` of a fork request is the folder of the source: a fork works in the
  /// folder of its source.
  ///
  /// - Parameters:
  ///   - cwd: The `cwd` of the request.
  ///   - source: The entry of the source.
  ///   - sessionId: The source, for the refusal.
  /// - Throws: The refusal of a relative path, or
  ///   ``RequestError/mismatchedWorkingDirectory(id:requested:recorded:)``.
  private static func requireSourceFolder(
    _ cwd: AbsolutePath, of source: ActiveSession, sessionId: SessionId
  ) throws {
    let requested = try SessionSetup.validatedWorkingDirectory(path: cwd.rawValue, field: .cwd)
      .standardizedFileURL.path
    let folder = source.workingDirectory.standardizedFileURL.path
    guard requested == folder else {
      throw RequestError.mismatchedWorkingDirectory(
        id: sessionId, requested: requested, recorded: folder)
    }
  }

  /// The history of the source of a fork as the agent reads it for the fork: with the ids that
  /// an incoming message of the history names as its recipient (``forkRecipients(of:sessionId:)``).
  /// Each count of the turns of the source reads these ids, so each count uses the full fork
  /// chain of the source.
  ///
  /// - Parameters:
  ///   - history: The retained history of the source.
  ///   - forkSource: The session that the source is a fork of, or `nil`.
  ///   - sessionId: The source.
  /// - Returns: The source history.
  func forkSourceHistory(
    of history: SessionMergeEngine, forkSource: ULID?, sessionId: SessionId
  ) async -> ForkSourceHistory {
    ForkSourceHistory.snapshot(
      of: history, recipients: await forkRecipients(of: forkSource, sessionId: sessionId))
  }

  /// The ids that an incoming message of the history of a session names as its recipient: the
  /// session, and each session that it is a fork of. A fork copies the history of its source, so
  /// an incoming message of the copy names the source.
  ///
  /// - Parameters:
  ///   - forkSource: The session that the session is a fork of, or `nil`.
  ///   - sessionId: The session.
  /// - Returns: The ids.
  func forkRecipients(of forkSource: ULID?, sessionId: SessionId) async -> Set<SessionId> {
    var recipients: Set<SessionId> = [sessionId]
    var next = forkSource
    while let source = next, recipients.insert(SessionId(rawValue: source.description)).inserted {
      next = await self.forkSource(of: source)
    }
    return recipients
  }

  /// The session that a session is a fork of, from the session directory.
  ///
  /// - Parameter id: The session.
  /// - Returns: The source, or `nil` when the session is no fork or the directory does not know
  ///   it. A read that fails goes to the log.
  func forkSource(of id: ULID) async -> ULID? {
    do {
      guard let summary = try await sessionDirectory.summary(of: id), summary.kind == .fork else {
        return nil
      }
      return summary.parentID
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The summary of a session did not read. The agent does not know if it is a fork.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
      return nil
    }
  }

  /// Reads the cut of a `session/fork` request and maps it to a point of the source history.
  ///
  /// - No `_meta.sah.forkCut` member, or JSON `null`: ``SessionForkPoint/lastCompletedTurn``.
  /// - A cut: the turn that holds the message of the cut in the retained history
  ///   (``ForkSourceHistory/turn(holding:)``). The turn count reads the records of the mail
  ///   delivery (``MailDeliveryRecord``), with the recipients of the source, thus an incoming
  ///   message to a session of the fork chain of the source is a turn, and an action command is
  ///   none. The session directory cuts only at
  ///   the edge of a turn, so a cut in a turn rounds to an edge of that turn:
  ///   ``ForkCutSide/after`` gives ``SessionForkPoint/afterTurn(_:)``, and the fork keeps the
  ///   message. ``ForkCutSide/before`` gives ``SessionForkPoint/beforeTurn(_:)``, and the fork
  ///   does not keep the message. Thus a cut after an agent message keeps the whole turn of the
  ///   message, and a cut before a user message keeps the turns before it.
  /// - A cut on a message before the first turn: ``SessionForkPoint/beforeTurn(_:)`` of the first
  ///   turn (``SessionForkPoint/firstTurn``).
  ///
  /// The history keeps the ACP ids that the client saw live, and the file of the history keeps
  /// them for a new process (``SessionHistoryFile``). Thus the map is the same for a session
  /// that was resumed after a restart.
  ///
  /// - Parameters:
  ///   - meta: The `_meta` of the request, or `nil`.
  ///   - source: The retained history of the source session, with its recipients
  ///     (``forkSourceHistory(of:forkSource:sessionId:)``).
  ///   - sessionId: The source session, for the refusal.
  /// - Returns: The fork point.
  /// - Throws: An invalid-params refusal for a `_meta.sah.forkCut` member that is not a cut, for
  ///   a side that the agent does not know, and for a message id that no message of the history
  ///   has.
  static func forkPoint(
    of meta: FoundationModelsACP.JSONValue?, in source: ForkSourceHistory, sessionId: SessionId
  ) throws -> SessionForkPoint {
    guard let cut = SAH.ForkCut.extract(from: meta) else {
      guard !hasForkCutMember(meta) else {
        throw RequestError.malformedForkCut(id: sessionId)
      }
      return .lastCompletedTurn
    }
    guard let side = ForkCutSide(cut.side) else {
      throw RequestError.unknownForkCutSide(cut.side, id: sessionId)
    }
    guard let position = source.history.messagePosition(of: cut.messageId) else {
      throw RequestError.unknownForkCutMessage(cut.messageId, id: sessionId)
    }
    guard let turn = source.turn(holding: position) else {
      return .beforeTurn(SessionForkPoint.firstTurn)
    }
    switch side {
    case .before:
      return .beforeTurn(turn)
    case .after:
      return .afterTurn(turn)
    }
  }

  /// Whether `_meta.sah.forkCut` has a value that is not JSON `null`. A request with such a member
  /// that does not decode as a cut is refused, so a cut with an error never forks the whole
  /// session.
  ///
  /// - Parameter meta: The `_meta` of the request, or `nil`.
  /// - Returns: `true` when the member is there with a value.
  private static func hasForkCutMember(_ meta: FoundationModelsACP.JSONValue?) -> Bool {
    guard case .object(let members) = meta, case .object(let sah) = members[SAH.metaKey],
      let cut = sah[SAH.ForkCut.metaKey]
    else {
      return false
    }
    return cut != .null
  }
}

extension RequestError {
  /// The failure of a `session/fork` request whose fork the agent cannot open: the launcher
  /// mounted no fork for the request, or the table holds no fork with the id. An internal error,
  /// with the fork id in the detail of `data`.
  ///
  /// - Parameter forkId: The fork that the session directory made.
  /// - Returns: The typed internal error.
  static func unopenedFork(_ forkId: SessionId) -> RequestError {
    internalError(detail: "the fork \(forkId.rawValue) closed before the agent opened it")
  }

  /// The refusal of a `_meta.sah.forkCut` member that does not decode as a cut. Invalid params,
  /// with the session id and the reason in `data`.
  ///
  /// - Parameter id: The source session of the fork.
  /// - Returns: The typed invalid-params error.
  static func malformedForkCut(id: SessionId) -> RequestError {
    invalidParamsRefusal(
      id: id, reason: "_meta.sah.forkCut is not a cut with a messageId and a side",
      method: ACPMethod.sessionFork)
  }

  /// The refusal of a fork cut with a side that the agent does not know. Invalid params, with the
  /// session id and the reason in `data`.
  ///
  /// - Parameters:
  ///   - side: The side that the request sent.
  ///   - id: The source session of the fork.
  /// - Returns: The typed invalid-params error.
  static func unknownForkCutSide(_ side: SAH.ForkCut.Side, id: SessionId) -> RequestError {
    invalidParamsRefusal(
      id: id, reason: "the fork cut side \(side.rawValue) is not before or after",
      method: ACPMethod.sessionFork)
  }

  /// The refusal of a fork cut on a message id that no message of the source history has.
  /// Invalid params, with the session id and the reason in `data`. No fork is made.
  ///
  /// - Parameters:
  ///   - messageId: The message id that the request sent.
  ///   - id: The source session of the fork.
  /// - Returns: The typed invalid-params error.
  static func unknownForkCutMessage(_ messageId: MessageId, id: SessionId) -> RequestError {
    invalidParamsRefusal(
      id: id,
      reason: "no message of the session \(id.rawValue) has the id \(messageId.rawValue)",
      method: ACPMethod.sessionFork)
  }

  /// The text of the refusal of a fork cut in the turns that a compaction folded. The summary of
  /// the compaction also tells of the turns after such a cut, so the session directory refuses it.
  static let compactedForkCutText =
    "This part of the session was compacted. Fork from a later turn."

  /// The text of the refusal of a fork cut on a turn that the session does not have.
  static let missingForkTurnText =
    "The session has no such turn. Fork from a turn that the session shows."

  /// The text of the refusal of a fork cut after the turn that runs now.
  static let runningForkTurnText =
    "This turn still runs. Fork from a completed turn, or wait until this turn ends."

  /// The text of the refusal of a fork of a session that records nothing to disk.
  static let unforkableSessionText =
    "This session records nothing to disk, so it cannot be forked."

  /// The text of the refusal of a fork of an archived session.
  static let archivedForkSourceText =
    "This session is archived. Unarchive it before you fork it."

  /// The text of the refusal of a fork of a session that the session directory does not know.
  static let unknownForkSourceText = "The session directory does not know this session."

  /// The refusal of a fork cut that the session directory found out of range
  /// (`SessionDirectoryError.forkCutOutOfRange`). Invalid params, with a text for the person:
  ///
  /// - ``compactedForkCutText`` when the cut is in the turns that a compaction folded. The agent
  ///   sees the compaction entries in its own history (``ForkSourceHistory/isFolded(_:)``).
  /// - ``runningForkTurnText`` when the cut is after the turn that runs now.
  /// - ``missingForkTurnText`` for each other cut: a turn that the session does not have.
  ///
  /// - Parameters:
  ///   - point: The point of the cut.
  ///   - source: The history of the source at the time of the fork.
  ///   - id: The source session of the fork.
  /// - Returns: The typed invalid-params error.
  static func forkCutOutOfRange(
    _ point: SessionForkPoint, in source: ForkSourceHistory, id: SessionId
  ) -> RequestError {
    if source.isFolded(point) {
      return forkRefusal(text: compactedForkCutText, id: id)
    }
    if source.isAfterRunningTurn(point) {
      return forkRefusal(text: runningForkTurnText, id: id)
    }
    return forkRefusal(text: missingForkTurnText, id: id)
  }

  /// The refusal of a fork that the session directory refused.
  ///
  /// - A cut out of range: ``forkCutOutOfRange(_:in:id:)``.
  /// - A source that records nothing to disk: invalid params with ``unforkableSessionText``.
  /// - An archived source: invalid params with ``archivedForkSourceText``.
  /// - A source that the directory does not know: invalid params with ``unknownForkSourceText``.
  /// - Each other error: an internal error with the error in `data`.
  ///
  /// - Parameters:
  ///   - error: The error of the session directory.
  ///   - point: The point of the cut.
  ///   - source: The history of the source at the time of the fork.
  ///   - id: The source session of the fork.
  /// - Returns: The typed error.
  static func forkRefusal(
    _ error: SessionDirectoryError, point: SessionForkPoint, in source: ForkSourceHistory,
    id: SessionId
  ) -> RequestError {
    switch error {
    case .forkCutOutOfRange:
      return forkCutOutOfRange(point, in: source, id: id)
    case .forkUnsupported:
      return forkRefusal(text: unforkableSessionText, id: id)
    case .archivedSession:
      return forkRefusal(text: archivedForkSourceText, id: id)
    case .unknownSession:
      return forkRefusal(text: unknownForkSourceText, id: id)
    default:
      return internalError(detail: "the session directory did not fork the session: \(error)")
    }
  }

  /// One refusal of a fork: invalid params, with the text for the person as the message and as
  /// the reason in `data`, beside the session id and the method.
  ///
  /// - Parameters:
  ///   - text: The text for the person.
  ///   - id: The source session of the fork.
  /// - Returns: The typed invalid-params error.
  private static func forkRefusal(text: String, id: SessionId) -> RequestError {
    RequestError(
      code: .invalidParams,
      message: text,
      data: .object([
        "sessionId": .string(id.rawValue),
        "reason": .string(text),
        "method": .string(ACPMethod.sessionFork),
      ]))
  }
}
