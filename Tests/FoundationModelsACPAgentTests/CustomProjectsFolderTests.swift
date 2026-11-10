import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The projects folder that a host gives to
/// `AgentHome.makeCustom(synced:local:projects:)` (ACPA-16).
///
/// The case composes the agent over the stub model, as an in-process host
/// does, with a projects folder that is not in the synced root. It drives
/// the agent from the client end of the harness, and reads the project
/// store from disk.
@Suite(.closesHarnesses) struct CustomProjectsFolderTests {
  /// The dotfolder name of the host in this suite.
  private static let dotfolderName = "custom-projects-host"

  /// The directory label of the suite.
  private static let label = "CustomProjectsFolderTests"

  /// The text of the one prompt of the session. The first prompt writes
  /// the index record, and a session with no prompt is not listable.
  private static let promptText = "record this session"

  /// A session in a home whose projects folder is outside the synced root
  /// registers its project in that folder and not in
  /// `<synced>/projects/`, and the cross-project `session/list` reads the
  /// project from that folder.
  @Test
  func aSessionRegistersAndListsItsProjectInTheGivenFolder() async throws {
    let synced = makeResolvedDirectory(label: "\(Self.label)-synced")
    let projects = makeResolvedDirectory(label: "\(Self.label)-projects")
    let workspace = makeResolvedDirectory(label: "\(Self.label)-repo")
    let composed = try await ComposedAgent.compose(
      name: DotfolderName(Self.dotfolderName),
      workingDirectory: workspace,
      home: AgentHomeFixture.make(label: Self.label, synced: synced, projects: projects),
      environment: try StubAgentDefaultsLayer.makeEnvironment(name: Self.dotfolderName, base: [:]),
      modelSource: .stub)
    let harness = await AgentClientHarness.makeRecording(agent: composed.agent)
    _ = try await harness.client.initialize(AgentClientHarness.makeInitializeRequest())

    let sessionId = try await Self.recordOneSession(in: workspace, through: harness)
    _ = try await harness.connection.closeSession(CloseSessionRequest(sessionId: sessionId))
    let list = try await harness.connection.listSessions(ListSessionsRequest())
    await harness.close()

    #expect(
      try ProjectStore(directory: projects).projects().map(\.path)
        == [workspace.standardizedFileURL.path])
    #expect(
      !FileManager.default.fileExists(
        atPath: synced.appendingPathComponent(AgentHomeFixture.projectsFolderName).path))
    #expect(list.sessions.map(\.sessionId) == [sessionId])
  }

  /// Opens one session in `workspace`, sends one prompt, and waits until
  /// the session journal is on disk.
  ///
  /// - Parameters:
  ///   - workspace: The working directory of the session.
  ///   - harness: The initialized harness.
  /// - Returns: The session id.
  /// - Throws: Whatever the wire calls or the wait throw.
  private static func recordOneSession(
    in workspace: URL, through harness: AgentClientHarness
  ) async throws -> SessionId {
    let session = try await harness.client.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
    let sessionId = await MainActor.run { session.sessionId }
    try await ScriptedPromptFixture.runPrompt(
      AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText),
      through: harness)
    try await ResumeSessionFixture.waitForJournal(of: sessionId, in: harness.agent)
    return sessionId
  }
}
