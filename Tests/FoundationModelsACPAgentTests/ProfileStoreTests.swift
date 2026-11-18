import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The profile store: the profile files of the project layer, the user layer
/// and the bundled resources, the first layer that has a name wins.
@Suite struct ProfileStoreTests {
  /// The folders of one test: a working directory with its project layer,
  /// and a user layer.
  struct Fixture {
    /// The folders of the configuration.
    let folders = ConfigurationLoaderTests.Fixture()

    /// The settings folders over ``folders``.
    let settingsFolders: SettingsFolders

    /// Makes the folders.
    ///
    /// - Throws: `DotfolderNameError`.
    init() throws {
      settingsFolders = SettingsFolders(
        name: try DotfolderName(ConfigurationLoaderTests.agentName),
        home: AgentHomeFixture.make(label: "ProfileStoreTests", synced: folders.userDirectory),
        environment: [:])
    }

    /// The working directory of the project layer.
    var cwd: URL { folders.workingDirectory }

    /// The profiles folder of the user layer.
    var userProfiles: URL {
      folders.userDirectory.appendingPathComponent(ProfileFile.folderName, isDirectory: true)
    }

    /// The profiles folder of the project layer.
    var projectProfiles: URL {
      folders.projectDirectory.appendingPathComponent(ProfileFile.folderName, isDirectory: true)
    }

    /// The layers of the profiles.
    var layers: ProfileLayers { ProfileLayers(settingsFolders: settingsFolders) }

    /// Writes one profile file.
    ///
    /// - Parameters:
    ///   - text: The text of the file.
    ///   - name: The name of the profile.
    ///   - folder: The profiles folder.
    func write(_ text: String, named name: String, in folder: URL) throws {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try text.write(
        to: folder.appendingPathComponent("\(name).\(ProfileFile.fileExtension)"), atomically: true,
        encoding: .utf8)
    }
  }

  /// The text of a profile file that names one `standard` model.
  private static let customText = "standard:\n  - mlx-community/Qwen3-4B-4bit\n"

  // MARK: - list and read

  /// With no file in a layer, the list is the bundled profiles.
  @Test func theListIsTheBundledProfilesWithNoFile() throws {
    let entries = try Fixture().layers.list(cwd: nil)

    #expect(entries.map(\.name) == ["large", "medium", "small"])
    #expect(entries.map(\.layer) == [.bundled, .bundled, .bundled])
  }

  /// A user file with the hidden flag of macOS is in the list. iCloud sets
  /// that flag on each file of a synced `~/.config`; only a dotfile is
  /// hidden.
  @Test func aUserFileWithTheHiddenFlagIsInTheList() throws {
    let fixture = try Fixture()
    try fixture.write(Self.customText, named: "custom", in: fixture.userProfiles)
    var file = fixture.userProfiles.appendingPathComponent("custom.\(ProfileFile.fileExtension)")
    var values = URLResourceValues()
    values.isHidden = true
    try file.setResourceValues(values)
    try #require(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)

    #expect(fixture.layers.list(cwd: nil).contains { $0.name == "custom" && $0.layer == .user })
  }

  /// A dotfile in a profiles folder is not a profile.
  @Test func aDotfileIsNotInTheList() throws {
    let fixture = try Fixture()
    try fixture.write(Self.customText, named: ".custom", in: fixture.userProfiles)

    #expect(!fixture.layers.list(cwd: nil).contains { $0.name == ".custom" })
  }

  /// A user file with a new name is in the list, at the user layer.
  @Test func aUserFileIsInTheList() throws {
    let fixture = try Fixture()
    try fixture.write(Self.customText, named: "custom", in: fixture.userProfiles)

    let entry = fixture.layers.list(cwd: nil).first { $0.name == "custom" }

    #expect(entry?.layer == .user)
  }

  /// A project file wins over a user file and a bundled file of the same
  /// name, as a whole file.
  @Test func theProjectFileWinsOverTheUserAndBundledFiles() throws {
    let fixture = try Fixture()
    try fixture.write("description: user\n", named: "large", in: fixture.userProfiles)
    try fixture.write("description: project\n", named: "large", in: fixture.projectProfiles)

    let entry = fixture.layers.list(cwd: fixture.cwd).first { $0.name == "large" }

    #expect(entry?.layer == .project)
    #expect(try fixture.layers.read("large", cwd: fixture.cwd).description == "project")
  }

