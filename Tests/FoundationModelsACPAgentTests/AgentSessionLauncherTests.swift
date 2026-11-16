import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The launcher of the session directory of the agent (ROUTER-8, ACPA-9
/// Step 2): `restoreSession(id:)` makes a recorded root session live with no
/// client, and `launchRootSession(for:)` waits for Step 7.
@Suite struct AgentSessionLauncherTests {
  /// The label of the stub agent and of its directories.
  private static let label = "AgentSessionLauncherTests"

  /// Composes a stub agent, runs `initialize`, opens one session in a new
  /// folder, and closes it, so that only its recording stays.
  ///
  /// - Parameter label: The label of the agent and of its directories.
  /// - Returns: The composition, the id of the recorded session, and its
  ///   folder.
  /// - Throws: Whatever the composition or a request throws.
  private static func recordedSession(
    label: String
  ) async throws -> (composed: ComposedAgent, id: SessionId, folder: URL) {
    let composed = try await composeStubAgent(name: Self.label, label: label)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let folder = makeResolvedDirectory(label: "\(label)-cwd")
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId
    _ = try await composed.agent.closeSession(CloseSessionRequest(sessionId: id))
    return (composed, id, folder)
  }

  /// The ULID of a wire session id.
  private static func ulid(_ id: SessionId) throws -> ULID {
    try #require(ULID(ulidString: id.rawValue))
  }

  /// A recorded root session that is not live comes back live, in the
  /// session table of the agent. The launcher takes the session for no
  /// connection: the owner record stays as it was.
  @Test func aRecordedSessionRestoresLiveAndKeepsItsOwnerRecord() async throws {
    let recorded = try await Self.recordedSession(label: "\(Self.label)-cold")
    let launcher = AgentSessionLauncher(agent: recorded.composed.agent)
    let ownerBefore = await recorded.composed.agent.connections.owner(of: recorded.id)

    let session = try await launcher.restoreSession(id: try Self.ulid(recorded.id))
    let entry = await recorded.composed.agent.liveRoot(recorded.id)
    let owner = await recorded.composed.agent.connections.owner(of: recorded.id)
    await recorded.composed.closeOpenSessions()

    #expect(session.id == (try Self.ulid(recorded.id)))
    #expect(entry != nil)
    #expect(entry?.workingDirectory.standardizedFileURL == recorded.folder.standardizedFileURL)
    #expect(owner == ownerBefore)
  }

  /// A session that is live already comes back as it is: no second entry.
  @Test func aLiveSessionComesBackAsItIs() async throws {
    let recorded = try await Self.recordedSession(label: "\(Self.label)-live")
    let launcher = AgentSessionLauncher(agent: recorded.composed.agent)
    let first = try await launcher.restoreSession(id: try Self.ulid(recorded.id))

    let second = try await launcher.restoreSession(id: try Self.ulid(recorded.id))
    await recorded.composed.closeOpenSessions()

    #expect((first as AnyObject) === (second as AnyObject))
  }

  /// A client takes a session that the launcher restored, with the hot
  /// resume of a live root.
  @Test func aClientTakesARestoredSession() async throws {
    let recorded = try await Self.recordedSession(label: "\(Self.label)-take")
    let launcher = AgentSessionLauncher(agent: recorded.composed.agent)
    let restored = try await launcher.restoreSession(id: try Self.ulid(recorded.id))

    _ = try await recorded.composed.agent.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: recorded.folder.path), sessionId: recorded.id))
    let after = await recorded.composed.agent.liveRoot(recorded.id)?.session
    await recorded.composed.closeOpenSessions()

    #expect((after as AnyObject?) === (restored as AnyObject))
  }

  /// An id that names no recorded session gives `unknownSession`.
  @Test func anUnknownIdIsRefused() async throws {
    let recorded = try await Self.recordedSession(label: "\(Self.label)-unknown")
    let launcher = AgentSessionLauncher(agent: recorded.composed.agent)
    let unknown = ULID()

    await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
      _ = try await launcher.restoreSession(id: unknown)
    }
    await recorded.composed.closeOpenSessions()
  }

  /// The start of a new root session waits for ACPA-9 Step 7.
  @Test func theLaunchOfARootSessionIsNotAvailableYet() async throws {
    let recorded = try await Self.recordedSession(label: "\(Self.label)-launch")
    let launcher = AgentSessionLauncher(agent: recorded.composed.agent)

    await #expect(throws: SessionDirectoryError.noLauncher) {
      _ = try await launcher.launchRootSession(
        for: SessionStartRequest(firstMessage: "hello", origin: .tool))
    }
    await recorded.composed.closeOpenSessions()
  }
}
