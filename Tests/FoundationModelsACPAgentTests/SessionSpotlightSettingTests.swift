import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `sessions.spotlight` setting (D207 (i), Q73): the builtin layer
/// turns it on, and the `settings` tool and the `settings` endpoint read
/// and write it at the user level only. The app owns the Spotlight writes;
/// the agent does not act on the setting.
@Suite struct SessionSpotlightSettingTests {
  /// The key path of `sessions.spotlight`.
  private static let spotlightKeyPath = [
    AgentConfiguration.CodingKeys.sessions.stringValue,
    SessionsConfiguration.CodingKeys.spotlight.stringValue,
  ]

  /// The key path of the `sessions` section.
  private static let sessionsKeyPath = [AgentConfiguration.CodingKeys.sessions.stringValue]

  /// The code of a change that names a key of the user level only at the
  /// session level.
  private static let userLevelOnlyCode = "USER_LEVEL_ONLY"

  /// A user level that turns Spotlight off.
  private static let spotlightOffYAML = "sessions:\n  spotlight: false\n"

  /// The arguments of a `settings` tool call that sets `sessions.spotlight`.
  ///
  /// - Parameters:
  ///   - value: The new value.
  ///   - level: The `SettingLevel` name.
  /// - Returns: The arguments. They give no `cwd`: the folder of the
  ///   session of the tool applies.
  private static func setSpotlightArguments(_ value: Bool, level: String) -> GraphQLArguments {
    var variables = SettingsGraphFixture.variables(keyPath: spotlightKeyPath, cwd: nil)
    variables["value"] = .bool(value)
    variables["level"] = .string(level)
    return GraphQLArguments(query: SettingsGraphFixture.setMutation, variables: variables)
  }

  /// The arguments of a `settings` tool call that reads `sessions.spotlight`.
  ///
  /// - Returns: The arguments. They give no `cwd`: the folder of the
  ///   session of the tool applies.
  private static func readSpotlightArguments() -> GraphQLArguments {
    GraphQLArguments(
      query: SettingsGraphFixture.settingQuery,
      variables: SettingsGraphFixture.variables(keyPath: spotlightKeyPath, cwd: nil))
  }

  /// The `value` and the `level` of the `setting` of a reply.
  ///
  /// - Parameter reply: The reply of a `setting` query.
  /// - Returns: The value as a Boolean, and the level name.
  /// - Throws: A failed requirement when the reply has no setting.
  private static func spotlightReading(of reply: GraphQLReply) throws -> (value: Bool?, level: String?) {
    let setting = try reply.object("setting")
    return (setting["value"] as? Bool, setting["level"] as? String)
  }

  // MARK: - The configuration

  /// The builtin file turns Spotlight on.
  @Test func theBuiltinFileTurnsSpotlightOn() throws {
    let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

    #expect(decoded.sessions.spotlight == true)
  }

  /// A user level with `spotlight: false` merges over the builtin layer,
  /// and the merged tree of a folder decodes to `spotlight == false`.
  @Test func aUserLevelTurnsSpotlightOffInTheMergedConfiguration() throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-user-merge")
    try ConfigFileFixture.write(Self.spotlightOffYAML, in: try fixture.userRoot)

    let merged = try fixture.store.mergedRootNow(for: fixture.firstDirectory)
      .decoded(as: AgentConfiguration.self)

    #expect(merged.sessions.spotlight == false)
  }

  // MARK: - The settings endpoint

  /// The endpoint writes `spotlight: false` at the user level, and reads it
  /// back from the user level.
  @Test func theEndpointWritesAndReadsTheUserLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-endpoint-user")

    let set = try await fixture.set(
      .bool(false), at: Self.spotlightKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)
    let read = try await fixture.setting(Self.spotlightKeyPath, cwd: nil)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.spotlightReading(of: read) == (false, SettingsGraphFixture.userLevel), "\(read.text)")
  }

  /// The endpoint refuses `spotlight` at the session level of a folder.
  @Test func theEndpointRefusesTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-endpoint-folder")

    let set = try await fixture.set(
      .bool(false), at: Self.spotlightKeyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)

    #expect(set.codes == [Self.userLevelOnlyCode], "\(set.text)")
  }

  /// The endpoint refuses a `sessions` mapping that holds `spotlight` at
  /// the session level of a folder.
  @Test func theEndpointRefusesASectionWithSpotlightAtTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-endpoint-section")

    let set = try await fixture.set(
      .dictionary(["spotlight": .bool(false)]), at: Self.sessionsKeyPath,
      level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)

    #expect(set.codes == [Self.userLevelOnlyCode], "\(set.text)")
  }

  /// A refused session level change writes nothing: the read of the folder
  /// still gives the builtin value.
  @Test func aRefusedSessionLevelChangeWritesNothing() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-endpoint-nothing")
    _ = try await fixture.set(
      .bool(false), at: Self.spotlightKeyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)

    let read = try await fixture.setting(Self.spotlightKeyPath, cwd: fixture.firstDirectory)

    #expect(
      try Self.spotlightReading(of: read) == (true, SettingsGraphFixture.builtinLayer), "\(read.text)")
  }

  /// The endpoint still writes a `sessions` mapping with `recap` only at
  /// the session level of a folder.
  @Test func theEndpointWritesTheRecapSectionAtTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-endpoint-recap")

    let set = try await fixture.set(
      .dictionary(["recap": .bool(false)]), at: Self.sessionsKeyPath,
      level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
  }

  // MARK: - The settings tool

  /// The `settings` tool of a session writes `spotlight: false` at the user
  /// level, and reads it back from the user level.
  @Test func theToolWritesAndReadsTheUserLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-tool-user")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)

    let set = try GraphQLReply(
      await tool.call(arguments: Self.setSpotlightArguments(false, level: SettingsGraphFixture.userLevel)))
    let read = try GraphQLReply(await tool.call(arguments: Self.readSpotlightArguments()))

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.spotlightReading(of: read) == (false, SettingsGraphFixture.userLevel), "\(read.text)")
  }

  /// The `settings` tool of a session refuses `spotlight` at the session
  /// level.
  @Test func theToolRefusesTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-tool-folder")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)

    let set = try GraphQLReply(
      await tool.call(arguments: Self.setSpotlightArguments(false, level: SettingsGraphFixture.sessionLevel)))

    #expect(set.codes == [Self.userLevelOnlyCode], "\(set.text)")
  }

  /// The description of the `settings` tool describes the key.
  @Test func theToolDescriptionDescribesTheKey() {
    #expect(SettingsTool.toolDescription.contains(SessionsConfiguration.spotlightDescription))
  }
}
