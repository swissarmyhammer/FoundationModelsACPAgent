import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The session config options surface.
///
/// The first option is a `select` of category `model` over
/// the resident profile's `standard` and `flash` slots. Both slots are
/// already resident, so a switch loads nothing and blocks on nothing.
/// The value ids are the stable slot names; the labels show each slot's
/// `chosen.stringValue`, because `ModelRef`'s `repo` and `revision` are
/// internal and `stringValue` is the only public read.
///
/// The second option is the `agent` select (ACPA-1, ``AgentOption``). A
/// session that has no agent catalog does not show it. The agent is set
/// only at `session/new`.
///
/// One construction serves every announcement: the `session/new`
/// response, the `session/set_config_option` response, and the
/// `config_option_update` push each carry the complete list this type
/// builds — never a delta. `mode`, `thought_level` and a `model_config`
/// context size are intentionally absent: nothing on the Router side
/// peers with them. No groups.
enum ConfigOptions {
  /// The wire id of the one model-slot select option.
  static let modelOptionId = SessionConfigId(rawValue: "model")

  /// The option's human-readable label.
  private static let modelOptionName = "Model"

  /// The option's description. It says the select is over the
  /// profile's slots, so a user does not expect a full candidate list.
  private static let modelOptionDescription =
    "Selects which of the resident profile's model slots answers this session: standard or flash."

  /// The chat slots the option offers, in priority order. Embedding
  /// is not a chat slot, so it is never offered.
  static let selectableSlots: [ModelSlot] = [.standard, .flash]

  /// The default slot. Every option MUST have a default.
  /// It is the standard slot — the same slot `session/new` composes
  /// the session from — so a client that ignores config options gets
  /// a session that operates.
  static let defaultSlot: ModelSlot = .standard

  /// The complete, priority-ordered option list for one session:
  /// the model-slot select, then the agent select when the session has
  /// one.
  ///
  /// - Parameters:
  ///   - profile: The resident profile whose slots are offered.
  ///   - selectedSlot: The slot the session currently generates on.
  ///   - agent: The agent select of the session, or `nil` for none.
  /// - Returns: The complete state every announcement carries.
  static func options(
    profile: LanguageModelProfile, selectedSlot: ModelSlot, agent: AgentOption?
  ) -> [SessionConfigOption] {
    [modelOption(profile: profile, selectedSlot: selectedSlot)]
      + (agent.map { [$0.option] } ?? [])
  }

  /// The model-slot select.
  ///
  /// - Parameters:
  ///   - profile: The resident profile whose slots are offered.
  ///   - selectedSlot: The slot the session currently generates on.
  /// - Returns: The option.
  private static func modelOption(
    profile: LanguageModelProfile, selectedSlot: ModelSlot
  ) -> SessionConfigOption {
    SessionConfigOption(
      configId: modelOptionId,
      name: modelOptionName,
      category: .model,
      description: modelOptionDescription,
      type: .select(
        SessionConfigSelect(
          currentValue: SessionConfigValueId(rawValue: selectedSlot.rawValue),
          options: makeSelectOptionsValue(profile: profile))))
  }

  /// Maps a set request's value id to a selectable slot.
  ///
  /// - Parameter value: The `type: "id"` value of the request.
  /// - Returns: The slot, or `nil` when the id names no chat slot —
  ///   `embedding` included, because it is not offered.
  static func slot(for value: SessionConfigValueId) -> ModelSlot? {
    guard let slot = ModelSlot(rawValue: value.rawValue), selectableSlots.contains(slot)
    else {
      return nil
    }
    return slot
  }

  /// The `model:` value of an agent that asks for the default slot.
  static let inheritModelValue = "inherit"

  /// The start slot of a session for the `model:` key of its session agent
  /// (ACPA-1b): the start value of the `model` option.
  ///
  /// The case of the letters does not matter.
  ///
  /// - Parameter model: The `model:` value of the session agent, or `nil`
  ///   when the agent has no such key.
  /// - Returns: The selectable slot that `model` names. No value and
  ///   `inherit` give ``defaultSlot``. A value that names no selectable slot
  ///   gives ``defaultSlot`` and a warning for the log.
  static func slot(forAgentModel model: String?) -> (slot: ModelSlot, warning: String?) {
    guard let model, model.lowercased() != inheritModelValue else {
      return (defaultSlot, nil)
    }
    guard let slot = slot(for: SessionConfigValueId(rawValue: model.lowercased())) else {
      let valid = ([inheritModelValue] + selectableSlots.map(\.rawValue))
        .map { "`\($0)`" }.joined(separator: ", ")
      return (
        defaultSlot,
        "The model `\(model)` of the session agent is not a slot. The session starts on the "
          + "`\(defaultSlot.rawValue)` slot. Use one of these values: \(valid)."
      )
    }
    return (slot, nil)
  }

