import FoundationModelsACP

/// The methods that the client can use on one session.
///
/// Every session is the same kind of thing, and what it permits is data. A root
/// session permits all methods (``all``). A child session permits only what it
/// advertises in `subagent_update.capabilities`
/// (``init(advertised:)``). A handler asks ``permits(_:)`` and has no
/// "is this a child" branch.
///
/// The default is "not permitted". A method that a set does not name is
/// refused, also a method that a later version of the protocol adds.
struct SessionCapabilitySet: Equatable, Sendable {
  /// The permitted method names, or `nil` when the set permits every method.
  private let permitted: Set<String>?

  /// The set of a root session. It permits every method, also an unknown one.
  static let all = SessionCapabilitySet(permitted: nil)

  /// Makes a set from the capabilities that a child advertises.
  ///
  /// A capability that this initializer does not map is not permitted, so a
  /// capability that the wire type adds later grants nothing until it is mapped here.
  ///
  /// - Parameter advertised: The capabilities of the `subagent_update`.
  init(advertised: SubagentSessionCapabilities) {
    var methods: Set<String> = []
    if advertised.cancel != nil {
      methods.insert(ACPMethod.sessionCancel)
    }
    self.init(permitted: methods)
  }

  /// Makes a set.
  ///
  /// - Parameter permitted: The permitted method names, or `nil` for every method.
  private init(permitted: Set<String>?) {
    self.permitted = permitted
  }

  /// Whether the client can use `method` on the session.
  ///
  /// - Parameter method: The wire name of the method, for example `session/prompt`.
  /// - Returns: `true` when the set permits the method.
  func permits(_ method: String) -> Bool {
    guard let permitted else {
      return true
    }
    return permitted.contains(method)
  }
}

extension RoutedACPAgent {
  /// Refuses a method that the capabilities of the session do not permit.
  ///
  /// - Parameters:
  ///   - method: The wire name of the method.
  ///   - sessionId: The session that the request names.
  /// - Throws: ``RequestError/methodNotPermitted(_:on:)`` when the session does not permit the method.
  ///   A `sessionId` that the table does not hold is not refused here.
  ///   The handler refuses it as an unknown session.
  func requirePermitted(_ method: String, on sessionId: SessionId) throws {
    guard let entry = sessions[sessionId] else {
      return
    }
    guard entry.capabilities.permits(method) else {
      throw RequestError.methodNotPermitted(method, on: sessionId)
    }
  }
}
