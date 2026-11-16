import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `sessions` tool of each session and the record of the use of a
/// session (ACPA-9 Step 2, D118, D184).
///
/// Each session gets a top-level `sessions` tool over the session directory
/// of the agent, thus the session gives the `sessions` GraphQL endpoint: the
/// Pinned and Recent lists of the server. When a client opens a session
/// with `session/new` or `session/resume`, the agent records the use of the
/// session in the directory.
@Suite struct SessionsToolMountTests {
  /// The label of the stub agent and of its directories.
  private static let label = "SessionsToolMountTests"

  /// The name of the `sessions` tool and of its endpoint.
  private static let sessionsName = "sessions"

  /// Composes a stub agent and runs `initialize`.
  ///
  /// - Parameter label: The label of the agent and of its directories.
  /// - Returns: The composition.
  /// - Throws: Whatever the composition or the handshake throws.
  private static func composeAgent(label: String) async throws -> ComposedAgent {
    let composed = try await composeStubAgent(name: Self.label, label: label)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    return composed
  }

  /// Opens a new session in a new folder.
  ///
  /// - Parameters:
  ///   - composed: The composed agent.
  ///   - label: The label of the folder.
  /// - Returns: The id of the session and its folder.
  /// - Throws: Whatever `session/new` throws.
  private static func openSession(
    on composed: ComposedAgent, label: String
  ) async throws -> (id: SessionId, folder: URL) {
    let folder = makeResolvedDirectory(label: label)
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId
    return (id, folder)
  }

  // MARK: - The tool and the endpoint

  /// A new session has a top-level `sessions` tool, and its surface gives
  /// the `sessions` endpoint.
  @Test func aNewSessionHasTheSessionsToolAndItsEndpoint() async throws {
    let composed = try await Self.composeAgent(label: "\(Self.label)-tool")
    let session = try await Self.openSession(on: composed, label: "\(Self.label)-tool-cwd")

    let surface = await composed.agent.sessions[session.id]?.surface
    await composed.closeOpenSessions()

    #expect(surface?.tools.contains { $0.name == Self.sessionsName } == true)
    #expect(surface?.graphQLEndpoints.contains { $0.name == Self.sessionsName } == true)
  }

  /// Two sessions of one agent share one `sessions` endpoint instance, thus
  /// one cursor sequence.
  @Test func twoSessionsShareOneSessionsEndpoint() async throws {
    let composed = try await Self.composeAgent(label: "\(Self.label)-shared")
    let first = try await Self.openSession(on: composed, label: "\(Self.label)-shared-a")
    let second = try await Self.openSession(on: composed, label: "\(Self.label)-shared-b")

    let firstEndpoint = await composed.agent.sessions[first.id]?.surface.graphQLEndpoints
      .first { $0.name == Self.sessionsName }
    let secondEndpoint = await composed.agent.sessions[second.id]?.surface.graphQLEndpoints
      .first { $0.name == Self.sessionsName }
    await composed.closeOpenSessions()

    let a = try #require(firstEndpoint as? AnyObject)
    let b = try #require(secondEndpoint as? AnyObject)
    #expect(a === b)
  }

  /// The endpoint answers the queries of the Pinned and Recent lists.
  @Test func theEndpointAnswersThePinnedAndRecentQueries() async throws {
    let composed = try await Self.composeAgent(label: "\(Self.label)-query")
    let session = try await Self.openSession(on: composed, label: "\(Self.label)-query-cwd")
    let endpoint = try #require(
      await composed.agent.sessions[session.id]?.surface.graphQLEndpoints
        .first { $0.name == Self.sessionsName })

    let reply = try await endpoint.execute(
      query: "{ pinnedSessions { id pinned } recentSessions { id lastUsedAt } }",
      variables: [:], operationName: nil, viewer: nil)
    await composed.closeOpenSessions()

    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    #expect(object["errors"] == nil, "\(reply)")
    let data = try #require(object["data"] as? [String: Any])
    #expect(data["pinnedSessions"] is [Any])
    #expect(data["recentSessions"] is [Any])
  }

  // MARK: - The use of a session

  /// `session/new` and `session/resume` each record one use of the
  /// session, by its id.
  @Test func newAndResumeEachRecordTheUseOfTheSession() async throws {
    let composed = try await Self.composeAgent(label: "\(Self.label)-use")
    let recorded = UseLog()
    await composed.agent.useSessionUseRecorder { id in await recorded.append(id) }

    let session = try await Self.openSession(on: composed, label: "\(Self.label)-use-cwd")
    let afterNew = await recorded.ids
    _ = try await composed.agent.closeSession(CloseSessionRequest(sessionId: session.id))
    _ = try await composed.agent.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: session.folder.path), sessionId: session.id))
    let afterResume = await recorded.ids
    await composed.closeOpenSessions()

    let id = try #require(ULID(ulidString: session.id.rawValue))
    #expect(afterNew == [id])
    #expect(afterResume == [id, id])
  }

  /// A failure of the record does not stop the open of the session.
  @Test func aFailedRecordDoesNotStopTheOpen() async throws {
    let composed = try await Self.composeAgent(label: "\(Self.label)-fail")
    await composed.agent.useSessionUseRecorder { id in
      throw SessionDirectoryError.unknownSession(id)
    }

    let session = try await Self.openSession(on: composed, label: "\(Self.label)-fail-cwd")
    let isOpen = await composed.agent.sessions[session.id] != nil
    await composed.closeOpenSessions()

    #expect(isOpen)
  }
}

/// The ids that a test recorder got, in order.
private actor UseLog {
  /// The recorded ids.
  private(set) var ids: [ULID] = []

  /// Records one id.
  ///
  /// - Parameter id: The id of the used session.
  func append(_ id: ULID) {
    ids.append(id)
  }
}