  /// The generation handle of a selectable slot.
  ///
  /// - Parameters:
  ///   - slot: The selected slot; only ``selectableSlots`` reach here.
  ///   - profile: The resident profile that owns the handles.
  /// - Returns: The slot's resident handle.
  static func handle(for slot: ModelSlot, of profile: LanguageModelProfile) -> RoutedLLM {
    switch slot {
    case .standard:
      return profile.standard
    case .flash:
      return profile.flash
    case .embedding:
      // ``slot(for:)`` never yields `embedding`; reaching here is
      // programmer error, not a recoverable input.
      preconditionFailure("embedding is not a chat slot and has no generation handle")
    }
  }

  /// The select's raw `options` value: the flat list of the two slot
  /// values (``encodedSelectOptions(_:)``).
  ///
  /// - Parameter profile: The resident profile whose slots are shown.
  /// - Returns: The encoded flat list.
  private static func makeSelectOptionsValue(
    profile: LanguageModelProfile
  ) -> SessionConfigSelectOptions {
    encodedSelectOptions(
      selectableSlots.map { slot in
        SessionConfigSelectOption(
          name: handle(for: slot, of: profile).chosen.stringValue,
          value: SessionConfigValueId(rawValue: slot.rawValue),
          description: "The profile's \(slot.rawValue) slot.")
      })
  }

  /// The raw `options` value of a select: the flat list of `values`,
  /// encoded through the generated `SessionConfigSelectOption` coder so
  /// the wire shape can never drift from the schema.
  ///
  /// `SessionConfigSelectOptions` is the wire package's permanently
  /// deferred union (flat list or groups), represented as raw JSON.
  /// We ship the flat list, without groups.
  ///
  /// - Parameter values: The values of the select, in order.
  /// - Returns: The encoded flat list.
  static func encodedSelectOptions(
    _ values: [SessionConfigSelectOption]
  ) -> SessionConfigSelectOptions {
    do {
      let data = try JSONEncoder().encode(values)
      return try JSONDecoder().decode(SessionConfigSelectOptions.self, from: data)
    } catch {
      // An array of string-field wire values always encodes and
      // always re-decodes as JSON; reaching here is programmer
      // error, not a recoverable input.
      preconditionFailure("the select options failed to encode: \(error)")
    }
  }
}

extension RequestError {
  /// The reason an unmatched set value reports: a
  /// `.other` value, a value of the wrong type, or an id that names
  /// no offered slot.
  private static let invalidConfigValueReason = "the value does not match the option"

  /// The unknown-option refusal: invalid params with the option id in
  /// `data`, the same pattern as the session-id refusals.
  ///
  /// - Parameter id: The unknown option id.
  /// - Returns: The typed invalid-params error.
  static func unknownConfigOption(id: SessionConfigId) -> RequestError {
    RequestError(
      code: .invalidParams,
      message: RequestError.invalidParams.message,
      data: .object(["configId": .string(id.rawValue)]))
  }

  /// The mismatched-value refusal: invalid params with
  /// the option id and the reason in `data`. The state does not
  /// change and no push goes out.
  ///
  /// - Parameter id: The option id the value failed to match.
  /// - Returns: The typed invalid-params error.
  static func invalidConfigOptionValue(id: SessionConfigId) -> RequestError {
    RequestError(
      code: .invalidParams,
      message: RequestError.invalidParams.message,
      data: .object([
        "configId": .string(id.rawValue),
        "reason": .string(invalidConfigValueReason),
      ]))
  }
}

