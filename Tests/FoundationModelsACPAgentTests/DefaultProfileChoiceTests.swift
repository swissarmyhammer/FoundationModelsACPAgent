import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The choice of the default profile (D203): the largest bundled profile
/// whose fit says that it fits, else `small`. The same choice is the
/// fallback of a `profile` name that no layer has.
@Suite struct DefaultProfileChoiceTests {
  /// The name of the bundled profile `medium`.
  private static let mediumName = "medium"

  /// The dotfolder name of the agents of this suite.
  private static let agentName = "default-profile-choice"

  /// Where only `small` fits, the choice is `small`.
  @Test func onlySmallFitsSelectsSmall() async {
    let name = await BundledProfiles.fallbackName(
      using: ProfileFitStub(fitting: [BundledProfiles.smallestName]))

    #expect(name == BundledProfiles.smallestName)
  }

  /// Where `medium` and `small` fit, the choice is `medium`.
  @Test func mediumAndSmallFitSelectsMedium() async {
    let name = await BundledProfiles.fallbackName(
      using: ProfileFitStub(fitting: [Self.mediumName, BundledProfiles.smallestName]))

    #expect(name == Self.mediumName)
  }

  /// Where each profile fits, the choice is the first name, `large`.
  @Test func eachFitSelectsTheLargest() async {
    let name = await BundledProfiles.fallbackName(using: ProfileFitStub.allFit)

    #expect(name == BundledProfiles.names.first)
  }

  /// Where the source fails for each profile, the choice is `small`.
  @Test func aFailedSourceSelectsSmall() async {
    let name = await BundledProfiles.fallbackName(using: ProfileFitStub.noneFit)

    #expect(name == BundledProfiles.smallestName)
  }

  /// With no source, no fit can be read, and the choice is `small`.
  @Test func noSourceSelectsSmall() async {
    let name = await BundledProfiles.fallbackName(using: nil)

    #expect(name == BundledProfiles.smallestName)
  }

  /// In a cancelled task, the choice is `small`, also when each profile
  /// fits.
  @Test func aCancelledChoiceSelectsSmall() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await BundledProfiles.fallbackName(using: ProfileFitStub.allFit)
    }

    #expect(await task.value == BundledProfiles.smallestName)
  }

  /// A load where no layer sets `profile` uses the profile of the choice,
  /// and the configuration names it.
  @Test func aLoadWithNoProfileKeyUsesTheChoice() throws {
    let fixture = ConfigurationLoaderTests.Fixture()

    let loaded = try fixture.makeLoader(fallbackProfileName: Self.mediumName).load()

    #expect(loaded.configuration.profile.name == Self.mediumName)
  }

  /// A load where no layer sets `profile` reads the profile file of the
  /// choice.
  @Test func aLoadWithNoProfileKeyReadsTheProfileOfTheChoice() throws {
    let fixture = ConfigurationLoaderTests.Fixture()

    let loaded = try fixture.makeLoader(fallbackProfileName: Self.mediumName).load()

    #expect(loaded.configuration.profile.definition.name == Self.mediumName)
  }

  /// A load of a name that no layer has uses the profile of the choice.
  @Test func anUnknownNameUsesTheChoice() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(
      "profile: \(ConfigurationLoaderTests.unknownProfileName)\n", in: fixture.userDirectory)

    let loaded = try fixture.makeLoader(fallbackProfileName: Self.mediumName).load()

    #expect(loaded.configuration.profile.definition.name == Self.mediumName)
  }

  /// A load where a layer sets `profile` keeps that profile.
  @Test func aProfileKeyWinsOverTheChoice() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig("profile: \(BundledProfiles.smallestName)\n", in: fixture.userDirectory)

    let loaded = try fixture.makeLoader(fallbackProfileName: Self.mediumName).load()

    #expect(loaded.configuration.profile.definition.name == BundledProfiles.smallestName)
  }

  /// The merge of the settings store where no level sets `profile` uses
  /// the profile of the choice of the store.
  @Test func theSettingsStoreUsesItsChoice() async throws {
    let settingsFolders = try SettingsFoldersFixture.make(label: "DefaultProfileChoice-store")
    let store = SettingsStore(
      settingsFolders: settingsFolders, secretStore: InMemorySecretStore(),
      fallbackProfileName: Self.mediumName)

    let merged = try await store.merged(
      for: makeResolvedDirectory(label: "DefaultProfileChoice-store-cwd"))

    #expect(merged.configuration.profile.definition.name == Self.mediumName)
  }

  /// The composition with a fit source where only `small` fits starts
  /// with `small`.
  @Test func theCompositionStartsWithTheChoice() async throws {
    let composed = try await composeStubAgent(
      name: Self.agentName, label: "DefaultProfileChoice-compose",
      profileFitSource: ProfileFitStub(fitting: [BundledProfiles.smallestName]))

    #expect(composed.configuration.profile.name == BundledProfiles.smallestName)
  }

  /// The composition gives its choice to the settings store, thus each
  /// session loads with the same choice.
  @Test func theCompositionGivesTheChoiceToTheSessions() async throws {
    let composed = try await composeStubAgent(
      name: Self.agentName, label: "DefaultProfileChoice-compose-store",
      profileFitSource: ProfileFitStub(fitting: [BundledProfiles.smallestName]))

    #expect(composed.agent.settingsStore.fallbackProfileName == BundledProfiles.smallestName)
  }

  /// An agent with no choice of its host chooses with its router: the stub
  /// machine fits `large`.
  @Test func anAgentChoosesWithItsRouter() async throws {
    let agent = try await makeStubAgent(
      name: Self.agentName,
      cacheDirectory: makeResolvedDirectory(label: "DefaultProfileChoice-agent-cache"))

    #expect(agent.settingsStore.fallbackProfileName == BundledProfiles.names.first)
  }

  /// A store with no choice uses `small`, the choice when no fit can be
  /// read.
  @Test func aStoreWithNoChoiceUsesSmall() throws {
    let settingsFolders = try SettingsFoldersFixture.make(label: "DefaultProfileChoice-nochoice")

    let store = SettingsStore(settingsFolders: settingsFolders, secretStore: InMemorySecretStore())

    #expect(store.fallbackProfileName == BundledProfiles.smallestName)
  }
}
