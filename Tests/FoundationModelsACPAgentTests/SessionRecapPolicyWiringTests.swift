import Foundation
import FoundationModelsACPAgentTestSupport
import Testing
import ULID

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The agent gives the `sessions.recap` setting to the Router session
/// directory as its recap policy (D206).
///
/// The directory asks the policy for the working folder of a session at the
/// end of each turn, and gives no recap target when the policy is off. The
/// recap waits 20 seconds of idle time on a clock that a test cannot reach,
/// so each test reads the recap target of a new live session
/// (`RouterSessionDirectory.recapTarget(of:)`) and does not wait for a recap.
@Suite(.closesHarnesses) struct SessionRecapPolicyWiringTests {
  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionRecapPolicyWiringTests"

  /// A folder level that turns the recap off.
  private static let recapOffYAML = "sessions:\n  recap: false\n"

  /// Opens one new session in `cwd`, and tells if the directory gives it a
  /// recap target.
  ///
  /// - Parameters:
  ///   - agent: The initialized agent.
  ///   - cwd: The working directory of the session.
  /// - Returns: `true` when the directory gives the session a recap target.
  /// - Throws: What `session/new` throws, or a failed requirement when the
  ///   session id is not a ULID.
  private static func hasRecapTarget(on agent: RoutedACPAgent, in cwd: URL) async throws -> Bool {
    let response = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))
    let id = try #require(ULID(ulidString: response.sessionId.rawValue))
    return agent.sessionDirectory.recapTarget(of: id) != nil
  }

  /// A session in a folder with no `sessions.recap` setting gets a recap
  /// target: the policy is on by default.
  @Test func aSessionInAFolderWithNoSettingGetsARecapTarget() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-on")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-on-repo")

    #expect(try await Self.hasRecapTarget(on: agent, in: cwd) == true)
  }

  /// A session in a folder whose level turns the recap off gets no recap
  /// target.
  @Test func aSessionInAFolderThatTurnsTheRecapOffGetsNoRecapTarget() async throws {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: "\(Self.label)-off")
    let cwd = makeResolvedDirectory(label: "\(Self.label)-off-repo")
    let folderRoot = try #require(
      SettingsFoldersFixture.layerRoot(
        of: .project, in: agent.settingsFolders, workingDirectory: cwd))
    try ConfigFileFixture.write(Self.recapOffYAML, in: folderRoot)

    #expect(try await Self.hasRecapTarget(on: agent, in: cwd) == false)
  }
}
