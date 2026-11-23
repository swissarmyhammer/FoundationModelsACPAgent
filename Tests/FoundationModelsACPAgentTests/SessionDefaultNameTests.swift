import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The default name of a new root session (user decision of 2026-11-23,
/// which replaces D199 (b)): the last folder name of its working folder,
/// as it is written (`SessionName.default(folder:usedNames:)`). The agent
/// of the session does not change the name, so each test here has another
/// agent and gets the same rule.
///
/// Each test opens its sessions with `session/new` on a stub agent over
/// throwaway folders, and reads the name from the Router session directory.
@Suite(.closesHarnesses) struct SessionDefaultNameTests {
  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionDefaultNameTests"

  /// The `name` of the default agent: the root `AGENT.md` of the user layer.
  private static let defaultAgentName = "Default Helper"

  /// The name that the host gives the agent.
  private static let hostAgentName = "Testudo"

  /// The default name of the first session in `cwd`.
  ///
  /// - Parameter cwd: The working directory of the session.
  /// - Returns: The last folder name of `cwd`.
  private static func folderName(of cwd: URL) -> String {
    SessionName.default(folder: cwd, usedNames: [])
  }

  /// Opens one new session in `cwd` and gives its name.
  ///
  /// - Parameters:
  ///   - agent: The initialized agent.
  ///   - cwd: The working directory of the session.
  /// - Returns: The title of the session in the Router session directory.
  /// - Throws: What `session/new` or the directory read throws.
  private static func nameOfNewSession(on agent: RoutedACPAgent, in cwd: URL) async throws
    -> String?
  {
    let response = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))
    let id = try #require(ULID(ulidString: response.sessionId.rawValue))
    return try await agent.sessionDirectory.summary(of: id)?.title
  }

  /// Makes an initialized stub agent whose default agent is the root
  /// `AGENT.md` of its user layer, with the name ``defaultAgentName``.
  ///
  /// - Parameter test: The name of the test, for the folder labels.
  /// - Returns: The agent.
  /// - Throws: What the write or the agent throws.
  private static func makeAgentWithNamedDefaultAgent(test: String) async throws -> RoutedACPAgent {
    let userDirectory = makeResolvedDirectory(label: "\(label)-\(test)-user")
    try AgentFolderFixture.writeAgent(named: defaultAgentName, in: userDirectory)
    return try await AgentClientHarness.makeInitializedAgent(
      label: "\(label)-\(test)", userDirectory: userDirectory)
  }

  /// A new session of a named default agent gets the last folder name of
  /// its working folder, not the name of the agent.
  @Test func aSessionOfTheDefaultAgentGetsTheNameOfItsFolder() async throws {
    let agent = try await Self.makeAgentWithNamedDefaultAgent(test: "first")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-first-repo")

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == Self.folderName(of: cwd))
  }

  /// A second new session in the same folder gets the name of the folder
  /// with the number 2.
  @Test func aSecondSessionOfTheAgentInTheSameFolderGetsTheNextNumber() async throws {
    let agent = try await Self.makeAgentWithNamedDefaultAgent(test: "second")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-second-repo")
    _ = try await Self.nameOfNewSession(on: agent, in: cwd)

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == "\(Self.folderName(of: cwd))-2")
  }

  /// A session of the `AGENT.md` of its working directory gets the last
  /// folder name, not the `name` of that file.
  @Test func aSessionOfAnAgentMdGetsTheNameOfItsFolder() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-folder")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-folder-repo")
    try AgentFolderFixture.writeAgent(named: AgentFolderFixture.sampleAgentName, in: cwd)

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == Self.folderName(of: cwd))
  }

  /// A session of the builtin default agent with a host name gets the
  /// last folder name, not the name that the host gives the agent.
  @Test func aSessionOfTheBuiltinAgentWithAHostNameGetsTheNameOfItsFolder() async throws {
    let composed = try await composeStubAgent(
      name: Self.label, label: "\(Self.label)-host", agentName: Self.hostAgentName)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let cwd = makeResolvedDirectory(label: "\(Self.label)-host-repo")

    let name = try await Self.nameOfNewSession(on: composed.agent, in: cwd)
    await composed.closeOpenSessions()

    #expect(name == Self.folderName(of: cwd))
  }

  /// A session of the builtin default agent with no host name gets the
  /// last folder name, not the id of the default agent.
  @Test func aSessionOfTheBuiltinAgentWithNoHostNameGetsTheNameOfItsFolder() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-floor")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-floor-repo")

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == Self.folderName(of: cwd))
  }
}
