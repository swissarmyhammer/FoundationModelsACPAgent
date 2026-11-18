import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The default name of a new root session (D199 (b), task ^r9prwh9). The
/// agent gives Router the agent of the session when it makes the session:
/// the catalog id and the name of the agent. Router makes the default name
/// from the name of the agent, else from the id.
///
/// Each test opens its sessions with `session/new` on a stub agent over
/// throwaway folders, and reads the name from the Router session directory.
@Suite(.closesHarnesses) struct SessionDefaultNameTests {
  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionDefaultNameTests"

  /// The `name` of the default agent: the root `AGENT.md` of the user layer.
  private static let defaultAgentName = "Default Helper"

  /// The default name that ``defaultAgentName`` gives.
  private static let defaultAgentSlug = "default-helper"

  /// The name that the host gives the agent.
  private static let hostAgentName = "Testudo"

  /// The default name that ``hostAgentName`` gives.
  private static let hostAgentSlug = "testudo"

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

  /// A new session of the default agent gets the name of that agent.
  @Test func aSessionOfTheDefaultAgentGetsTheNameOfTheAgent() async throws {
    let agent = try await Self.makeAgentWithNamedDefaultAgent(test: "first")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-first-repo")

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == Self.defaultAgentSlug)
  }

  /// A second new session of the same agent in the same folder gets the
  /// name of the agent with the number 2.
  @Test func aSecondSessionOfTheAgentInTheSameFolderGetsTheNextNumber() async throws {
    let agent = try await Self.makeAgentWithNamedDefaultAgent(test: "second")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-second-repo")
    _ = try await Self.nameOfNewSession(on: agent, in: cwd)

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == "\(Self.defaultAgentSlug)-2")
  }

  /// A session of the `AGENT.md` of its working directory gets the `name`
  /// of that file.
  @Test func aSessionOfAnAgentMdGetsItsName() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-folder")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-folder-repo")
    try AgentFolderFixture.writeAgent(named: AgentFolderFixture.sampleAgentName, in: cwd)

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == AgentFolderFixture.sampleAgentSlug)
  }

  /// A session of the builtin default agent gets the name that the host
  /// gives the agent.
  @Test func aSessionOfTheBuiltinAgentGetsTheNameOfTheHost() async throws {
    let composed = try await composeStubAgent(
      name: Self.label, label: "\(Self.label)-host", agentName: Self.hostAgentName)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let cwd = makeResolvedDirectory(label: "\(Self.label)-host-repo")

    let name = try await Self.nameOfNewSession(on: composed.agent, in: cwd)
    await composed.closeOpenSessions()

    #expect(name == Self.hostAgentSlug)
  }

  /// A session of the builtin default agent with no host name gets the id
  /// of the default agent, not the fallback name of `SessionName`.
  @Test func aSessionOfTheBuiltinAgentWithNoHostNameGetsTheDefaultID() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-floor")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-floor-repo")

    let name = try await Self.nameOfNewSession(on: agent, in: cwd)

    #expect(name == AgentCatalog.defaultAgentID)
  }
}
