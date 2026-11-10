import Foundation
import FoundationModelsACP
import FoundationModelsAgents

extension ConfigOptions {
  /// The wire id of the agent select option.
  static let agentOptionId = SessionConfigId(rawValue: "agent")

  /// The value id of the default agent in the agent select option. With no
  /// default agent, this value is the builtin floor.
  static let defaultAgentValue = AgentCatalog.defaultAgentID

  /// The human-readable label of the agent option.
  private static let agentOptionName = "Agent"

  /// The description of the agent option.
  private static let agentOptionDescription =
    "Selects the agent of this session. Only session/new sets it."

  /// The description of the `default` value when no layer gives a default
  /// agent.
  private static let builtinAgentDescription = "The built-in instructions of the agent."

  /// The member of `_meta.sah` of `session/new` that holds the config
  /// option values of the request.
  ///
  /// The `NewSessionRequest` of FoundationModelsACP has no `configOptions`
  /// field, thus a client gives the values in `_meta`:
  /// `_meta.sah.configOptions` is an object from the option id to the value
  /// id, for example `{"agent": "coder"}`. Only `agent` is known.
  static let sessionNewConfigOptionsKey = "configOptions"

  /// The agent select of one session (ACPA-1).
  ///
  /// The values are `default` first (the default agent, else the builtin
  /// floor), then each agent of the catalog that a user can start
  /// (`isUserInvocable`), sorted by id. The default agent is never
  /// user-invocable, thus it occurs one time. When the session agent is the
  /// `AGENT.md` of the working directory and no value has its id, its value
  /// comes last. The current value is the agent of the session.
  struct AgentOption: Equatable, Sendable {
    /// The value id of the agent of the session.
    let current: String

    /// The values of the select, in announcement order.
    let values: [SessionConfigSelectOption]

    /// Makes the agent select of a session.
    ///
    /// - Parameters:
    ///   - catalog: The agent catalog of the session.
    ///   - agent: The resolved agent of the session.
    init(catalog: AgentCatalog, agent: ResolvedSessionAgent) {
      let defaultValue = SessionConfigSelectOption(
        name: ConfigOptions.defaultAgentValue,
        value: SessionConfigValueId(rawValue: ConfigOptions.defaultAgentValue),
        description: catalog.defaultAgent?.description ?? ConfigOptions.builtinAgentDescription)
      let listed = [defaultValue] + catalog.userInvocable.map { Self.value(of: $0) }
      let sessionValue = agent.definition.map { definition in
        Self.value(of: definition, id: agent.choice.id)
      }
      let isListed = listed.contains { $0.value.rawValue == agent.choice.id }
      current = agent.choice.id
      values = listed + (isListed ? [] : sessionValue.map { [$0] } ?? [])
    }

    /// The value of one agent.
    ///
    /// - Parameters:
    ///   - definition: The agent.
    ///   - id: The value id, or `nil` for the id of the definition.
    /// - Returns: The value.
    private static func value(of definition: AgentDefinition, id: String? = nil)
      -> SessionConfigSelectOption
    {
      let id = id ?? definition.id
      return SessionConfigSelectOption(
        name: id, value: SessionConfigValueId(rawValue: id),
        description: definition.description)
    }

    /// The wire option.
    var option: SessionConfigOption {
      SessionConfigOption(
        configId: ConfigOptions.agentOptionId,
        name: ConfigOptions.agentOptionName,
        description: ConfigOptions.agentOptionDescription,
        type: .select(
          SessionConfigSelect(
            currentValue: SessionConfigValueId(rawValue: current),
            options: ConfigOptions.encodedSelectOptions(values))))
    }
  }

  /// The value of the `agent` option of a `session/new` request: the
  /// member `agent` of `_meta.sah.configOptions`
  /// (``sessionNewConfigOptionsKey``).
  ///
  /// - Parameter meta: The `_meta` of the request.
  /// - Returns: The value id, or `nil` when the request gives no agent.
  /// - Throws: `RequestError.invalidParams` when `configOptions` is not an
  ///   object, `unknownConfigOption` for a member that is not `agent`, and
  ///   `invalidConfigOptionValue` for an `agent` value that is not a string.
  static func requestedAgent(in meta: JSONValue?) throws -> String? {
    guard case .object(let members)? = meta, case .object(let sah)? = members[SAH.metaKey],
      let configOptions = sah[sessionNewConfigOptionsKey]
    else {
      return nil
    }
    guard case .object(let values) = configOptions else {
      throw RequestError.invalidParams
    }
    if let unknown = values.keys.sorted().first(where: { $0 != agentOptionId.rawValue }) {
      throw RequestError.unknownConfigOption(id: SessionConfigId(rawValue: unknown))
    }
    guard let value = values[agentOptionId.rawValue] else {
      return nil
    }
    guard case .string(let id) = value else {
      throw RequestError.invalidConfigOptionValue(id: agentOptionId)
    }
    return id
  }
}

extension RequestError {
  /// The reason of the refusal of a set of the agent option.
  private static let agentFixedReason = "the agent of a session is set only at session/new"

  /// The refusal of a `session/set_config_option` for the agent option:
  /// invalid params with the option id and the reason in `data`. The agent
  /// of a session is set only at `session/new`.
  ///
  /// - Parameter id: The id of the agent option.
  /// - Returns: The typed invalid-params error.
  static func agentFixedAtSessionStart(id: SessionConfigId) -> RequestError {
    RequestError(
      code: .invalidParams,
      message: RequestError.invalidParams.message,
      data: .object([
        "configId": .string(id.rawValue),
        "reason": .string(agentFixedReason),
      ]))
  }
}
