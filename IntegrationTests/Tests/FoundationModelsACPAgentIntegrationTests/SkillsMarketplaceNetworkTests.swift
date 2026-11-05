import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - The shipped skills marketplace list reaches GitHub
//
// The shipped `tools.skills.marketplaces` list names the `main` branch of the
// `swissarmyhammer/skills` repository on GitHub, and a session start fetches
// each marketplace into the cache folder of the home of the agent.
//
// The suites of this package must be offline and repeatable. Thus the unit
// suite `SkillsMarketplaceTests` proves that a session of the stub agent
// reads no marketplace, and this suite proves the shipped list one time on
// purpose, over the network. The agent runs in this process: no process is
// the subject.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The marketplace fetch of a session that reads the shipped list.
struct SkillsMarketplaceNetworkTests {
  // MARK: - Constants

  /// The user-layer `config.yaml`. The code context is off, because this
  /// suite does not need it and it makes a session start slower. The skills
  /// marketplace list is not set, so the shipped list stays.
  private static let userConfigYAML = "tools:\n  codeContext: false\n"

  // MARK: - The drive

  /// Composes the stub agent over the shipped configuration, with no offline
  /// defaults layer, and opens one session over an in-memory wire. The
  /// session start fetches the marketplaces. Then the wire comes down.
  ///
  /// - Parameter home: The home of the agent. Its user layer holds
  ///   ``userConfigYAML``, and its cache folder receives the fetch.
  /// - Throws: Whatever the composition, the handshake or the session call
  ///   throws.
  private static func startOneSession(in home: AgentHome) async throws {
    let workspace = makeResolvedDirectory(label: "SkillsMarketplaceNetwork-repo")
    let composed = try await ComposedAgent.compose(
      name: DotfolderName(TierThreeFixture.agentDotfolderName),
      workingDirectory: workspace,
      home: home,
      environment: [TierThreeFixture.defaultsDirectoryVariable: TierThreeFixture.noDefaultsLayerValue],
      modelSource: .stub)
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await composed.serve(over: agentEnd)
    let model = await ConnectionModel()
    let connection = await model.connect(over: clientEnd)
    // Swift has no asynchronous `defer`, and the wire must come down on
    // the failing path as well, so the outcome is held here and given
    // back after the teardown.
    let outcome: Result<Void, any Error>
    do {
      _ = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
      _ = try await connection.newSession(
        NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
      outcome = .success(())
    } catch {
      outcome = .failure(error)
    }
    await connection.close()
    await agentConnection.close()
    clientEnd.close()
    agentEnd.close()
    await composed.waitForConnectionTeardown()
    await composed.closeOpenSessions()
    try outcome.get()
  }

  // MARK: - The contract

  /// The shipped marketplace list reaches GitHub. This test uses the
  /// network on purpose: it is the one test of this package that proves
  /// the default marketplace path.
  ///
  /// An empty ``TierThreeFixture/noDefaultsLayerValue`` removes the offline
  /// defaults layer, so the agent reads the shipped list. The session start
  /// fetches a snapshot of the `swissarmyhammer/skills` repository into the
  /// cache folder of the home.
  @Test
  func theShippedMarketplaceListFetchesTheGitHubSkillsRepositoryOverTheNetwork() async throws {
    let home = AgentHomeFixture.make(label: "SkillsMarketplaceNetwork")
    try ConfigFileFixture.write(Self.userConfigYAML, in: home.synced)

    try await Self.startOneSession(in: home)

    let fetched = try FileManager.default.contentsOfDirectory(
      atPath: home.skillsMarketplaceCacheDirectory.path)
    #expect(!fetched.isEmpty, "the cache folder holds no fetch")
  }
}
