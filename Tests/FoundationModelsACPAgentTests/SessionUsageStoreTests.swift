import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The Pinned and Recent lists of the server (D118 (e), D184): the agent
/// gives the session directory a usage store in the state of this machine
/// (``AgentHome/sessionUsageFile``), and the `sessions` endpoint reads it.
@Suite struct SessionUsageStoreTests {
  /// The fields of a session in the lists.
  private static let fields = "{ id pinned lastUsedAt }"

  /// An agent over `home`, initialized.
  private static func agent(label: String, home: AgentHome) async throws -> ComposedAgent {
    let composed = try await composeStubAgent(name: "SessionUsageStoreTests", label: label, home: home)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    return composed
  }

  /// Opens a new session in a new folder.
  private static func open(on composed: ComposedAgent, label: String) async throws -> (
    id: SessionId, folder: URL
  ) {
    let folder = makeResolvedDirectory(label: label)
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId
    return (id, folder)
  }

  /// Runs a document on the `sessions` endpoint of the agent.
  private static func run(_ composed: ComposedAgent, _ document: String) async throws -> GraphQLReply {
    let endpoint = SessionsGraph.endpoint(of: composed.agent.sessionDirectory)
    return try GraphQLReply(
      try await endpoint.execute(query: document, variables: [:], operationName: nil, viewer: nil))
  }

  /// The ids of a list of the `sessions` endpoint.
  private static func ids(_ composed: ComposedAgent, _ list: String) async throws -> [String] {
    let reply = try await run(composed, "{ \(list) \(fields) }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
    let items = try #require(reply.data?[list.components(separatedBy: "(")[0]] as? [[String: Any]])
    return items.compactMap { $0["id"] as? String }
  }

  /// Pins a session through the `sessions` endpoint.
  private static func pin(_ composed: ComposedAgent, _ id: SessionId) async throws {
    let reply = try await run(
      composed, "mutation { pinSession(input: {id: \"\(id.rawValue)\"}) \(fields) }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
  }

  /// The usage file is `sessions/usage.json` in the state of this machine.
  @Test func theUsageFileIsInTheLocalState() {
    let home = AgentHomeFixture.make(label: "SessionUsageStoreTests-path")

    #expect(home.sessionUsageFile.deletingLastPathComponent().deletingLastPathComponent() == home.local)
    #expect(home.sessionUsageFile.lastPathComponent == "usage.json")
  }

  /// A pin shows in pinnedSessions, and the open of a session shows in
  /// recentSessions, the last used first.
  @Test func aPinAndAnOpenShowInTheLists() async throws {
    let home = AgentHomeFixture.make(label: "SessionUsageStoreTests-lists")
    let composed = try await Self.agent(label: "SessionUsageStoreTests-lists", home: home)
    let first = try await Self.open(on: composed, label: "SessionUsageStoreTests-lists-a")
    let second = try await Self.open(on: composed, label: "SessionUsageStoreTests-lists-b")
    try await Self.pin(composed, first.id)
    _ = try await composed.agent.closeSession(CloseSessionRequest(sessionId: first.id))
    _ = try await composed.agent.resumeSession(
      ResumeSessionRequest(cwd: AbsolutePath(rawValue: first.folder.path), sessionId: first.id))

    let pinned = try await Self.ids(composed, "pinnedSessions")
    let recent = try await Self.ids(composed, "recentSessions")
    await composed.closeOpenSessions()

    #expect(pinned == [first.id.rawValue])
    // The Recent list has no pinned session (D118 (c)).
    #expect(recent == [second.id.rawValue])
    #expect(FileManager.default.fileExists(atPath: home.sessionUsageFile.path))
  }

  /// The Recent list gives the last used session first.
  @Test func theRecentListGivesTheLastUsedFirst() async throws {
    let home = AgentHomeFixture.make(label: "SessionUsageStoreTests-order")
    let composed = try await Self.agent(label: "SessionUsageStoreTests-order", home: home)
    let first = try await Self.open(on: composed, label: "SessionUsageStoreTests-order-a")
    let second = try await Self.open(on: composed, label: "SessionUsageStoreTests-order-b")
    _ = try await composed.agent.closeSession(CloseSessionRequest(sessionId: first.id))
    _ = try await composed.agent.resumeSession(
      ResumeSessionRequest(cwd: AbsolutePath(rawValue: first.folder.path), sessionId: first.id))

    let recent = try await Self.ids(composed, "recentSessions")
    await composed.closeOpenSessions()

    #expect(recent == [first.id.rawValue, second.id.rawValue])
  }

  /// A pin survives a new agent over the same home.
  @Test func aPinSurvivesANewAgent() async throws {
    let home = AgentHomeFixture.make(label: "SessionUsageStoreTests-keep")
    let before = try await Self.agent(label: "SessionUsageStoreTests-keep-1", home: home)
    let session = try await Self.open(on: before, label: "SessionUsageStoreTests-keep-cwd")
    try await Self.pin(before, session.id)
    await before.closeOpenSessions()

    let after = try await Self.agent(label: "SessionUsageStoreTests-keep-2", home: home)
    let pinned = try await Self.ids(after, "pinnedSessions")
    await after.closeOpenSessions()

    #expect(pinned == [session.id.rawValue])
  }

  /// Two homes do not share their pins.
  @Test func twoHomesDoNotSharePins() async throws {
    let pinnedHome = AgentHomeFixture.make(label: "SessionUsageStoreTests-home-a")
    let otherHome = AgentHomeFixture.make(label: "SessionUsageStoreTests-home-b")
    let pinner = try await Self.agent(label: "SessionUsageStoreTests-home-a", home: pinnedHome)
    let session = try await Self.open(on: pinner, label: "SessionUsageStoreTests-home-cwd")
    try await Self.pin(pinner, session.id)
    await pinner.closeOpenSessions()

    let other = try await Self.agent(label: "SessionUsageStoreTests-home-b", home: otherHome)
    let pinned = try await Self.ids(other, "pinnedSessions")
    await other.closeOpenSessions()

    #expect(pinned.isEmpty)
  }
}
