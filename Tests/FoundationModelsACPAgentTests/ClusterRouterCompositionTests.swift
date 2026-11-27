import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCluster
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `cluster:` section reaches the Router (task ^j1vfmkf): the composition reads the section
/// of the user level before it builds the Router, and gives its mode and options to the Router
/// and to the live loader. The session level is ignored, and the stub path ignores the section.
///
/// No test asks the network and no test loads a model: the live Router is only built.
@Suite struct ClusterRouterCompositionTests {
  // MARK: - Constants

  /// The label of the throwaway folders of the suite.
  private static let label = "ClusterRouterCompositionTests"

  /// A host name of the section.
  private static let host = "m5u2.local"

  /// The `config.yaml` text of an enabled section with each key.
  private static let enabledYAML = """
    cluster:
      enabled: true
      hosts: [\(host)]
      policy: always
      workerDirectory: /tmp/fmcluster
    """

  /// The Keychain reference of the password of ``passwordLoginYAML``.
  private static let passwordReference = "cluster-password"

  /// The `config.yaml` text of an enabled password login, whose password is a Keychain
  /// reference.
  private static let passwordLoginYAML = """
    cluster:
      enabled: true
      user: ml
      password: keychain:\(passwordReference)
    """

  /// The path of stored properties from a `Router` to its loader.
  private static let loaderPath = ["loader"]

  // MARK: - Helpers

  /// The enabled section of ``enabledYAML``.
  ///
  /// - Returns: The section.
  /// - Throws: The parse or the decode error.
  private static func enabledSection() throws -> ClusterConfiguration {
    try ClusterYAML.cluster(of: enabledYAML)
  }

  /// The live Router of a section, as the composition makes it.
  ///
  /// - Parameters:
  ///   - cluster: The section.
  ///   - modelSource: The model path.
  /// - Returns: The Router.
  /// - Throws: The error of the construction.
  private static func makeRouter(
    cluster: ClusterConfiguration, modelSource: ComposedAgent.ModelSource = .live
  ) throws -> Router {
    try ComposedAgent.makeRouter(
      for: modelSource, home: AgentHomeFixture.make(label: label), huggingFaceTokenProvider: .environment,
      cluster: cluster)
  }

  /// The fit source of the CLI over the user level that `loader` reads, as `config show` and
  /// `doctor` make it.
  ///
  /// - Parameters:
  ///   - loader: The configuration loader.
  ///   - modelSource: The model path.
  /// - Returns: The fit source.
  private static func makeFitSource(
    userLevelOf loader: ConfigurationLoader, modelSource: ComposedAgent.ModelSource = .live
  ) -> any ProfileFitEstimating {
    ComposedAgent.makeProfileFitSource(
      for: modelSource, home: AgentHomeFixture.make(label: label),
      huggingFaceTokenProvider: .environment, userLevelOf: loader)
  }

  /// The folder of a worker source of a folder.
  ///
  /// - Parameter source: The worker source.
  /// - Returns: The path, or `nil` for a bundled source.
  private static func directoryPath(of source: WorkerSource) -> String? {
    guard case .directory(let directory) = source else {
      return nil
    }
    return directory.path
  }

  // MARK: - The user level

