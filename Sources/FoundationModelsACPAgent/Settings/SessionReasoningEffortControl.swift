import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The reasoning effort of one session, as the `settings` endpoint gives it
/// (D218): the level of the session and the levels of its model.
struct SettingsGraphReasoningEffort: Sendable, Equatable {
  /// The level of the session, or `nil` for a session on a model with no
  /// levels.
  let level: String?

  /// The values that the level of the session takes: each level of the
  /// model, then "Off" when the model has an Off level. Empty for a model
  /// with no levels.
  let levels: [String]

  /// The default level of the model, or `nil` for a model with no levels.
  let defaultLevel: String?

  /// The reasoning effort of a live Router session: the level of its facts
  /// and the levels of its model.
  ///
  /// - Parameter session: The Router session.
  init(session: any RoutedSession) {
    let levels = session.reasoningEffortLevels
    level = levels.sessionLevel(for: session.facts.reasoningEffort)
    self.levels = levels.sessionLevelNames
    defaultLevel = levels.defaultLevel
  }
}

/// The `SetReasoningEffortInput` input object of
/// `Mutation.setReasoningEffort`.
struct SettingsGraphSetReasoningEffortInput: Codable, Sendable {
  /// The new level: a value of `levels` of `Query.reasoningEffort`.
  let level: String
}

/// The arguments of `Mutation.setReasoningEffort`.
struct SettingsGraphSetReasoningEffortArguments: Codable, Sendable {
  /// The input object of the mutation.
  let input: SettingsGraphSetReasoningEffortInput
}

/// The reasoning effort of the sessions of an agent, for the `settings`
/// tool of each session (D218). The agent binds one control to its
/// `settings` endpoint (``SettingsGraph/bind(reasoningEffort:)``). The
/// tool of a session reads and sets the level of that session only.
protocol SessionReasoningEffortControl: Sendable {
  /// The reasoning effort of a live session.
  ///
  /// - Parameter session: The id of the Router session.
  /// - Returns: The level of the session and the levels of its model.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when no live
  ///   session has the id.
  func reasoningEffort(of session: ULID) async throws -> SettingsGraphReasoningEffort

  /// Sets the reasoning effort of a live session. The level applies from
  /// the next turn of the session, and the client of the session gets the
  /// new config options.
  ///
  /// - Parameters:
  ///   - level: The new level: a value of the levels of the model.
  ///   - session: The id of the Router session.
  /// - Returns: The reasoning effort of the session after the change.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when no live
  ///   session has the id, ``SettingsGraphError/unknownReasoningEffort(level:levels:)``
  ///   when `level` is not a level of the model, and the error of Router
  ///   when it cannot change the level.
  func setReasoningEffort(_ level: String, of session: ULID) async throws
    -> SettingsGraphReasoningEffort
}

/// The control that a `settings` endpoint uses, which the agent binds after
/// the endpoint exists. An endpoint with no agent, for example one that a
/// host makes before the agent exists, has no control.
final class SessionReasoningEffortBinding: Sendable {
  /// The bound control, or `nil` before the bind.
  private let control = Mutex<(any SessionReasoningEffortControl)?>(nil)

  /// Binds the control. A second bind replaces the first one.
  ///
  /// - Parameter newControl: The control of the agent.
  func bind(_ newControl: any SessionReasoningEffortControl) {
    control.withLock { $0 = newControl }
  }

  /// The access of one call of the `settings` endpoint: the control and the
  /// session of the call.
  ///
  /// Only a call of the ``SettingsTool`` of a session reads or changes the
  /// reasoning effort, and only for that session: the session of the tool
  /// call (`ToolContext.current`). A call of the endpoint from a client has
  /// no session, and a client sets the level with
  /// `session/set_config_option`.
  ///
  /// - Parameter sessionDirectory: The session folder of a call of the
  ///   tool, or `nil` for a call of the endpoint.
  /// - Returns: The access, or `nil` when the call has no session or the
  ///   endpoint has no control.
  func access(sessionDirectory: String?) -> SessionReasoningEffortAccess? {
    guard sessionDirectory != nil, let session = ToolContext.current?.sessionID,
      let bound = control.withLock({ $0 })
    else {
      return nil
    }
    return SessionReasoningEffortAccess(control: bound, session: session)
  }
}

