import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The profile files on the `models` endpoint: `Query.profiles` names the
/// layer of each profile, and `saveProfile` and `deleteProfile` change the
/// files through the profile store. A child agent run cannot change them
/// (D193).
@Suite struct ModelsGraphProfileFileTests {
  /// The text of a `saveProfile` mutation of a user profile `custom`.
  private static let saveUserDocument = """
    mutation { saveProfile(name: "custom", profile: {standard: ["mlx-community/Qwen3-4B-4bit"]}, \
    layer: USER) { name layer } }
    """

  /// The text of a `deleteProfile` mutation of the user profile `custom`.
  private static let deleteUserDocument = """
    mutation { deleteProfile(name: "custom", layer: USER) }
    """

  /// An endpoint over a settings fixture, whose calls run in a child agent
  /// run or not.
  ///
  /// - Parameters:
  ///   - fixture: The settings fixture.
  ///   - isChildRun: Whether each call runs in a child agent run.
  /// - Returns: The endpoint.
  private static func graph(_ fixture: SettingsGraphFixture, isChildRun: Bool = false) -> ModelsGraph {
    ModelsGraph(
      store: fixture.store, storage: ModelsGraphTests.builtinStorage(),
      profiles: ProfileStore(settingsFolders: fixture.store.settingsFolders),
      isChildRun: { isChildRun })
  }

  /// The profile files of the fixture.
  ///
  /// - Parameter fixture: The settings fixture.
  /// - Returns: The layers.
  private static func layers(_ fixture: SettingsGraphFixture) -> ProfileLayers {
    ProfileLayers(settingsFolders: fixture.store.settingsFolders)
  }

  /// The layer of each profile row, by name.
  ///
  /// - Parameter graph: The endpoint.
  /// - Returns: The layers.
  private static func rowLayers(_ graph: ModelsGraph) async throws -> [String: String] {
    let reply = try await ModelsGraphTests.run(graph, "{ profiles { name layer } }")
    let rows = try #require(reply.data?["profiles"] as? [[String: Any]], "\(reply.text)")
    return Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        (row["name"] as? String).map { ($0, row["layer"] as? String ?? "") }
      })
  }

  // MARK: - Query.profiles

  /// Each bundled profile has the layer BUNDLED.
  @Test func eachBundledProfileHasTheBundledLayer() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-bundled")

    let layers = try await Self.rowLayers(Self.graph(fixture))

    #expect(layers == ["large": "BUNDLED", "medium": "BUNDLED", "small": "BUNDLED"])
  }

  // MARK: - saveProfile

  /// A save writes the user file, and the profile has the layer USER.
  @Test func aSaveWritesTheUserProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-save")
    let graph = Self.graph(fixture)

    let reply = try await ModelsGraphTests.run(graph, Self.saveUserDocument)

    #expect(reply.codes.isEmpty, "\(reply.text)")
    #expect(try Self.layers(fixture).read("custom", cwd: nil).standard == ["mlx-community/Qwen3-4B-4bit"])
    #expect(try await Self.rowLayers(graph)["custom"] == "USER")
  }

  /// A save of a profile with an unknown key is refused, and writes no
  /// file.
  @Test func aSaveOfAnUnknownKeyIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-unknown")

    let reply = try await ModelsGraphTests.run(
      Self.graph(fixture),
      #"mutation { saveProfile(name: "custom", profile: {slots: []}, layer: USER) { name } }"#)

    #expect(reply.codes == ["INVALID_PROFILE"])
    #expect(!Self.layers(fixture).names(cwd: nil).contains("custom"))
  }

  /// A save to the bundled layer is refused: the bundled profiles are
  /// read-only.
  @Test func aSaveToTheBundledLayerIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-bundled-save")

    let reply = try await ModelsGraphTests.run(
      Self.graph(fixture),
      #"mutation { saveProfile(name: "large", profile: {}, layer: BUNDLED) { name } }"#)

    #expect(reply.codes == ["READ_ONLY"])
  }

  /// A save to the project layer with no working directory is refused.
  @Test func aProjectSaveWithNoWorkingDirectoryIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-no-cwd")

    let reply = try await ModelsGraphTests.run(
      Self.graph(fixture),
      #"mutation { saveProfile(name: "custom", profile: {}, layer: PROJECT) { name } }"#)

    #expect(reply.codes == ["MISSING_CWD"])
  }

  /// A save in a child agent run is refused, and writes no file.
  @Test func aChildRunCannotSaveAProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-child-save")

    let reply = try await ModelsGraphTests.run(
      Self.graph(fixture, isChildRun: true), Self.saveUserDocument)

    #expect(reply.codes == [ChildAgentRun.refusalCode])
    #expect(!Self.layers(fixture).names(cwd: nil).contains("custom"))
  }

  // MARK: - deleteProfile

  /// A delete removes the user file.
  @Test func aDeleteRemovesTheUserProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-delete")
    let graph = Self.graph(fixture)
    _ = try await ModelsGraphTests.run(graph, Self.saveUserDocument)

    let reply = try await ModelsGraphTests.run(graph, Self.deleteUserDocument)

    #expect(reply.data?["deleteProfile"] as? Bool == true, "\(reply.text)")
    #expect(!Self.layers(fixture).names(cwd: nil).contains("custom"))
  }

  /// A delete of a profile that the layer has no file of is refused.
  @Test func aDeleteWithNoFileIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-delete-none")

    let reply = try await ModelsGraphTests.run(Self.graph(fixture), Self.deleteUserDocument)

    #expect(reply.codes == ["NO_PROFILE_FILE"])
  }

  /// A delete in a child agent run is refused, and the file stays.
  @Test func aChildRunCannotDeleteAProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-child-delete")
    _ = try await ModelsGraphTests.run(Self.graph(fixture), Self.saveUserDocument)

    let reply = try await ModelsGraphTests.run(
      Self.graph(fixture, isChildRun: true), Self.deleteUserDocument)

    #expect(reply.codes == [ChildAgentRun.refusalCode])
    #expect(Self.layers(fixture).names(cwd: nil).contains("custom"))
  }

  // MARK: - Changes

  /// A save gives a PROFILE change that applies at the next launch.
  @Test func aSaveGivesAProfileChange() async throws {
    let fixture = try SettingsGraphFixture(label: "models-files-change")
    let graph = Self.graph(fixture)
    var events = try await graph.subscribe(
      query: ModelsGraphTests.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    _ = try await ModelsGraphTests.run(graph, Self.saveUserDocument)

    let change = try await ModelsGraphTests.next(&events)
    #expect(change["reason"] as? String == "PROFILE")
    #expect(change["appliesAt"] as? String == "NEXT_LAUNCH")
  }
}
