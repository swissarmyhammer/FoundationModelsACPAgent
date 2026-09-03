import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The session config options surface (plan.md §15): one `select` over the
/// resident profile's `standard` and `flash` slots, announced in the
/// `session/new` response, applied by `session/set_config_option` with
/// complete-state semantics, and kept true by the `config_option_update`
/// push when resolution diverges from the announced state.
@Suite struct ConfigOptionsTests {
    /// The text the standard slot's scripted model answers, so a turn's
    /// output names the slot that generated it.
    private static let standardAnswer = "standard-answer"

    /// The text the flash slot's scripted model answers.
    private static let flashAnswer = "flash-answer"

    /// A session id no agent ever issued.
    private static let unknownSessionId = SessionId(rawValue: "01UNKNOWNSESSIONULID0000000")

    // MARK: Harness

    /// A loader whose standard and flash containers play different
    /// scripts, so a turn's text asserts which slot generated it.
    ///
    /// - Returns: The loader to inject.
    private static func makeSlotLoader() -> StubModelLoader {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { slot in
            let answer = slot == .flash ? Self.flashAnswer : Self.standardAnswer
            return ScriptedLLMContainer(script: [.textDelta(answer), .endTurn])
        }
        return loader
    }

    /// Wires the shared fixture over the per-slot scripted loader.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeFixture(label: String) async throws -> ScriptedTurnFixture {
        try await ScriptedTurnFixture.make(loader: makeSlotLoader(), label: label)
    }

    /// The `session/set_config_option` request for the model option.
    ///
    /// - Parameters:
    ///   - sessionId: The session to set the option on.
    ///   - value: The tagged value to set.
    ///   - configId: The option to set; the model option by default.
    /// - Returns: The request.
    private static func makeSetRequest(
        sessionId: SessionId,
        value: SetSessionConfigOptionRequest.Value,
        configId: SessionConfigId = ConfigOptions.modelOptionId
    ) -> SetSessionConfigOptionRequest {
        SetSessionConfigOptionRequest(configId: configId, sessionId: sessionId, value: value)
    }

    /// The tagged select value for `slot`.
    ///
    /// - Parameter slot: The slot to select.
    /// - Returns: The `type: "id"` value.
    private static func idValue(for slot: ModelSlot) -> SetSessionConfigOptionRequest.Value {
        .id(SessionConfigValueId(rawValue: slot.rawValue))
    }

    // MARK: Readers

    /// The one model select of a complete option state.
    ///
    /// - Parameter options: The announced complete state.
    /// - Returns: The select payload.
    /// - Throws: When the state is not exactly one select option.
    private static func modelSelect(in options: [SessionConfigOption]?) throws
        -> SessionConfigSelect
    {
        let options = try #require(options)
        #expect(options.count == 1)
        let option = try #require(options.first)
        #expect(option.configId == ConfigOptions.modelOptionId)
        #expect(option.category == .model)
        guard case .select(let select) = option.type else {
            Issue.record("expected a select option, got \(option.type)")
            throw RequestError.invalidParams
        }
        return select
    }

    /// The typed select values behind a select's raw `options` JSON, so
    /// the assertion pins the wire shape to the generated decoder.
    ///
    /// - Parameter select: The select payload.
    /// - Returns: The decoded values, in announcement order.
    /// - Throws: When the raw JSON does not decode as the flat list.
    private static func decodedSelectOptions(
        of select: SessionConfigSelect
    ) throws -> [SessionConfigSelectOption] {
        let data = try JSONEncoder().encode(select.options)
        return try JSONDecoder().decode([SessionConfigSelectOption].self, from: data)
    }

    /// The concatenated agent-message text of a collected sequence.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The agent text, chunks joined in arrival order.
    private static func agentText(in updates: [UpdateSessionNotification]) -> String {
        updates.compactMap { notification in
            if case .agentMessageChunk(let chunk) = notification.update,
                case .text(let content) = chunk.content
            {
                return content.text
            }
            return nil
        }.joined()
    }

    /// The `config_option_update` payloads of a collected sequence.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The pushed complete states, in arrival order.
    private static func pushedStates(in updates: [UpdateSessionNotification])
        -> [ConfigOptionUpdate]
    {
        updates.compactMap { notification in
            if case .configOptionUpdate(let payload) = notification.update {
                return payload
            }
            return nil
        }
    }

    // MARK: - The session/new announcement

    /// The `session/new` response carries exactly one config option: a
    /// select of category `model` whose default is the standard slot and
    /// whose labels show each slot's `chosen.stringValue`.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewAnnouncesOneModelSlotSelectWithTheStandardDefault() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-announce")

        let select = try Self.modelSelect(in: fixture.newSessionConfigOptions)
        #expect(select.currentValue.rawValue == ModelSlot.standard.rawValue)

        let values = try Self.decodedSelectOptions(of: select)
        let profile = fixture.harness.agent.residentProfile
        #expect(
            values.map(\.name) == [
                profile.standard.chosen.stringValue, profile.flash.chosen.stringValue,
            ])
        #expect(
            values.map(\.value.rawValue) == [
                ModelSlot.standard.rawValue, ModelSlot.flash.rawValue,
            ])
        await fixture.close()
    }

    // MARK: - The unknown-id policy (plan.md §10.1)

    /// `session/set_config_option` with an unknown session id answers
    /// JSON-RPC invalid params with the id in `data`, and pushes no
    /// `config_option_update`.
    @Test(.timeLimit(.minutes(1)))
    func anUnknownSessionIdAnswersInvalidParamsWithTheIdInData() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-unknown")

        do {
            _ = try await fixture.harness.connection.setSessionConfigOption(
                Self.makeSetRequest(sessionId: Self.unknownSessionId, value: Self.idValue(for: .flash)))
            Issue.record("expected the unknown-id refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == Self.unknownSessionId.rawValue)
        }

        #expect(await fixture.collector.updates(ofKind: .configOptionUpdate).isEmpty)
        await fixture.close()
    }

    /// `session/set_config_option` on a closed session answers invalid
    /// params with the resume hint, and pushes no `config_option_update`.
    @Test(.timeLimit(.minutes(1)))
    func aClosedSessionAnswersInvalidParamsWithTheResumeHint() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-closed")
        await fixture.harness.agent.markSessionClosed(fixture.sessionId)

        do {
            _ = try await fixture.harness.connection.setSessionConfigOption(
                Self.makeSetRequest(sessionId: fixture.sessionId, value: Self.idValue(for: .flash)))
            Issue.record("expected the closed-session refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            #expect(errorDataField("sessionId", of: error) == fixture.sessionId.rawValue)
            #expect(errorDataField("reason", of: error) == "closed; resume it first")
        }

        #expect(await fixture.collector.updates(ofKind: .configOptionUpdate).isEmpty)
        await fixture.close()
    }

    // MARK: - The slot switch

    /// A set to `flash` answers the complete state showing `flash`, and
    /// the next turn generates on the flash slot's model.
    @Test(.timeLimit(.minutes(1)))
    func settingFlashSwitchesLaterTurnsToTheFlashSlot() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-switch")

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "first"))
        let firstTurn = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        #expect(Self.agentText(in: firstTurn).contains(Self.standardAnswer))
        try await ScriptedTurnFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)

        let response = try await fixture.harness.connection.setSessionConfigOption(
            Self.makeSetRequest(sessionId: fixture.sessionId, value: Self.idValue(for: .flash)))
        let select = try Self.modelSelect(in: response.configOptions)
        #expect(select.currentValue.rawValue == ModelSlot.flash.rawValue)
        #expect(try Self.decodedSelectOptions(of: select).count == ConfigOptions.selectableSlots.count)
        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.selectedSlot == .flash)

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "second"))
        let bothTurns = try await ScriptedTurnFixture.waitForIdle(fixture.collector, count: 2)
        #expect(Self.agentText(in: bothTurns).contains(Self.flashAnswer))

        // The set response already carried the complete state, so no
        // push follows it.
        try await ScriptedTurnFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        #expect(await fixture.collector.updates(ofKind: .configOptionUpdate).isEmpty)
        await fixture.close()
    }

    /// An invalid set — an unknown option id, a value that is not a
    /// slot, or a value of the wrong type — answers invalid params, and
    /// the state does not change.
    @Test(.timeLimit(.minutes(1)))
    func anInvalidSetAnswersInvalidParamsAndChangesNothing() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-invalid")

        let invalidRequests: [(label: String, request: SetSessionConfigOptionRequest)] = [
            (
                "an unknown option id",
                Self.makeSetRequest(
                    sessionId: fixture.sessionId,
                    value: Self.idValue(for: .flash),
                    configId: SessionConfigId(rawValue: "mode"))
            ),
            (
                "the embedding slot, which is not a chat slot",
                Self.makeSetRequest(sessionId: fixture.sessionId, value: Self.idValue(for: .embedding))
            ),
            (
                "a boolean value on a select option",
                Self.makeSetRequest(sessionId: fixture.sessionId, value: .boolean(true))
            ),
        ]
        for (label, request) in invalidRequests {
            do {
                _ = try await fixture.harness.connection.setSessionConfigOption(request)
                Issue.record("expected the invalid-params refusal for \(label)")
            } catch let error as RequestError {
                #expect(error.code == .invalidParams, "for \(label)")
            }
        }

        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.selectedSlot == .standard)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "still standard"))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        #expect(Self.agentText(in: updates).contains(Self.standardAnswer))
        #expect(await fixture.collector.updates(ofKind: .configOptionUpdate).isEmpty)
        await fixture.close()
    }

    // MARK: - The divergence push (plan.md §15)

    /// When the announced state shows a different model than resolution
    /// runs, the turn's end pushes exactly one `config_option_update`
    /// carrying the full option list, and `currentValue` is the truth.
    @Test(.timeLimit(.minutes(1)))
    func aScriptedResolutionDivergencePushesOneFullConfigOptionUpdate() async throws {
        let fixture = try await Self.makeFixture(label: "ConfigOptionsTests-divergence")
        let agent = fixture.harness.agent

        // Script the divergence: the announced state claims the flash
        // slot's model while the session generates on standard.
        let stale = ConfigOptions.options(
            profile: agent.residentProfile, selectedSlot: .flash)
        await agent.recordAnnouncedConfigOptions(stale, for: fixture.sessionId)

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "first"))
        let updates = try await ScriptedTurnFixture.waitForUpdates(
            of: fixture.collector, toReach: "one config_option_update"
        ) { updates in
            updates.contains { $0.update.kind == .configOptionUpdate }
        }

        let pushed = Self.pushedStates(in: updates)
        #expect(pushed.count == 1)
        let select = try Self.modelSelect(in: try #require(pushed.first).configOptions)
        #expect(select.currentValue.rawValue == ModelSlot.standard.rawValue)
        #expect(try Self.decodedSelectOptions(of: select).count == ConfigOptions.selectableSlots.count)

        // The push reconciled the state, so a second turn pushes nothing.
        try await ScriptedTurnFixture.waitForAvailability(agent, fixture.sessionId)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "second"))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector, count: 2)
        try await ScriptedTurnFixture.waitForAvailability(agent, fixture.sessionId)
        #expect(await fixture.collector.updates(ofKind: .configOptionUpdate).count == 1)
        await fixture.close()
    }
}