  /// The section of the user level is the section that the loader reads for the Router.
  @Test func theUserLevelSectionIsRead() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.enabledYAML, in: fixture.userDirectory)

    #expect(try fixture.makeLoader().loadUserCluster() == Self.enabledSection())
  }

  /// The section of the session level of a folder does not reach the Router.
  @Test func theSessionLevelSectionIsIgnored() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.enabledYAML, in: fixture.projectDirectory)

    #expect(try fixture.makeLoader().loadUserCluster() == ClusterConfiguration())
  }

  /// A key that the section does not have is an error of the read of the user level.
  @Test func anUnknownKeyOfTheUserLevelIsAnError() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig("cluster:\n  passphrase: secret\n", in: fixture.userDirectory)

    #expect(
      throws: ConfigurationError.unknownKey(
        section: ClusterConfiguration.sectionKey, key: "passphrase")
    ) {
      try fixture.makeLoader().loadUserCluster()
    }
  }

  // MARK: - The Router

  /// The live Router of an enabled section has the mode of the section.
  @Test func theLiveRouterHasTheModeOfTheSection() throws {
    let section = try Self.enabledSection()

    #expect(try Self.makeRouter(cluster: section).cluster == section.mode)
  }

  /// The live Router of an enabled section has the hosts of the section.
  @Test func theLiveRouterHasTheHostsOfTheSection() throws {
    #expect(try Self.makeRouter(cluster: Self.enabledSection()).clusterOptions.hosts == [Self.host])
  }

  /// The live Router of an enabled section has the policy of the section.
  @Test func theLiveRouterHasThePolicyOfTheSection() throws {
    #expect(try Self.makeRouter(cluster: Self.enabledSection()).clusterOptions.policy == .always)
  }

  /// The live Router of an enabled section has the worker folder of the section.
  @Test func theLiveRouterHasTheWorkerFolderOfTheSection() throws {
    let router = try Self.makeRouter(cluster: Self.enabledSection())

    #expect(Self.directoryPath(of: router.clusterOptions.workerSource) == "/tmp/fmcluster")
  }

  /// The live loader of the Router gets the same mode as the Router.
  @Test func theLiveLoaderHasTheModeOfTheSection() throws {
    let section = try Self.enabledSection()
    let router = try Self.makeRouter(cluster: section)

    let loader = try #require(
      Mirror(reflecting: router).descendant(Self.loaderPath[0]) as? LiveModelLoader)
    #expect(try loader.cluster == section.mode)
  }

  /// The stub Router ignores the section.
  @Test func theStubRouterIgnoresTheSection() throws {
    let router = try Self.makeRouter(cluster: Self.enabledSection(), modelSource: .stub)

    #expect(router.cluster == .off)
  }

  // MARK: - The composition

  /// The Router of the composition has the mode of the section of the user level that the
  /// loader reads.
  @Test func theRouterOfTheCompositionHasTheModeOfTheUserLevel() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.enabledYAML, in: fixture.userDirectory)
    let loader = try fixture.makeLoader()

    let router = try ComposedAgent.makeRouter(
      for: .live, home: AgentHomeFixture.make(label: Self.label),
      huggingFaceTokenProvider: .environment, userLevelOf: loader)

    #expect(try router.cluster == Self.enabledSection().mode)
  }

  // MARK: - The fit source

  /// The Router of the fit source of `config show` and `doctor` has the mode of the section of
  /// the user level, as the Router of the composition has.
  @Test func theRouterOfTheFitSourceHasTheModeOfTheUserLevel() async throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.enabledYAML, in: fixture.userDirectory)
    let source = Self.makeFitSource(userLevelOf: try fixture.makeLoader())

    let router = try await #require(source as? DeferredRouterFitSource).router()
    #expect(try router.cluster == Self.enabledSection().mode)
  }

  /// Making the fit source reads no Keychain item: the section is read at the first fit,
  /// because a Keychain read can prompt the person.
  @Test func makingTheFitSourceReadsNoSecret() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.passwordLoginYAML, in: fixture.userDirectory)
    let store = CountingSecretStore()

    _ = Self.makeFitSource(userLevelOf: try fixture.makeLoader(secretStore: store))

    #expect(store.reads.count == 0)
  }

  /// A fit reads the section of the user level: a password with no value in the Keychain gives
  /// a report that does not fit, with the error of the section as its failure.
  @Test func aSectionThatDoesNotLoadGivesNoFit() async throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.passwordLoginYAML, in: fixture.userDirectory)
    let source = Self.makeFitSource(
      userLevelOf: try fixture.makeLoader(secretStore: InMemorySecretStore([:])), modelSource: .stub)
    let profile = try #require(BundledProfiles.all.first)

    let unresolved = ConfigurationError.unresolvedSecret(
      keyPath: "cluster.password", reference: Self.passwordReference)
    #expect(await source.fitReport(of: profile).failure == String(describing: unresolved))
  }
}
