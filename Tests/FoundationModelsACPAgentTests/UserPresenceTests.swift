import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsMultitool

/// The user presence of a session (elicitation-plan task 7). The agent
/// decides it when it opens the session, from the client capabilities of
/// `initialize` and from the bound connection, and gives it to Router. In a
/// headless session, a question ends at once with cancel, so it never waits
/// for a user who is not there.
@Suite(.closesHarnesses) struct UserPresenceTests {
  /// The presence of the Router session of the fixture's one session.
  ///
  /// - Parameter fixture: The wired fixture.
  /// - Returns: The presence of its run plane.
  /// - Throws: When the session is missing.
  private static func presence(of fixture: ScriptedPromptFixture) async throws -> UserPresence? {
    let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
    return runPlanePresence(of: session)
  }

  /// A client that answers elicitations gets an interactive session: a
  /// question of a tool goes to the client.
  @Test
  func aClientThatAnswersElicitationsGetsAnInteractiveSession() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "UserPresenceTests-interactive")
    let presence = try await Self.presence(of: fixture)
    await fixture.close()

    #expect(presence == .interactive)
  }

  /// A client with no elicitation capability gets a headless session.
  @Test
  func aClientWithNoElicitationCapabilityGetsAHeadlessSession() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "UserPresenceTests-no-capability",
      capabilities: ClientCapabilities())
    let presence = try await Self.presence(of: fixture)
    await fixture.close()

    #expect(presence == .headless)
  }

  /// An agent with no bound ACP client connection opens headless sessions:
  /// no relay is wired, so no user can answer (elicitation-plan task 7).
  /// The client capabilities of its `initialize` do not change that.
  @Test
  func anAgentWithNoBoundConnectionOpensAHeadlessSession() async throws {
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "UserPresenceTests-unbound-cache"),
      loader: makeScriptedModelLoader(script: [.endPass]))
    _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
    let response = try await agent.newSession(
      NewSessionRequest(
        cwd: AbsolutePath(rawValue: makeResolvedDirectory(label: "UserPresenceTests-unbound").path))
    )
    let session = try #require(await agent.sessions[response.sessionId]?.session)
    let presence = runPlanePresence(of: session)
    _ = try await agent.closeSession(CloseSessionRequest(sessionId: response.sessionId))

    #expect(presence == .headless)
  }

  // MARK: - session/resume

  /// Records a session with a client of `recordedWith`, then resumes it in
  /// a new agent with a client of `resumedWith`, over the same working
  /// directory, and reads the recorded and the resumed session with
  /// `projection`.
  ///
  /// - Parameters:
  ///   - recordedWith: The capabilities of the client that records.
  ///   - resumedWith: The capabilities of the client that resumes.
  ///   - label: The directory label of the proof.
  ///   - projectConfigYAML: The project `config.yaml` to write under the
  ///     working directory, or `nil` (the default) for none.
  ///   - projection: What to read of a session, given the agent that holds
  ///     it and its id.
  /// - Returns: The reading of the recorded session and of the resumed one.
  /// - Throws: Whatever the fixtures, the prompt, the resume or the
  ///   projection throws.
  private static func recordAndResume<Reading>(
    recordedWith: ClientCapabilities, resumedWith: ClientCapabilities, label: String,
    projectConfigYAML: String? = nil,
    projection: (RoutedACPAgent, SessionId) async throws -> Reading
  ) async throws -> (recorded: Reading, resumed: Reading) {
    let first = try await ScriptedPromptFixture.make(
      script: [.textDelta("recorded"), .endPass], label: label, capabilities: recordedWith,
      projectConfigYAML: projectConfigYAML)
    try await ScriptedPromptFixture.runPrompt(on: first, text: "record this session")
    let recorded = try await projection(first.harness.agent, first.sessionId)
    let sessionId = first.sessionId
    let resumed = try await first.closeAndResume(
      makeSecond: {
        try await ScriptedPromptFixture.make(
          script: [.endPass], label: "\(label)-second", capabilities: resumedWith,
          workingDirectory: $0)
      },
      read: { second, _ in try await projection(second.harness.agent, sessionId) })
    return (recorded, resumed)
  }

  /// The presence of the run plane of the session `sessionId`.
  ///
  /// - Parameters:
  ///   - agent: The agent that holds the session.
  ///   - sessionId: The session.
  /// - Returns: The presence of its run plane.
  /// - Throws: When the session is missing.
  private static func presence(
    of agent: RoutedACPAgent, sessionId: SessionId
  ) async throws -> UserPresence? {
    let session = try #require(await agent.sessions[sessionId]?.session)
    return runPlanePresence(of: session)
  }

  /// A session recorded by an interactive client and resumed by a client
  /// with no elicitation capability is headless: the resume gives the
  /// presence of the client of now, not the recorded one.
  @Test
  func aSessionRecordedInteractiveAndResumedWithNoElicitationIsHeadless() async throws {
    let presences = try await Self.recordAndResume(
      recordedWith: ACPClient.advertisedCapabilities, resumedWith: ClientCapabilities(),
      label: "UserPresenceTests-resume-headless", projection: Self.presence(of:sessionId:))

    #expect(presences.recorded == .interactive)
    #expect(presences.resumed == .headless)
  }

  /// The reverse: a session recorded by a client with no elicitation
  /// capability and resumed by an interactive client is interactive.
  @Test
  func aSessionRecordedHeadlessAndResumedByAnInteractiveClientIsInteractive() async throws {
    let presences = try await Self.recordAndResume(
      recordedWith: ClientCapabilities(), resumedWith: ACPClient.advertisedCapabilities,
      label: "UserPresenceTests-resume-interactive", projection: Self.presence(of:sessionId:))

    #expect(presences.recorded == .headless)
    #expect(presences.resumed == .interactive)
  }

  // MARK: - The MCP servers of a session

  /// The project `config.yaml` that mounts one stdio MCP server, the
  /// `mcp-test-server` in echo mode. A project config, so a resumed
  /// session over the same directory mounts it too.
  ///
  /// - Returns: The YAML document.
  /// - Throws: The locator error.
  private static func mcpConfigYAML() throws -> String {
    let command = try BuiltProductLocator.mcpTestServerURL().path
    return """
      tools:
        mcp:
          - name: presence
            command: \(command)
            args:
              - --mode
              - echo
      """
  }

  /// The user presence of each MCP server of the session `sessionId`.
  ///
  /// - Parameters:
  ///   - agent: The agent that holds the session.
  ///   - sessionId: The session.
  /// - Returns: The presence of each server, in mount order.
  /// - Throws: When the session is missing.
  private static func mcpPresences(
    of agent: RoutedACPAgent, sessionId: SessionId
  ) async throws -> [UserPresence] {
    let servers = try #require(await agent.sessions[sessionId]?.surface.mcpServers)
    var presences: [UserPresence] = []
    for server in servers {
      presences.append(await server.userPresence)
    }
    return presences
  }

  /// The MCP servers of a session get the presence of the session: a
  /// client with no elicitation capability gives headless servers, and an
  /// interactive client gives interactive servers. A resume by the other
  /// kind of client gives the presence of that client.
  @Test(arguments: [
    (
      ClientCapabilities(), ACPClient.advertisedCapabilities, UserPresence.headless,
      UserPresence.interactive
    ),
    (
      ACPClient.advertisedCapabilities, ClientCapabilities(), UserPresence.interactive,
      UserPresence.headless
    ),
  ])
  func theMCPServersOfASessionGetItsPresenceAlsoAfterResume(
    recordedWith: ClientCapabilities, resumedWith: ClientCapabilities,
    recordedPresence: UserPresence, resumedPresence: UserPresence
  ) async throws {
    let presences = try await Self.recordAndResume(
      recordedWith: recordedWith, resumedWith: resumedWith,
      label: "UserPresenceTests-mcp-\(recordedPresence)",
      projectConfigYAML: try Self.mcpConfigYAML(), projection: Self.mcpPresences(of:sessionId:))

    #expect(presences.recorded == [recordedPresence])
    #expect(presences.resumed == [resumedPresence])
  }
}