/// The reasoning effort control and the session of one call of the
/// ``SettingsTool`` of a session.
struct SessionReasoningEffortAccess: Sendable {
  /// The control of the agent.
  let control: any SessionReasoningEffortControl

  /// The id of the Router session of the tool call.
  let session: ULID
}

/// The control of a ``RoutedACPAgent``. It holds the agent weakly: the agent
/// holds the endpoint, and the endpoint holds the control.
final class AgentReasoningEffortControl: SessionReasoningEffortControl, @unchecked Sendable {
  /// The agent whose sessions the control reads and changes. Weak, to break
  /// the cycle agent → endpoint → control → agent. It is set one time, in
  /// the initializer, and never changes.
  private weak var agent: RoutedACPAgent?

  /// Makes the control of `agent`.
  ///
  /// - Parameter agent: The agent.
  init(agent: RoutedACPAgent) {
    self.agent = agent
  }

  /// The reasoning effort of a live session of the agent.
  ///
  /// - Parameter session: The id of the Router session.
  /// - Returns: The level of the session and the levels of its model.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when the agent
  ///   is gone or no live session has the id.
  func reasoningEffort(of session: ULID) async throws -> SettingsGraphReasoningEffort {
    guard let agent else {
      throw SettingsGraphError.noSessionReasoningEffort
    }
    return try agent.reasoningEffortOfSession(session)
  }

  /// Sets the reasoning effort of a live session of the agent.
  ///
  /// - Parameters:
  ///   - level: The new level.
  ///   - session: The id of the Router session.
  /// - Returns: The reasoning effort of the session after the change.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when the agent
  ///   is gone, and what ``RoutedACPAgent/setReasoningEffortOfSession(_:to:)``
  ///   throws.
  func setReasoningEffort(_ level: String, of session: ULID) async throws
    -> SettingsGraphReasoningEffort
  {
    guard let agent else {
      throw SettingsGraphError.noSessionReasoningEffort
    }
    return try await agent.setReasoningEffortOfSession(session, to: level)
  }
}

extension RoutedACPAgent {
  /// The reasoning effort of a live Router session (D218), for the
  /// `settings` tool of the session.
  ///
  /// - Parameter id: The id of the Router session.
  /// - Returns: The level of the session and the levels of its model.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when no live
  ///   session has the id.
  nonisolated func reasoningEffortOfSession(_ id: ULID) throws -> SettingsGraphReasoningEffort {
    guard let session = sessionDirectory.session(id: id) else {
      throw SettingsGraphError.noSessionReasoningEffort
    }
    return SettingsGraphReasoningEffort(session: session)
  }

  /// Sets the reasoning effort of a live Router session (D218), for the
  /// `settings` tool of the session. The level applies from the next turn.
  /// The client of the session gets one `config_option_update` with the new
  /// level (``reconcileConfigOptions(for:)``), because no client request
  /// carries the change.
  ///
  /// - Parameters:
  ///   - id: The id of the Router session.
  ///   - level: The new level: a value of the levels of the model.
  /// - Returns: The reasoning effort of the session after the change.
  /// - Throws: ``SettingsGraphError/noSessionReasoningEffort`` when no live
  ///   session has the id, ``SettingsGraphError/unknownReasoningEffort(level:levels:)``
  ///   when `level` is not a level of the model, and the error of Router
  ///   when it cannot change the level.
  func setReasoningEffortOfSession(_ id: ULID, to level: String) async throws
    -> SettingsGraphReasoningEffort
  {
    let current = try reasoningEffortOfSession(id)
    guard current.levels.contains(level) else {
      throw SettingsGraphError.unknownReasoningEffort(level: level, levels: current.levels)
    }
    try await sessionDirectory.setReasoningEffort(level, of: id)
    await reconcileConfigOptions(for: SessionId(rawValue: id.description))
    return try reasoningEffortOfSession(id)
  }
}
