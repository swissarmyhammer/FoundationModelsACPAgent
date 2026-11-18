import FoundationModelsACP

/// The point of the history of a source session where a fork cuts it (D205), as the agent reads
/// it from a `session/fork` request.
enum SessionForkPoint: Equatable, Sendable {
  /// The end of the last completed turn of the source. A turn that runs is not copied. A request
  /// with no cut in `_meta.sah.forkCut` forks here.
  case lastCompletedTurn

  /// A position in the retained ACP history of the source: the number of transcript entries that
  /// the fork keeps (``SessionMergeEngine/forkPosition(of:on:)``).
  case retainedHistoryPosition(Int)
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
  /// `_meta.sah.forkCut` and maps it to a point of the source history
  /// (``forkPoint(of:in:sessionId:)``).
  ///
  /// This build does not make the fork: the fork through the Router is the next step. So, after
  /// the map, the request gets the internal error ``RequestError/forkNotServed(id:)``, and
  /// `initialize` does not announce `fork` (``forkIsServed``).
  ///
  /// - Parameter params: The request naming the source session and the cut.
  /// - Returns: The response of the fork.
  /// - Throws: The order rule's invalid-request error, `RequestError.unknownSession` for an id no
  ///   session of the table holds, the refusal of a method that the session does not permit, the
  ///   invalid-params refusal of a cut, and then ``RequestError/forkNotServed(id:)``.
  public func forkSession(_ params: ForkSessionRequest) async throws -> ForkSessionResponse {
    try await forkSession(params, from: .direct)
  }

  /// Forks one session for one connection: the work of ``forkSession(_:)``.
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
    guard let entry = sessions[params.sessionId] else {
      throw RequestError.unknownSession(id: params.sessionId)
    }
    try requirePermitted(ACPMethod.sessionFork, on: params.sessionId)
    // The map refuses a cut that is not valid before any fork exists. The fork through the
    // Router takes the point when this build makes the fork.
    _ = try Self.forkPoint(of: params.meta, in: entry.history, sessionId: params.sessionId)
    throw RequestError.forkNotServed(id: params.sessionId)
  }

  /// Reads the cut of a `session/fork` request and maps it to a point of the source history.
  ///
  /// - No `_meta.sah.forkCut` member, or JSON `null`: ``SessionForkPoint/lastCompletedTurn``.
  /// - A cut: the position of the cut in the retained history
  ///   (``SessionMergeEngine/forkPosition(of:on:)``).
  ///
  /// - Parameters:
  ///   - meta: The `_meta` of the request, or `nil`.
  ///   - history: The retained history of the source session.
  ///   - sessionId: The source session, for the refusal.
  /// - Returns: The fork point.
  /// - Throws: An invalid-params refusal for a `_meta.sah.forkCut` member that is not a cut, for
  ///   a side that the agent does not know, and for a message id that no message of the history
  ///   has.
  static func forkPoint(
    of meta: JSONValue?, in history: SessionMergeEngine, sessionId: SessionId
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
    guard let position = history.forkPosition(of: cut.messageId, on: side) else {
      throw RequestError.unknownForkCutMessage(cut.messageId, id: sessionId)
    }
    return .retainedHistoryPosition(position)
  }

  /// Whether `_meta.sah.forkCut` has a value that is not JSON `null`. A request with such a member
  /// that does not decode as a cut is refused, so a cut with an error never forks the whole
  /// session.
  ///
  /// - Parameter meta: The `_meta` of the request, or `nil`.
  /// - Returns: `true` when the member is there with a value.
  private static func hasForkCutMember(_ meta: JSONValue?) -> Bool {
    guard case .object(let members) = meta, case .object(let sah) = members[SAH.metaKey],
      let cut = sah[SAH.ForkCut.metaKey]
    else {
      return false
    }
    return cut != .null
  }
}

extension RequestError {
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

  /// The error of a `session/fork` request with a valid cut while this build makes no fork. An
  /// internal error, with the session id in `data`.
  ///
  /// - Parameter id: The source session of the fork.
  /// - Returns: The typed internal error.
  static func forkNotServed(id: SessionId) -> RequestError {
    RequestError(
      code: .internalError,
      message: RequestError.internalError().message,
      data: .object([
        "sessionId": .string(id.rawValue),
        "reason": .string("this build does not make a fork yet"),
      ]))
  }
}
