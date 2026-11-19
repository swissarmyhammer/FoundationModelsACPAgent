import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `sessions.recap` setting (D206): the builtin layer turns the recap
/// on, a user level or a folder level can turn it off, and
/// ``SettingsStore/isSessionRecapOn(for:)`` gives the merged value of a
/// folder from the store at each call.
@Suite struct SessionRecapSettingTests {
  /// The key path of `sessions.recap`.
  private static let recapKeyPath = [
    AgentConfiguration.CodingKeys.sessions.stringValue, SessionsConfiguration.CodingKeys.recap.stringValue,
  ]

  /// A folder level that turns the recap off.
  private static let recapOffYAML = "sessions:\n  recap: false\n"

  /// A folder level that turns the recap on.
  private static let recapOnYAML = "sessions:\n  recap: true\n"

  /// A folder level whose `recap` is not a Boolean, so the decode fails.
  private static let badYAML = "sessions:\n  recap: [1, 2]\n"

  /// The arguments of an `updateSetting` call of `sessions.recap` at the
  /// session level of a folder.
  ///
  /// - Parameters:
  ///   - value: The new value.
  ///   - workingDirectory: The working directory of the session.
  /// - Returns: The arguments.
  private static func setRecapArguments(_ value: Bool, cwd workingDirectory: URL)
    -> GraphQLArguments
  {
    var variables = SettingsGraphFixture.variables(keyPath: recapKeyPath, cwd: workingDirectory)
    variables["value"] = .bool(value)
    variables["level"] = .string(SettingsGraphFixture.sessionLevel)
    return GraphQLArguments(query: SettingsGraphFixture.setMutation, variables: variables)
  }

  /// The `value` and the `level` of the `setting` of a reply.
  ///
  /// - Parameter reply: The reply of a `setting` query.
  /// - Returns: The value as a Boolean, and the level name.
  /// - Throws: A failed requirement when the reply has no setting.
  private static func recapReading(of reply: GraphQLReply) throws -> (value: Bool?, level: String?) {
    let setting = try reply.object("setting")
    return (setting["value"] as? Bool, setting["level"] as? String)
  }

  // MARK: - The builtin layer

  /// The builtin file turns the recap on.
  @Test func theBuiltinFileTurnsTheRecapOn() throws {
    let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

    #expect(decoded.sessions.recap == true)
  }

  // MARK: - The folder function

  /// A folder level with `recap: false` turns the recap off for that folder.
  @Test func aFolderLevelTurnsTheRecapOffForItsFolder() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-folder-off")
    try ConfigFileFixture.write(
      Self.recapOffYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

    #expect(try await fixture.store.isSessionRecapOn(for: fixture.firstDirectory) == false)
  }

  /// A folder level with `recap: false` does not turn the recap off for a
  /// different folder.
  @Test func aFolderLevelKeepsTheRecapOnForADifferentFolder() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-other-folder")
    try ConfigFileFixture.write(
      Self.recapOffYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

    #expect(try await fixture.store.isSessionRecapOn(for: fixture.secondDirectory) == true)
  }

  /// The `settings` tool turns the recap off for a folder, and the next
  /// call of the folder function gives the new value with no restart.
  @Test func theSettingsToolChangeAppliesAtTheNextCall() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-tool")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)
    _ = try await fixture.store.isSessionRecapOn(for: fixture.firstDirectory)

    let reply = try GraphQLReply(
      await tool.call(arguments: Self.setRecapArguments(false, cwd: fixture.firstDirectory)))

