import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The session config options surface (plan.md §15).
///
/// Day one ships one real option: a `select` of category `model` over
/// the resident profile's `standard` and `flash` slots. Both slots are
/// already resident, so a switch loads nothing and blocks on nothing.
/// The value ids are the stable slot names; the labels show each slot's
/// `chosen.stringValue`, because `ModelRef`'s `repo` and `revision` are
/// internal and `stringValue` is the only public read.
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

    /// The default slot (plan.md §15: every option MUST have a default).
    /// It is the standard slot — the same slot `session/new` composes
    /// the session from — so a client that ignores config options gets
    /// a session that operates.
    static let defaultSlot: ModelSlot = .standard

    /// The complete, priority-ordered option list for one session:
    /// the one model-slot select (plan.md §15).
    ///
    /// - Parameters:
    ///   - profile: The resident profile whose slots are offered.
    ///   - selectedSlot: The slot the session currently generates on.
    /// - Returns: The complete state every announcement carries.
    static func options(
        profile: LanguageModelProfile, selectedSlot: ModelSlot
    ) -> [SessionConfigOption] {
        [
            SessionConfigOption(
                configId: modelOptionId,
                name: modelOptionName,
                category: .model,
                description: modelOptionDescription,
                type: .select(
                    SessionConfigSelect(
                        currentValue: SessionConfigValueId(rawValue: selectedSlot.rawValue),
                        options: makeSelectOptionsValue(profile: profile))))
        ]
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
    /// values, encoded through the generated `SessionConfigSelectOption`
    /// coder so the wire shape can never drift from the schema.
    ///
    /// `SessionConfigSelectOptions` is the wire package's permanently
    /// deferred union (flat list or groups), represented as raw JSON.
    /// We ship the flat list, without groups (plan.md §15).
    ///
    /// - Parameter profile: The resident profile whose slots are shown.
    /// - Returns: The encoded flat list.
    private static func makeSelectOptionsValue(
        profile: LanguageModelProfile
    ) -> SessionConfigSelectOptions {
        let values = selectableSlots.map { slot in
            SessionConfigSelectOption(
                name: handle(for: slot, of: profile).chosen.stringValue,
                value: SessionConfigValueId(rawValue: slot.rawValue),
                description: "The profile's \(slot.rawValue) slot.")
        }
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
    /// The reason an unmatched set value reports (plan.md §15): a
    /// `.other` value, a value of the wrong type, or an id that names
    /// no offered slot.
    private static let invalidConfigValueReason = "the value does not match the option"

    /// The unknown-option refusal: invalid params with the option id in
    /// `data`, the §10.1 pattern of the session-id refusals.
    ///
    /// - Parameter id: The unknown option id.
    /// - Returns: The typed invalid-params error.
    static func unknownConfigOption(id: SessionConfigId) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object(["configId": .string(id.rawValue)]))
    }

    /// The mismatched-value refusal (plan.md §15): invalid params with
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
    /// Applies one config-option set (plan.md §15): validates the
    /// session and the option, switches the model slot, and answers the
    /// COMPLETE option state — `configOptions` is required and never a
    /// delta. The response is the announcement, so no push follows a
    /// successful set.
    ///
    /// The unknown-id policy is §10.1's: an unknown `sessionId` is
    /// invalid params with the id in `data`; a known but closed session
    /// is invalid params with the resume hint. Neither pushes a
    /// `config_option_update`.
    ///
    /// - Parameter params: The request: the session, the option id, and
    ///   the tagged value.
    /// - Returns: The complete option state after the set.
    /// - Throws: The order rule's error, `unknownSession`,
    ///   `closedSession`, `unknownConfigOption`, or
    ///   `invalidConfigOptionValue`.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try requireInitialized(before: ACPMethod.sessionSetConfigOption)
        guard let entry = sessions[params.sessionId] else {
            throw RequestError.unknownSession(id: params.sessionId)
        }
        if entry.isClosed {
            throw RequestError.closedSession(id: params.sessionId)
        }
        guard params.configId == ConfigOptions.modelOptionId else {
            throw RequestError.unknownConfigOption(id: params.configId)
        }
        guard case .id(let valueId) = params.value,
            let slot = ConfigOptions.slot(for: valueId)
        else {
            throw RequestError.invalidConfigOptionValue(id: params.configId)
        }

        await applyModelSlot(slot, to: params.sessionId, entry: entry)
        let options = ConfigOptions.options(profile: residentProfile, selectedSlot: slot)
        recordAnnouncedConfigOptions(options, for: params.sessionId)
        return SetSessionConfigOptionResponse(configOptions: options)
    }

    /// Switches the session's generation slot: the entry's Router
    /// session is replaced by one vended from the selected slot's
    /// resident handle, so later turns generate on the switched slot.
    /// Both slots are resident, so the switch loads nothing and blocks
    /// on nothing (plan.md §15).
    ///
    /// The replacement records under the session's own transcript
    /// directory, so the lineage stays on disk the way a fork's nesting
    /// states it (plan.md §4.2). The replaced session is closed when it
    /// is idle; a turn still in flight keeps it and finishes there.
    ///
    /// - Parameters:
    ///   - slot: The selected slot. A set to the current slot changes
    ///     nothing.
    ///   - sessionId: The session to switch.
    ///   - entry: The session's table entry, read by the caller.
    private func applyModelSlot(
        _ slot: ModelSlot, to sessionId: SessionId, entry: ActiveSession
    ) async {
        guard slot != entry.selectedSlot else { return }
        // The replacement keeps automatic compaction on: the same
        // `compaction:` section the session was composed from, against the
        // selected slot's resolved context (plan.md §2.4).
        let replacement = ConfigOptions.handle(for: slot, of: residentProfile)
            .makeBudgetedSession(
                instructions: entry.instructions,
                workingDirectory: entry.workingDirectory,
                recordingRoot: entry.transcriptDirectory,
                tools: entry.surface.tools,
                compaction: entry.configuration.compaction)
        sessions[sessionId]?.session = replacement
        sessions[sessionId]?.selectedSlot = slot
        if entry.availability == .idle {
            await entry.session.close()
        }
    }

    /// Records the option state the client last saw, so the divergence
    /// check compares against the true announced baseline. `session/new`
    /// and `session/set_config_option` record what they answered.
    ///
    /// - Parameters:
    ///   - options: The complete state that was announced.
    ///   - sessionId: The session it was announced for.
    func recordAnnouncedConfigOptions(
        _ options: [SessionConfigOption], for sessionId: SessionId
    ) {
        sessions[sessionId]?.announcedConfigOptions = options
    }

    /// Pushes one `config_option_update` when the announced state
    /// diverges from the truth (plan.md §15): when resolution lands on a
    /// different model than the option shows, `currentValue` — and the
    /// labels beside it — must be corrected, or the client's selector
    /// claims a model the agent does not run. The push carries the
    /// complete list. When the announced state is already the truth,
    /// nothing goes out.
    ///
    /// Each turn's end runs this check, so a divergence is corrected at
    /// the first moment the model demonstrably generated.
    ///
    /// - Parameter sessionId: The session to reconcile.
    func reconcileConfigOptions(for sessionId: SessionId) async {
        guard let entry = sessions[sessionId] else { return }
        let truth = ConfigOptions.options(
            profile: residentProfile, selectedSlot: entry.selectedSlot)
        guard truth != entry.announcedConfigOptions else { return }
        recordAnnouncedConfigOptions(truth, for: sessionId)
        guard let connection = boundConnection else { return }
        await connection.post(
            .configOptionUpdate(ConfigOptionUpdate(configOptions: truth)), in: sessionId)
    }
}
