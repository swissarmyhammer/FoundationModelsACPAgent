import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// A `profile` value that gives no usable name uses the fallback profile
/// (D203, task ^8a6cykg): the old map form with no `preset`, and a `null`
/// value. Before the fix, such a value gave the in-code default `large`,
/// and a machine where `large` does not fit stopped at the resolution.
@Suite struct OldProfileMapFallbackTests {
  /// The dotfolder name of the agents of this suite.
  private static let agentName = "old-profile-map-fallback"

  /// The name of the bundled profile `medium`. It is not the default
  /// fallback of a loader, so a load that gives it used the fallback of
  /// the test.
  private static let mediumName = "medium"

  /// The old map form with no `preset`, as an older client writes it.
  private static let oldMapDocument = """
    profile:
      standard: ["mlx-community/Qwen3-4B-4bit"]
      flash: ["mlx-community/Qwen3-1.7B-4bit"]
    """

  /// A `profile` key with a `null` value.
  private static let nullProfileDocument = "profile: ~\n"

  /// Loads `document` as the project `config.yaml` with the fallback
  /// profile ``mediumName``.
  ///
  /// - Parameter document: The project `config.yaml`.
  /// - Returns: The loaded configuration.
  /// - Throws: What the load throws.
  private static func load(_ document: String) throws -> LoadedConfiguration {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(document, in: fixture.projectDirectory)
    return try fixture.makeLoader(fallbackProfileName: mediumName).load()
  }

  /// The old map form with no `preset` selects the fallback profile.
  @Test func theOldMapFormWithNoPresetSelectsTheFallback() throws {
    let loaded = try Self.load(Self.oldMapDocument)

    #expect(loaded.configuration.profile.definition.name == Self.mediumName)
  }

  /// The old map form with no `preset` names the fallback profile.
  @Test func theOldMapFormWithNoPresetNamesTheFallback() throws {
    let loaded = try Self.load(Self.oldMapDocument)

    #expect(loaded.configuration.profile.name == Self.mediumName)
  }

  /// The old map form with no `preset` keeps its warnings: each key is no
  /// longer used.
  @Test func theOldMapFormWithNoPresetWarnsOfEachKey() throws {
    let loaded = try Self.load(Self.oldMapDocument)

    #expect(
      loaded.warnings == [
        .retiredKey(section: "profile", key: "flash"),
        .retiredKey(section: "profile", key: "standard"),
      ])
  }

  /// A `null` profile selects the fallback profile.
  @Test func aNullProfileSelectsTheFallback() throws {
    let loaded = try Self.load(Self.nullProfileDocument)

    #expect(loaded.configuration.profile.definition.name == Self.mediumName)
  }

  /// The composition over a fit source where only `small` fits starts
  /// with `small` for the old map form with no `preset`.
  @Test func theCompositionStartsWithTheChoiceForTheOldMapForm() async throws {
    let workspace = makeResolvedDirectory(label: "OldProfileMapFallback-compose-repo")
    let projectDirectory = workspace.appendingPathComponent(
      ".\(Self.agentName)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectDirectory, withIntermediateDirectories: true)
    try Self.oldMapDocument.write(
      to: projectDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
      atomically: true, encoding: .utf8)

    let composed = try await composeStubAgent(
      name: Self.agentName, label: "OldProfileMapFallback-compose", workspace: workspace,
      profileFitSource: ProfileFitStub(fitting: [BundledProfiles.smallestName]))

    #expect(composed.configuration.profile.name == BundledProfiles.smallestName)
  }
}