    #expect(reply.codes.isEmpty, "\(reply.text)")
    #expect(try await fixture.store.isSessionRecapOn(for: fixture.firstDirectory) == false)
  }

  // MARK: - The synchronous policy read

  /// A folder level with `recap: false` turns the synchronous read off for
  /// a session in that folder.
  @Test func theNowReadIsOffForAFolderThatTurnsItOff() throws {
    let fixture = try SettingsGraphFixture(label: "recap-now-folder-off")
    try ConfigFileFixture.write(
      Self.recapOffYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

    #expect(fixture.store.isSessionRecapOnNow(for: fixture.firstDirectory) == false)
  }

  /// A folder level with `recap: false` keeps the synchronous read on for
  /// a session in a different folder.
  @Test func theNowReadStaysOnForADifferentFolder() throws {
    let fixture = try SettingsGraphFixture(label: "recap-now-other-folder")
    try ConfigFileFixture.write(
      Self.recapOffYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

    #expect(fixture.store.isSessionRecapOnNow(for: fixture.secondDirectory) == true)
  }

  /// The `settings` tool turns the recap off for a folder whose level the
  /// store holds, and the synchronous read gives the new value with no
  /// restart.
  @Test func theNowReadGivesTheValueOfTheSettingsTool() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-now-tool")
    let tool = SettingsTool(endpoint: fixture.graph, sessionDirectory: fixture.firstDirectory)
    try await fixture.store.startWatching(cwd: fixture.firstDirectory)

    let reply = try GraphQLReply(
      await tool.call(arguments: Self.setRecapArguments(false, cwd: fixture.firstDirectory)))

    #expect(reply.codes.isEmpty, "\(reply.text)")
    #expect(fixture.store.isSessionRecapOnNow(for: fixture.firstDirectory) == false)
  }

  /// An outside write of the folder level file reaches the synchronous
  /// read after the watcher of the store reads the file again.
  @Test(.timeLimit(.minutes(1))) func theNowReadGivesTheValueOfAnOutsideWrite() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-now-outside")
    let workingDirectory = fixture.firstDirectory

    _ = try await OutsideSettingsWrite.write(
      Self.recapOffYAML, over: Self.recapOnYAML, in: try fixture.sessionRoot(of: workingDirectory),
      expecting: SettingsChange(level: .session(workingDirectory), keyPath: nil)
    ) {
      try await fixture.store.startWatching(cwd: workingDirectory)
      return await fixture.store.changes().makeAsyncIterator()
    } nextChange: { changes in
      await changes.next()
    }

    #expect(fixture.store.isSessionRecapOnNow(for: workingDirectory) == false)
  }

  /// A folder level that does not parse gives the default: the recap is on.
  @Test func theNowReadGivesTheDefaultForALevelThatDoesNotRead() throws {
    let fixture = try SettingsGraphFixture(label: "recap-now-bad")
    try ConfigFileFixture.write(
      Self.badYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

    #expect(fixture.store.isSessionRecapOnNow(for: fixture.firstDirectory) == true)
  }

  // MARK: - The settings endpoint

  /// The endpoint writes `recap: false` at the user level, and reads it
  /// back from the user level.
  @Test func theEndpointWritesAndReadsTheUserLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-endpoint-user")

    let set = try await fixture.set(
      .bool(false), at: Self.recapKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)
    let read = try await fixture.setting(Self.recapKeyPath, cwd: nil)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.recapReading(of: read) == (false, SettingsGraphFixture.userLevel), "\(read.text)")
  }

  /// The endpoint writes `recap: true` at the session level of a folder
  /// over a user level that turns it off, and reads it back from the
  /// session level of that folder.
  @Test func theEndpointWritesAndReadsTheFolderLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "recap-endpoint-folder")
    _ = try await fixture.set(
      .bool(false), at: Self.recapKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)

    let set = try await fixture.set(
      .bool(true), at: Self.recapKeyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)
    let read = try await fixture.setting(Self.recapKeyPath, cwd: fixture.firstDirectory)

    #expect(set.codes.isEmpty, "\(set.text)")
    #expect(
      try Self.recapReading(of: read) == (true, SettingsGraphFixture.sessionLevel),
      "\(read.text)")
  }

  /// The description of the `settings` tool describes the key.
  @Test func theToolDescriptionDescribesTheKey() {
    #expect(SettingsTool.toolDescription.contains(SessionsConfiguration.recapDescription))
  }
}
