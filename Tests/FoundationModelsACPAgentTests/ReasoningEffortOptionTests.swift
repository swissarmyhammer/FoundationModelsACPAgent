import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The reasoning effort select of a session (D218): one `select` option of
/// category `thought_level` over the levels of the model of the session, in
/// the `session/new` response, the `session/set_config_option` response
/// and each `config_option_update`. A set changes the level of the Router
/// session from its next turn. A model with no levels gives no option.
@Suite(.closesHarnesses) struct ReasoningEffortOptionTests {
  /// The three levels of the fake model of the standard slot. The default
  /// is `medium`.
  private static let threeLevels = ReasoningEffortLevels(
    levels: ["low", "medium", "high"], defaultLevel: "medium", hasOff: false)

  /// The two levels and the Off level of the fake model of the flash slot.
  /// The default is `high`.
  private static let flashLevels = ReasoningEffortLevels(
    levels: ["low", "high"], defaultLevel: "high", hasOff: true)

  /// The level that the tests set.
  private static let lowLevel = "low"

  /// The text that each scripted model answers.
  private static let answer = "effort-answer"

  /// The script of a plain turn.
  private static let answerScript: [ScriptedPassStep] = [.textDelta(answer), .endPass]

  // MARK: Harness

  /// A loader whose standard and flash containers have their own levels.
  ///
  /// - Parameters:
  ///   - standard: The levels of the standard model.
  ///   - flash: The levels of the flash model. None by default.
  ///   - standardScript: The script of the standard model.
  ///   - recorder: The recorder of the level of each submission of the
  ///     standard model, or `nil`.
  /// - Returns: The loader to inject.
  private static func makeLoader(
    standard: ReasoningEffortLevels, flash: ReasoningEffortLevels = .unsupported,
    standardScript: [ScriptedPassStep] = answerScript, recorder: ReasoningEffortRecorder? = nil
  ) -> StubModelLoader {
    var loader = StubModelLoader()
    loader.makeLLMContainer = { slot in
      slot == .flash
        ? ScriptedLLMContainer(script: answerScript, reasoningEffortLevels: flash)
        : ScriptedLLMContainer(
          script: standardScript, reasoningEffortLevels: standard, effortRecorder: recorder)
    }
    return loader
  }

  /// Wires the fixture over `loader`, with a `flash` model of its own, so
  /// each slot loads its own container.
  ///
  /// - Parameters:
  ///   - loader: The loader.
  ///   - label: The directory label of the calling test.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction or the handshake throws.
  private static func makeFixture(loader: StubModelLoader, label: String) async throws
    -> ScriptedPromptFixture
  {
    try await ScriptedPromptFixture.make(
      loader: loader, configuration: ScriptedPromptFixture.distinctFlashConfiguration,
      label: label)
  }