extension RoutedACPAgent {
  /// Applies one config-option set: validates the
  /// session and the option, switches the model slot, and answers the
  /// COMPLETE option state — `configOptions` is required and never a
  /// delta. The response is the announcement, so no push follows a
  /// successful set.
  ///
  /// The unknown-id policy is the one of every session method: an unknown `sessionId` is
  /// invalid params with the id in `data`; a known but closed session
  /// is invalid params with the resume hint. Neither pushes a
  /// `config_option_update`.
  ///
  /// - Parameter params: The request: the session, the option id, and
  ///   the tagged value.
  /// - Returns: The complete option state after the set.
  /// - Throws: The order rule's error, `unknownSession`,
  ///   `closedSession`, `unknownConfigOption`,
  ///   `invalidConfigOptionValue`, or `agentFixedAtSessionStart` for the
  ///   `agent` option, which only `session/new` sets.
  public func setSessionConfigOption(
    _ params: SetSessionConfigOptionRequest
  ) async throws -> SetSessionConfigOptionResponse {
    try await setSessionConfigOption(params, from: .direct)
  }

  /// Applies one config-option set for one connection: the work of
  /// ``setSessionConfigOption(_:)``.
  ///
  /// - Parameters:
  ///   - params: The request: the session, the option id, and the tagged
  ///     value.
  ///   - caller: The connection of the request.
  /// - Returns: The complete option state after the set.
  /// - Throws: The errors that ``setSessionConfigOption(_:)`` names.
  func setSessionConfigOption(
    _ params: SetSessionConfigOptionRequest, from caller: ConnectionId
  ) async throws -> SetSessionConfigOptionResponse {
    try requireInitialized(before: ACPMethod.sessionSetConfigOption, from: caller)
    guard let entry = sessions[params.sessionId] else {
      throw RequestError.unknownSession(id: params.sessionId)
    }
    try requirePermitted(ACPMethod.sessionSetConfigOption, on: params.sessionId)
    if entry.isClosed {
      throw RequestError.closedSession(id: params.sessionId)
    }
    if params.configId == ConfigOptions.agentOptionId, entry.agentOption != nil {
      throw RequestError.agentFixedAtSessionStart(id: params.configId)
    }
    guard params.configId == ConfigOptions.modelOptionId else {
      throw RequestError.unknownConfigOption(id: params.configId)
    }
    guard case .id(let valueId) = params.value,
      let slot = ConfigOptions.slot(for: valueId)
    else {
      throw RequestError.invalidConfigOptionValue(id: params.configId)
    }

    try await applyModelSlot(slot, to: params.sessionId)
    let options = ConfigOptions.options(
      profile: residentProfile, selectedSlot: slot, agent: entry.agentOption)
    recordAnnouncedConfigOptions(options, for: params.sessionId)
    return SetSessionConfigOptionResponse(configOptions: options)
  }

  /// Records the option state the client last saw, so the divergence
  /// check compares against the true announced baseline. `session/new`
  /// and `session/set_config_option` record what they answered. The
  /// retained history of the session keeps the same state, so a resume
  /// replays the options that the client saw.
  ///
  /// - Parameters:
  ///   - options: The complete state that was announced.
  ///   - sessionId: The session it was announced for.
  func recordAnnouncedConfigOptions(
    _ options: [SessionConfigOption], for sessionId: SessionId
  ) {
    sessions[sessionId]?.announcedConfigOptions = options
    recordInHistory(.configOptionUpdate(ConfigOptionUpdate(configOptions: options)), of: sessionId)
  }

  /// Pushes one `config_option_update` when the announced state
  /// diverges from the truth: when resolution lands on a
  /// different model than the option shows, `currentValue` — and the
  /// labels beside it — must be corrected, or the client's selector
  /// claims a model the agent does not run. The push carries the
  /// complete list. When the announced state is already the truth,
  /// nothing goes out.
  ///
  /// The end of each prompt runs this check, so a divergence is corrected
  /// at the first moment the model demonstrably generated.
  ///
  /// - Parameter sessionId: The session to reconcile.
  func reconcileConfigOptions(for sessionId: SessionId) async {
    guard let entry = sessions[sessionId] else { return }
    let truth = ConfigOptions.options(
      profile: residentProfile, selectedSlot: entry.selectedSlot, agent: entry.agentOption)
    guard truth != entry.announcedConfigOptions else { return }
    recordAnnouncedConfigOptions(truth, for: sessionId)
    await connections.path(forSession: sessionId)?.connection.post(
      .configOptionUpdate(ConfigOptionUpdate(configOptions: truth)), in: sessionId)
  }
}
