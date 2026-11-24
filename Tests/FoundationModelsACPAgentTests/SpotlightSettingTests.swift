import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `spotlight` section (D214, D100): one switch for each kind of Spotlight item. The
/// `settings` tool and the `settings` endpoint read and write each key at the user level and at
/// the session level, as each other key. The app reads the keys; the agent applies no rule to
/// them. The key `sessions.spotlight` is gone.
@Suite struct SpotlightSettingTests {
  /// The key path of a key of the `spotlight` section.
  ///
  /// - Parameter key: The key.
  /// - Returns: The key path.
  private static func keyPath(_ key: SpotlightConfiguration.CodingKeys) -> [String] {
    [SpotlightConfiguration.sectionKey, key.stringValue]
  }

  /// The arguments of a `settings` tool call that sets a key.
  ///
  /// - Parameters:
  ///   - keyPath: The key path.
  ///   - value: The new value.
  ///   - level: The `SettingLevel` name.
  /// - Returns: The arguments. They give no `cwd`: the folder of the session of the tool applies.
  private static func setArguments(_ keyPath: [String], _ value: Bool, level: String)
    -> GraphQLArguments
  {
    var variables = SettingsGraphFixture.variables(keyPath: keyPath, cwd: nil)
    variables["value"] = .bool(value)
    variables["level"] = .string(level)
    return GraphQLArguments(query: SettingsGraphFixture.setMutation, variables: variables)
  }

  /// The `value` and the `level` of the `setting` of a reply.
  ///
  /// - Parameter reply: The reply of a `setting` query.
  /// - Returns: The value as a Boolean, and the level name.
  /// - Throws: A failed requirement when the reply has no setting.
  private static func reading(of reply: GraphQLReply) throws -> (value: Bool?, level: String?) {
    let setting = try reply.object("setting")
    return (setting["value"] as? Bool, setting["level"] as? String)
  }

  // MARK: - The configuration

  /// The builtin file gives the default of each key of the section.
  @Test func theBuiltinFileGivesTheDefaultOfEachKey() throws {
    let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

    #expect(decoded.spotlight == SpotlightConfiguration())
    #expect(
      [
        decoded.spotlight.enabled, decoded.spotlight.sessions, decoded.spotlight.archivedSessions,
        decoded.spotlight.automatedSessions, decoded.spotlight.tasks, decoded.spotlight.library,
        decoded.spotlight.externalSessions, decoded.spotlight.settings, decoded.spotlight.commands,
      ] == [true, true, false, false, true, true, true, true, true])
    let builtin = try BuiltinConfigurationFile.root()
    #expect(builtin.value(at: [SessionsConfiguration.sectionKey, "spotlight"]) == nil)
  }

  // MARK: - The settings endpoint

  /// `updateSetting spotlight.tasks false` at the user level is accepted, and a read gives
  /// `false` from the user level.
  @Test func theEndpointWritesAndReadsAKeyAtTheUserLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-tasks-user")
    let keyPath = Self.keyPath(.tasks)

    let set = try await fixture.set(
      .bool(false), at: keyPath, level: SettingsGraphFixture.userLevel, cwd: nil)
    let read = try await fixture.setting(keyPath, cwd: nil)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(try Self.reading(of: read) == (false, SettingsGraphFixture.userLevel), "\(read.text)")
  }

  /// `spotlight.enabled: false` at the session level of a folder gives `false` for that folder
  /// and `true` for another folder.
  @Test func theSessionLevelOfAFolderTurnsSpotlightOffForThatFolderOnly() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-enabled-folder")
    let keyPath = Self.keyPath(.enabled)

    let set = try await fixture.set(
      .bool(false), at: keyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)
    let first = try await fixture.setting(keyPath, cwd: fixture.firstDirectory)
    let second = try await fixture.setting(keyPath, cwd: fixture.secondDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.reading(of: first) == (false, SettingsGraphFixture.sessionLevel), "\(first.text)")
    #expect(
      try Self.reading(of: second) == (true, SettingsGraphFixture.builtinLayer), "\(second.text)")
  }

  /// A `config.yaml` of a folder with `spotlight.enabled: false` merges to `false` for that
  /// folder only. The merged tree of another folder has no value, so the default (`true`)
  /// applies.
  @Test func aFolderFileTurnsSpotlightOffInTheMergedConfiguration() throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-enabled-file")
    try ConfigFileFixture.write(
      "spotlight:\n  enabled: false\n", in: try fixture.sessionRoot(of: fixture.firstDirectory))

    let first = try fixture.store.mergedRootNow(for: fixture.firstDirectory)
      .decoded(as: AgentConfiguration.self)
    let second = try fixture.store.mergedRootNow(for: fixture.secondDirectory)

    #expect(first.spotlight.enabled == false)
    #expect(second.value(at: Self.keyPath(.enabled)) == nil)
    #expect(SpotlightConfiguration().enabled == true)
  }

  /// `updateSetting sessions.spotlight` gives the answer of an unknown key.
  @Test func theOldSessionsKeyIsUnknown() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-old-key")

    let set = try await fixture.set(
      .bool(false), at: [SessionsConfiguration.sectionKey, "spotlight"],
      level: SettingsGraphFixture.userLevel, cwd: nil)

    #expect(set.codes == [Self.unknownKeyCode], "\(set.text)")
  }

  /// The code of a change of a key that a checked section does not know.
  private static let unknownKeyCode = "INVALID_VALUE"

  // MARK: - The settings tool

  /// The `settings` tool of a session writes a key at the session level of its folder.
  @Test func theToolWritesAKeyAtTheSessionLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-tool-folder")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)

    let set = try GraphQLReply(
      await tool.call(
        arguments: Self.setArguments(
          Self.keyPath(.enabled), false, level: SettingsGraphFixture.sessionLevel)))
    let read = try await fixture.setting(Self.keyPath(.enabled), cwd: fixture.firstDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.reading(of: read) == (false, SettingsGraphFixture.sessionLevel), "\(read.text)")
  }

  /// The description of the `settings` tool describes the section.
  @Test func theToolDescriptionDescribesTheSection() {
    #expect(SettingsTool.toolDescription.contains(SpotlightConfiguration.help))
  }
}