  /// Sets the reasoning effort option of the session of `fixture`.
  ///
  /// - Parameters:
  ///   - value: The tagged value to set.
  ///   - fixture: The fixture.
  /// - Returns: The response.
  /// - Throws: Whatever `session/set_config_option` throws.
  private static func setEffort(
    _ value: SetSessionConfigOptionRequest.Value, on fixture: ScriptedPromptFixture
  ) async throws -> SetSessionConfigOptionResponse {
    try await fixture.harness.connection.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.effortOptionId, sessionId: fixture.sessionId, value: value))
  }

  /// The tagged select value of a level.
  ///
  /// - Parameter level: The level.
  /// - Returns: The `type: "id"` value.
  private static func idValue(_ level: String) -> SetSessionConfigOptionRequest.Value {
    .id(SessionConfigValueId(rawValue: level))
  }

  /// The reasoning effort select of a complete option state.
  ///
  /// - Parameter options: The announced complete state.
  /// - Returns: The select payload.
  /// - Throws: When the state has no reasoning effort select.
  private static func effortSelect(in options: [SessionConfigOption]?) throws
    -> SessionConfigSelect
  {
    try ConfigOptionSelect.select(in: options, configId: ConfigOptions.effortOptionId)
  }

  /// The value ids of a select, in announcement order.
  ///
  /// - Parameter select: The select payload.
  /// - Returns: The value ids.
  /// - Throws: When the raw JSON does not decode as the flat list.
  private static func valueIds(of select: SessionConfigSelect) throws -> [String] {
    try ConfigOptionSelect.decodedOptions(of: select).map(\.value.rawValue)
  }

  /// The pushed `config_option_update` states of a collected sequence.
  ///
  /// - Parameter updates: The collected notifications.
  /// - Returns: The option lists of the pushes, in arrival order.
  private static func pushedOptions(in updates: [UpdateSessionNotification])
    -> [[SessionConfigOption]]
  {
    updates.compactMap { notification in
      guard case .configOptionUpdate(let payload) = notification.update else { return nil }
      return payload.configOptions
    }
  }

  // MARK: - The session/new announcement

  /// A model with three levels: the `session/new` response has the effort
  /// option with the three levels in the order of the model.
  @Test func sessionNewAnnouncesTheThreeLevelsOfTheModel() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-values")
    await fixture.close()

    let select = try Self.effortSelect(in: fixture.newSessionConfigOptions)
    #expect(try Self.valueIds(of: select) == Self.threeLevels.levels)
  }

  /// A model with three levels: the current value of the effort option is
  /// the default level of the model.
  @Test func sessionNewAnnouncesTheDefaultLevelAsTheCurrentValue() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-default")
    await fixture.close()

    let select = try Self.effortSelect(in: fixture.newSessionConfigOptions)
    #expect(select.currentValue.rawValue == Self.threeLevels.defaultLevel)
  }

  /// The effort option has the category `thought_level`.
  @Test func theEffortOptionHasTheThoughtLevelCategory() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-category")
    await fixture.close()

    let option = try #require(
      fixture.newSessionConfigOptions?.first { $0.configId == ConfigOptions.effortOptionId })
    #expect(option.category == .thoughtLevel)
  }

  /// A model with an Off level gives "Off" as the last value.
  @Test func aModelWithAnOffLevelGivesOffAsTheLastValue() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.flashLevels), label: "EffortOption-off")
    await fixture.close()

    let select = try Self.effortSelect(in: fixture.newSessionConfigOptions)
    #expect(try Self.valueIds(of: select).last == ReasoningEffortLevels.offLevelName)
  }

  /// A model with no levels: the `session/new` response has no effort
  /// option.
  @Test func aModelWithNoLevelsGetsNoEffortOption() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: .unsupported), label: "EffortOption-none")
    await fixture.close()

    let ids = try #require(fixture.newSessionConfigOptions).map(\.configId)
    #expect(!ids.contains(ConfigOptions.effortOptionId))
  }

  // MARK: - The set

  /// A set to `low` answers the complete state with `low`.
  @Test func aSetToLowAnswersTheEffortOptionWithLow() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-set")

    let response = try await Self.setEffort(Self.idValue(Self.lowLevel), on: fixture)
    await fixture.close()

    #expect(try Self.effortSelect(in: response.configOptions).currentValue.rawValue == Self.lowLevel)
  }

  /// A set to `low` gives the response AND one `config_option_update`
  /// with `low`, for a client that discards the response. The prompt end
  /// after it pushes nothing more, because the set recorded the state.
  @Test func aSetToLowAlsoPostsOneConfigOptionUpdateWithLow() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-set-push")

    let response = try await Self.setEffort(Self.idValue(Self.lowLevel), on: fixture)
    let updates = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "one config_option_update"
    ) { updates in
      updates.contains { $0.update.kind == .configOptionUpdate }
    }
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: "after the set")
    let pushedCount = await fixture.collector.updates(ofKind: .configOptionUpdate).count
    await fixture.close()

    #expect(try Self.effortSelect(in: response.configOptions).currentValue.rawValue == Self.lowLevel)
    let pushed = try #require(Self.pushedOptions(in: updates).first)
    #expect(try Self.effortSelect(in: pushed).currentValue.rawValue == Self.lowLevel)
    #expect(pushed == response.configOptions)
    #expect(pushedCount == 1)
  }

  /// A set that fails posts no `config_option_update`.
  @Test func aFailedSetPostsNoConfigOptionUpdate() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-failed-push")

    _ = try? await Self.setEffort(Self.idValue("xhigh"), on: fixture)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: "after the failed set")
    let pushedCount = await fixture.collector.updates(ofKind: .configOptionUpdate).count
    await fixture.close()

    #expect(pushedCount == 0)
  }

  /// A set to `low` changes the level of the Router session.
  @Test func aSetToLowChangesTheLevelOfTheRouterSession() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-router")
    let agent = fixture.harness.agent

    _ = try await Self.setEffort(Self.idValue(Self.lowLevel), on: fixture)
    let session = try #require(await agent.sessions[fixture.sessionId]?.session)
    let level = try await agent.sessionDirectory.reasoningEffort(of: session.id)
    await fixture.close()

    #expect(level == Self.lowLevel)
  }

  /// After a set to `low`, the next turn of the Router session states
  /// `low` to the model.
  @Test func theNextTurnAfterASetToLowUsesLow() async throws {
    let recorder = ReasoningEffortRecorder()
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels, recorder: recorder),
      label: "EffortOption-next-turn")

    _ = try await Self.setEffort(Self.idValue(Self.lowLevel), on: fixture)
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: "after the set")
    await fixture.close()

    #expect(recorder.levels.last == Self.lowLevel)
  }

  /// A value that is not a level of the model answers invalid params.
  @Test func aSetToAValueThatIsNotALevelAnswersInvalidParams() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-invalid")

    await #expect(throws: RequestError.invalidConfigOptionValue(id: ConfigOptions.effortOptionId)) {
      _ = try await Self.setEffort(Self.idValue("xhigh"), on: fixture)
    }
    await fixture.close()
  }

  /// A set of the effort option on a model with no levels is a set of an
  /// unknown option.
  @Test func aSetOnAModelWithNoLevelsAnswersAnUnknownOption() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: .unsupported), label: "EffortOption-unknown")

    await #expect(throws: RequestError.unknownConfigOption(id: ConfigOptions.effortOptionId)) {
      _ = try await Self.setEffort(Self.idValue(Self.lowLevel), on: fixture)
    }
    await fixture.close()
  }

  // MARK: - A change of the model

  /// A model set to the flash slot answers the levels of the flash model.
  @Test func aModelSetAnswersTheLevelsOfTheNewModel() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels, flash: Self.flashLevels),
      label: "EffortOption-model-set")

    let response = try await fixture.harness.connection.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.modelOptionId, sessionId: fixture.sessionId,
        value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))
    await fixture.close()

    let select = try Self.effortSelect(in: response.configOptions)
    #expect(try Self.valueIds(of: select) == Self.flashLevels.sessionLevelNames)
  }

  /// A model change that waits for an open prompt sends one
  /// `config_option_update` with the levels of the new model when the
  /// prompt ends.
  @Test func aModelChangeSendsAConfigOptionUpdateWithTheLevelsOfTheNewModel() async throws {
    let hold = ScriptedHold()
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(
        standard: Self.threeLevels, flash: Self.flashLevels,
        standardScript: [.holdUntilReleased(hold)] + Self.answerScript),
      label: "EffortOption-model-push")

    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "held"))
    try await ScriptedPromptFixture.waitForRunning(fixture.collector)
    try await fixture.switchModelSlot(to: .flash)
    hold.release()
    // The set posts its state at once, while the prompt still runs on the
    // standard model. The prompt end then posts the levels of the flash
    // model.
    let flashNames = Self.flashLevels.sessionLevelNames
    let updates = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "a config_option_update with the flash levels"
    ) { updates in
      Self.pushedOptions(in: updates).contains { options in
        (try? Self.valueIds(of: Self.effortSelect(in: options))) == flashNames
      }
    }
    await fixture.close()

    let pushed = try #require(Self.pushedOptions(in: updates).last)
    #expect(try Self.valueIds(of: Self.effortSelect(in: pushed)) == flashNames)
  }

  // MARK: - The profiles.<name>.effort setting

  /// The `profiles.<name>.effort` setting of the folder starts a new session
  /// at its level.
  @Test func theProfileEffortSettingStartsANewSessionAtItsLevel() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-setting")
    let agent = fixture.harness.agent
    try await agent.settingsStore.set(
      .string(Self.lowLevel), at: Self.effortKeyPath(of: agent), level: .session(fixture.cwd))

    let second = try await Self.newSessionOptions(in: fixture)
    await fixture.close()

    #expect(try Self.effortSelect(in: second).currentValue.rawValue == Self.lowLevel)
  }

  /// A `profiles.<name>.effort` value that is not a level of the model does
  /// not fail `session/new`: the session takes the default level.
  @Test func anUnknownProfileEffortStartsANewSessionAtTheDefaultLevel() async throws {
    let fixture = try await Self.makeFixture(
      loader: Self.makeLoader(standard: Self.threeLevels), label: "EffortOption-setting-unknown")
    let agent = fixture.harness.agent
    try await agent.settingsStore.set(
      .string("xhigh"), at: Self.effortKeyPath(of: agent), level: .session(fixture.cwd))

    let second = try await Self.newSessionOptions(in: fixture)
    await fixture.close()

    #expect(
      try Self.effortSelect(in: second).currentValue.rawValue == Self.threeLevels.defaultLevel)
  }

  /// The key path of `profiles.<name>.effort` for the resident profile of
  /// `agent`.
  ///
  /// - Parameter agent: The agent.
  /// - Returns: The key path.
  private static func effortKeyPath(of agent: RoutedACPAgent) -> [String] {
    [
      ProfilesConfiguration.sectionKey, agent.residentProfile.definitionName,
      ProfileSettings.CodingKeys.effort.stringValue,
    ]
  }

  /// Opens a second session in the folder of `fixture`, and gives the
  /// options of its `session/new` response.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The options of the response.
  /// - Throws: Whatever `session/new` throws.
  private static func newSessionOptions(in fixture: ScriptedPromptFixture) async throws
    -> [SessionConfigOption]?
  {
    let session = try await fixture.harness.client.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
    return await MainActor.run { session.configOptions }
  }

  // MARK: - The settings tool

  /// The prompt that starts the scripted `runCode` call.
  private static let toolPromptText = "Lower the reasoning effort of this session"

  /// The snippet: one `setReasoningEffort` mutation with `low`, which
  /// reports the level of its response.
  private static var setEffortCode: String {
    """
    const json = (answer) => typeof answer === "string" ? JSON.parse(answer) : answer;
    const set = json(await tools.settings.querySettings({
        query: "mutation { setReasoningEffort(input: {level: \\"\(lowLevel)\\"}) { level } }"
    }));
    return set.data && set.data.setReasoningEffort
        ? "level=" + set.data.setReasoningEffort.level : JSON.stringify(set);
    """
  }

  /// Wires a fixture whose standard model has three levels and plays one
  /// `runCode` call of ``setEffortCode``.
  ///
  /// - Parameter label: The directory label of the calling test.
  /// - Returns: The fixture.
  /// - Throws: Whatever the construction or the script encoding throws.
  private static func makeToolFixture(label: String) async throws -> ScriptedPromptFixture {
    try await Self.makeFixture(
      loader: Self.makeLoader(
        standard: Self.threeLevels,
        standardScript: try ScriptedPromptFixture.makeToolPromptScript(code: Self.setEffortCode)),
      label: label)
  }

  /// The `settings` tool of a session sets the level of its own session.
  @Test func theSettingsToolSetsTheLevelOfItsOwnSession() async throws {
    let fixture = try await Self.makeToolFixture(label: "EffortOption-tool")
    let agent = fixture.harness.agent

    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.toolPromptText)
    let session = try #require(await agent.sessions[fixture.sessionId]?.session)
    let level = try await agent.sessionDirectory.reasoningEffort(of: session.id)
    await fixture.close()

    #expect(level == Self.lowLevel)
  }

  /// A level change of the `settings` tool sends one `config_option_update`
  /// with the new level.
  @Test func theSettingsToolChangeSendsAConfigOptionUpdateWithTheNewLevel() async throws {
    let fixture = try await Self.makeToolFixture(label: "EffortOption-tool-push")

    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.toolPromptText)
    let updates = try await ScriptedPromptFixture.waitForUpdates(
      of: fixture.collector, toReach: "one config_option_update"
    ) { updates in
      updates.contains { $0.update.kind == .configOptionUpdate }
    }
    await fixture.close()

    let pushed = try #require(Self.pushedOptions(in: updates).last)
    #expect(try Self.effortSelect(in: pushed).currentValue.rawValue == Self.lowLevel)
  }
}
