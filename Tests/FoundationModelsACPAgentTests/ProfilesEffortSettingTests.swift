import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `profiles` section (D218): `profiles.<name>.effort` is the default
/// reasoning effort of the new sessions on a profile. The `settings` tool
/// and the `settings` endpoint read and write it at the user level and at
/// the session level of a folder. A value that is not a level of the model
/// gives a configuration warning and the default level.
@Suite struct ProfilesEffortSettingTests {
  /// The name of the profile of the tests.
  private static let profileName = "large"

  /// The value that the tests write.
  private static let lowLevel = "low"

  /// The three levels of a fake model. The default is `medium`.
  private static let threeLevels = ReasoningEffortLevels(
    levels: ["low", "medium", "high"], defaultLevel: "medium", hasOff: false)

  /// The key path of `profiles.large.effort`.
  private static let keyPath = [
    ProfilesConfiguration.sectionKey, profileName, ProfileSettings.CodingKeys.effort.stringValue,
  ]

  /// The code of a change that the schema check refuses.
  private static let invalidValueCode = "INVALID_VALUE"

  /// The `value` and the `level` of the `setting` of a reply.
  ///
  /// - Parameter reply: The reply of a `setting` query.
  /// - Returns: The value as a string, and the level name.
  /// - Throws: A failed requirement when the reply has no setting.
  private static func reading(of reply: GraphQLReply) throws -> (value: String?, level: String?) {
    let setting = try reply.object("setting")
    return (setting["value"] as? String, setting["level"] as? String)
  }

  // MARK: - The configuration

  /// The builtin file gives an empty section.
  @Test func theBuiltinFileGivesNoProfileSettings() throws {
    let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

    #expect(decoded.profiles == ProfilesConfiguration())
  }

  /// A folder file with `profiles.large.effort` decodes to the value.
  @Test func aFolderFileGivesTheEffortOfTheProfile() throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-file")
    try ConfigFileFixture.write(
      "profiles:\n  large:\n    effort: low\n",
      in: try fixture.sessionRoot(of: fixture.firstDirectory))

    let merged = try fixture.store.mergedRootNow(for: fixture.firstDirectory)
      .decoded(as: AgentConfiguration.self)

    #expect(merged.profiles.effort(of: Self.profileName) == Self.lowLevel)
  }

  // MARK: - The settings endpoint

  /// The endpoint writes and reads the key at the user level.
  @Test func theEndpointWritesAndReadsTheKeyAtTheUserLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-user")

    let set = try await fixture.set(
      .string(Self.lowLevel), at: Self.keyPath, level: SettingsGraphFixture.userLevel, cwd: nil)
    let read = try await fixture.setting(Self.keyPath, cwd: nil)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.reading(of: read) == (Self.lowLevel, SettingsGraphFixture.userLevel), "\(read.text)")
  }

  /// The endpoint writes the key at the session level of one folder only.
  @Test func theEndpointWritesTheKeyAtTheSessionLevelOfOneFolder() async throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-folder")

    let set = try await fixture.set(
      .string(Self.lowLevel), at: Self.keyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)
    let first = try await fixture.setting(Self.keyPath, cwd: fixture.firstDirectory)
    let second = try await fixture.setting(Self.keyPath, cwd: fixture.secondDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.reading(of: first) == (Self.lowLevel, SettingsGraphFixture.sessionLevel),
      "\(first.text)")
    #expect(second.data?["setting"] is NSNull, "\(second.text)")
  }

  /// A key under a profile that is not `effort` is refused.
  @Test func anUnknownKeyOfAProfileIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-unknown-key")

    let set = try await fixture.set(
      .string(Self.lowLevel), at: [ProfilesConfiguration.sectionKey, Self.profileName, "speed"],
      level: SettingsGraphFixture.userLevel, cwd: nil)

    #expect(set.codes == [Self.invalidValueCode], "\(set.text)")
  }

  // MARK: - The settings tool

  /// The `settings` tool of a session writes the key at the session level
  /// of its folder.
  @Test func theToolWritesTheKeyAtTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-tool")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)
    var variables = SettingsGraphFixture.variables(keyPath: Self.keyPath, cwd: nil)
    variables["value"] = .string(Self.lowLevel)
    variables["level"] = .string(SettingsGraphFixture.sessionLevel)

    let set = try GraphQLReply(
      await tool.call(
        arguments: GraphQLArguments(query: SettingsGraphFixture.setMutation, variables: variables)))
    let read = try await fixture.setting(Self.keyPath, cwd: fixture.firstDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.reading(of: read) == (Self.lowLevel, SettingsGraphFixture.sessionLevel),
      "\(read.text)")
  }

  /// The description of the `settings` tool describes the section.
  @Test func theToolDescriptionDescribesTheSection() {
    #expect(SettingsTool.toolDescription.contains(ProfilesConfiguration.help))
  }

  /// A call of the endpoint has no session, thus it cannot read the
  /// reasoning effort of a session.
  @Test func theEndpointHasNoSessionReasoningEffort() async throws {
    let fixture = try SettingsGraphFixture(label: "profiles-effort-no-session")

    let read = try await fixture.run("{ reasoningEffort { level } }")

    #expect(read.codes == [SettingsGraphError.noSessionReasoningEffort.code], "\(read.text)")
  }

  // MARK: - The start level of a new session

  /// A setting that is a level of the model gives that level.
  @Test func aKnownLevelStartsTheSessionAtThatLevel() {
    let start = ConfigOptions.startEffort(
      setting: Self.lowLevel, levels: Self.threeLevels, profileName: Self.profileName)

    #expect(start.level == Self.lowLevel)
  }

  /// A setting that is a level of the model gives no warning.
  @Test func aKnownLevelGivesNoWarning() {
    let start = ConfigOptions.startEffort(
      setting: Self.lowLevel, levels: Self.threeLevels, profileName: Self.profileName)

    #expect(start.warning == nil)
  }

  /// A setting that is not a level of the model gives a configuration
  /// warning with the levels and the default level of the model.
  @Test func anUnknownValueGivesAWarning() {
    let start = ConfigOptions.startEffort(
      setting: "xhigh", levels: Self.threeLevels, profileName: Self.profileName)

    #expect(
      start.warning
        == .unknownEffort(
          profile: Self.profileName, value: "xhigh", levels: Self.threeLevels.levels,
          defaultLevel: Self.threeLevels.defaultLevel))
  }

  /// A setting that is not a level of the model gives the default level of
  /// the model (`nil` for Router).
  @Test func anUnknownValueStartsTheSessionAtTheDefaultLevel() {
    let start = ConfigOptions.startEffort(
      setting: "xhigh", levels: Self.threeLevels, profileName: Self.profileName)

    #expect(start.level == nil)
  }

  /// The warning of an unknown value names the key path of the setting.
  @Test func theWarningNamesTheKeyPathOfTheSetting() {
    let warning = ConfigurationWarning.unknownEffort(
      profile: Self.profileName, value: "xhigh", levels: Self.threeLevels.levels,
      defaultLevel: Self.threeLevels.defaultLevel)

    #expect(warning.sectionKeyPath == Self.keyPath.joined(separator: "."))
  }
}