  /// A read of a name that no layer has is an error that lists each name.
  @Test func anUnknownNameIsAnErrorThatListsTheNames() throws {
    let layers = try Fixture().layers
    #expect(throws: ProfileStoreError.unknownProfile(name: "huge", available: ["large", "medium", "small"])) {
      try layers.read("huge", cwd: nil)
    }
  }

  /// A read of a bad file throws the error of the file.
  @Test func aBadFileThrowsTheErrorOfTheFile() throws {
    let fixture = try Fixture()
    try fixture.write("slots: []\n", named: "custom", in: fixture.userProfiles)

    #expect(throws: ProfileFileError.self) { try fixture.layers.read("custom", cwd: nil) }
  }

  /// A bad file is in the list, with its error.
  @Test func aBadFileIsInTheListWithItsError() throws {
    let fixture = try Fixture()
    try fixture.write("slots: []\n", named: "custom", in: fixture.userProfiles)

    let entry = fixture.layers.list(cwd: nil).first { $0.name == "custom" }

    #expect(entry?.error != nil)
  }

  // MARK: - save and delete

  /// A save to the user level writes a file that the next read gives.
  @Test func aSaveWritesTheUserFile() async throws {
    let fixture = try Fixture()
    let store = ProfileStore(settingsFolders: fixture.settingsFolders)

    try await store.save(text: Self.customText, as: "custom", level: .user)

    #expect(try fixture.layers.read("custom", cwd: nil).standard == ["mlx-community/Qwen3-4B-4bit"])
  }

  /// A save to the session level writes the project file.
  @Test func aSaveWritesTheProjectFile() async throws {
    let fixture = try Fixture()
    let store = ProfileStore(settingsFolders: fixture.settingsFolders)

    try await store.save(text: Self.customText, as: "custom", level: .session(fixture.cwd))

    #expect(fixture.layers.list(cwd: fixture.cwd).first { $0.name == "custom" }?.layer == .project)
  }

  /// A save of a text that does not decode writes nothing.
  @Test func aSaveOfABadTextWritesNothing() async throws {
    let fixture = try Fixture()
    let store = ProfileStore(settingsFolders: fixture.settingsFolders)

    await #expect(throws: ProfileFileError.self) {
      try await store.save(text: "slots: []\n", as: "custom", level: .user)
    }
    #expect(!fixture.layers.list(cwd: nil).contains { $0.name == "custom" })
  }

  /// A name that is not a plain file name is refused.
  @Test func aNameWithAPathIsRefused() async throws {
    let store = ProfileStore(settingsFolders: try Fixture().settingsFolders)

    await #expect(throws: ProfileStoreError.invalidName("../custom")) {
      try await store.save(text: Self.customText, as: "../custom", level: .user)
    }
  }

  /// A save of a profile value writes its text.
  @Test func aSaveOfAProfileWritesItsText() async throws {
    let fixture = try Fixture()
    let store = ProfileStore(settingsFolders: fixture.settingsFolders)
    let small = try #require(BundledProfiles.named("small"))

    try await store.save(small, as: "copy", level: .user)

    #expect(try fixture.layers.read("copy", cwd: nil).standard == small.standard)
  }

  /// A delete of the user file that overrides a bundled profile brings the
  /// bundled profile back.
  @Test func aDeleteBringsTheBundledProfileBack() async throws {
    let fixture = try Fixture()
    let store = ProfileStore(settingsFolders: fixture.settingsFolders)
    try await store.save(text: "description: mine\n", as: "large", level: .user)

    try await store.delete("large", level: .user)

    #expect(fixture.layers.list(cwd: nil).first { $0.name == "large" }?.layer == .bundled)
  }

  /// A delete of a name that the level has no file of is an error.
  @Test func aDeleteWithNoFileIsAnError() async throws {
    let store = ProfileStore(settingsFolders: try Fixture().settingsFolders)

    await #expect(throws: ProfileStoreError.noProfileFile(name: "large", layer: .user)) {
      try await store.delete("large", level: .user)
    }
  }

  // MARK: - Changes

  /// A save sends a change that names the profile and the level.
  @Test func aSaveSendsAChange() async throws {
    let store = ProfileStore(settingsFolders: try Fixture().settingsFolders)
    let changes = await store.changes()

    try await store.save(text: Self.customText, as: "custom", level: .user)

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == ProfileChange(level: .user, name: "custom"))
  }

  /// A delete sends a change that names the profile and the level.
  @Test func aDeleteSendsAChange() async throws {
    let store = ProfileStore(settingsFolders: try Fixture().settingsFolders)
    try await store.save(text: Self.customText, as: "custom", level: .user)
    let changes = await store.changes()

    try await store.delete("custom", level: .user)

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == ProfileChange(level: .user, name: "custom"))
  }
}
