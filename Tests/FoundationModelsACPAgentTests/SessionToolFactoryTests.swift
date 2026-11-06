import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsKanban
import GraphQL
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The seam that gives the tools of each session (`SessionToolFactory`), and
/// the `kanban` tool that the `acp-agent` executable mounts through it.
@Suite(.closesHarnesses) struct SessionToolFactoryTests {
  /// The name of the tool that the probe factories make.
  private static let probeToolName = "factory_probe"

  /// A factory runs once for each session, with the working directory of the
  /// session, the name of the agent, and a tag that differs for each
  /// session. Its tool is on the surface of the session, after the tools of
  /// the catalog.
  @Test
  func aFactoryRunsOnceForEachSessionWithItsContext() async throws {
    let agent = try await Self.makeAgent(label: "factory-context")
    let seen = WatchedValue<[SessionToolContext]>([])
    await agent.registerSessionToolFactories([
      { context in
        seen.update { $0.append(context) }
        return [FactoryProbeTool()]
      }
    ])
    let harness = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
    let first = makeResolvedDirectory(label: "factory-context-first")
    let second = makeResolvedDirectory(label: "factory-context-second")

    let firstSession = try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: first)).sessionId
    _ = try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: second))

    let contexts = seen.value
    #expect(contexts.map { $0.workingDirectory.path } == [first.path, second.path])
    #expect(contexts.allSatisfy { $0.agentName == AgentClientHarness.dotfolderName })
    #expect(Set(contexts.map(\.sessionTag)).count == contexts.count)
    #expect(contexts.allSatisfy { $0.sessionTag.count == SessionToolContext.sessionTagLength })
    let names = await agent.sessions[firstSession]?.surface.tools.map(\.name) ?? []
    #expect(names.last == Self.probeToolName)
  }

  /// A factory that throws fails `session/new`.
  @Test
  func aFactoryThatThrowsFailsTheNewSession() async throws {
    let agent = try await Self.makeAgent(label: "factory-throws")
    await agent.registerSessionToolFactories([{ _ in throw FactoryFailure() }])
    let harness = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())

    await #expect(throws: (any Error).self) {
      _ = try await harness.connection.newSession(
        AgentClientHarness.makeNewSessionRequest(cwd: makeResolvedDirectory(label: "factory-throws")))
    }
  }

  /// A session of the executable composition has a `kanban` endpoint in the
  /// tunnel.
  @Test
  func aSessionHasAKanbanEndpointInTheTunnel() async throws {
    let fixture = try await KanbanFixture.make(label: "kanban-endpoint", sessions: 1)

    let list = try await fixture.device.connection.callExtensionMethod(
      SAH.GraphQL.Method.endpoints, SAH.GraphQL.EndpointsRequest(),
      returning: SAH.GraphQL.EndpointsResponse.self)

    #expect(list.endpoints.map(\.name).contains("kanban"))
  }

  /// The model writes with the actor of its session; a tunnel write of a
  /// `userDevice` connection that claimed a person records that person.
  @Test
  func theModelRecordsTheAgentAndTheTunnelRecordsTheClaimedPerson() async throws {
    let fixture = try await KanbanFixture.make(label: "kanban-actors", sessions: 1)
    let session = fixture.sessions[0]

    _ = try await fixture.modelWrite("first", in: session)
    _ = try await fixture.tunnelWrite("second", in: session)

    let history = try await fixture.history(in: session)
    #expect(history.count == 2)
    let modelActor = try #require(history.last?.actor)
    let personActor = try #require(history.first?.actor)
    #expect(modelActor.contains(fixture.agentName.lowercased()))
    #expect(personActor != modelActor)
    #expect(personActor.contains("abc"))
  }

  /// Two sessions in one folder write, and `undoChange(input: {})` in the
  /// first session reverses only the change of the first session.
  @Test
  func anUndoInOneSessionDoesNotReverseTheChangeOfAnotherSession() async throws {
    let fixture = try await KanbanFixture.make(label: "kanban-undo", sessions: 2)
    let (first, second) = (fixture.sessions[0], fixture.sessions[1])
    _ = try await fixture.modelWrite("from first", in: first)
    _ = try await fixture.modelWrite("from second", in: second)

    let before = try await fixture.history(in: first)
    #expect(Set(before.map(\.actor)).count == before.count, "the two sessions share one actor")

    _ = try await fixture.modelExecute("mutation { undoChange(input: {}) { txn } }", in: first)

    let history = try await fixture.history(in: first)
    let undone = history.filter { $0.undone }
    #expect(undone.count == 1)
    let firstActor = try await fixture.actorOfOldestWrite(in: first)
    #expect(undone.first?.actor == firstActor)
  }

  /// A closed session lets the view of the board go. The factory holds
  /// nothing: only the tool of the session holds the graph (the cycles of
  /// `e9dfc6a` kept an object of a closed session alive).
  @Test
  func aClosedSessionReleasesItsKanbanGraph() async throws {
    let watch: WeakReferenceWatch<KanbanGraph>
    do {
      let fixture = try await KanbanFixture.make(label: "kanban-release", sessions: 1)
      let tools = await fixture.agent.sessions[fixture.sessions[0]]?.surface.tools ?? []
      let graph = try #require(
        tools.compactMap { $0 as? any GraphQLEndpointTool }.flatMap(\.graphQLEndpoints)
          .compactMap { $0 as? KanbanGraph }.first)
      watch = WeakReferenceWatch(watching: graph)
      _ = try await fixture.device.connection.closeSession(
        CloseSessionRequest(sessionId: fixture.sessions[0]))
      await fixture.device.close()
    }
    #expect(try await watch.waitForRelease(), "something still holds the graph of the session")
  }

  /// The tag of a session is recorded with it, and read back: the recorded
  /// tag first, and the start of the id for a session with no record.
  @Test
  func theTagOfASessionIsRecordedAndReadBack() throws {
    let root = makeResolvedDirectory(label: "SessionToolFactoryTests-tag-store")
    let recorded = SessionId(rawValue: "01M6RW6ZN35W68ZBBMDQSCMJYS")
    let unrecorded = SessionId(rawValue: "01M6RW73DVDTTTJTNC5VF5GZDG")

    try SessionTagStore.record("ABCD1234", for: recorded, in: root)

    #expect(SessionTagStore.tag(of: recorded, in: root) == "ABCD1234")
    #expect(
      SessionTagStore.tag(of: unrecorded, in: root)
        == String(unrecorded.rawValue.prefix(SessionToolContext.sessionTagLength)))
  }

  /// Makes a stub agent with the executable factory of the `kanban` tool,
  /// or with none.
  fileprivate static func makeAgent(label: String) async throws -> RoutedACPAgent {
    try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "SessionToolFactoryTests-\(label)-cache"))
  }
}

/// A failure of a test factory.
private struct FactoryFailure: Error {}

/// A tool that a probe factory makes.
private struct FactoryProbeTool: FoundationModels.Tool {
  let name = "factory_probe"
  let description = "A tool that a test factory makes."

  @Generable
  struct Arguments {}

  func call(arguments _: Arguments) async throws -> String { "ok" }
}

/// One agent with the executable factory of the `kanban` tool, one
/// `userDevice` connection that claimed a person, and some sessions in one
/// folder.
private struct KanbanFixture {
  /// The connection that claimed a person.
  let device: AgentClientHarness

  /// The agent.
  let agent: RoutedACPAgent

  /// The sessions, all in one folder.
  let sessions: [SessionId]

  /// The name of the agent.
  var agentName: String { AgentClientHarness.dotfolderName }

  /// Makes the fixture.
  static func make(label: String, sessions count: Int) async throws -> KanbanFixture {
    let agent = try await SessionToolFactoryTests.makeAgent(label: label)
    await agent.registerSessionToolFactories([AgentComposition.kanbanToolFactory])
    let claimed = GraphQLActor(id: "icloud/ABC", name: "Pat Person")
    let plain = AgentClientHarness.makeInitializeRequest()
    let claiming = InitializeRequest(
      info: plain.info, protocolVersion: plain.protocolVersion, capabilities: plain.capabilities,
      meta: .object([GraphQLActor.initializeMetaKey: try claimed.metaValue(as: JSONValue.self)]))
    let device = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await device.connection.initialize(claiming)
    let folder = makeResolvedDirectory(label: "SessionToolFactoryTests-\(label)-folder")
    let ids = try await openSessions(count, on: device, in: folder)
    return KanbanFixture(device: device, agent: agent, sessions: ids)
  }

  /// Opens `count` sessions in one folder, one after the other.
  ///
  /// - Parameters:
  ///   - count: The count of sessions.
  ///   - harness: The harness whose client opens them.
  ///   - folder: The working directory of each session.
  /// - Returns: The ids, in the order of the calls.
  /// - Throws: Whatever the wire throws.
  private static func openSessions(
    _ count: Int, on harness: AgentClientHarness, in folder: URL
  ) async throws -> [SessionId] {
    guard count > 0 else { return [] }
    let earlier = try await openSessions(count - 1, on: harness, in: folder)
    let latest = try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId
    return earlier + [latest]
  }

  /// Runs a document on the endpoint of a session with no viewer: the way
  /// of a tool call of the model.
  func modelExecute(_ query: String, in session: SessionId) async throws -> String {
    let tools = await agent.sessions[session]?.surface.tools ?? []
    let endpoint = try #require(
      tools.compactMap { $0 as? any GraphQLEndpointTool }.flatMap(\.graphQLEndpoints)
        .first { $0.name == "kanban" })
    return try await endpoint.execute(
      query: query, variables: [:], operationName: nil, viewer: nil)
  }

  /// Adds a task as the model.
  func modelWrite(_ title: String, in session: SessionId) async throws -> String {
    try await modelExecute(Self.addTask(title), in: session)
  }

  /// Adds a task through the tunnel call of the device connection.
  func tunnelWrite(_ title: String, in session: SessionId) async throws -> SAH.GraphQL.ExecutionResult {
    try await device.connection.callExtensionMethod(
      SAH.GraphQL.Method.execute,
      SAH.GraphQL.ExecuteRequest(
        endpoint: "kanban", sessionId: session, query: Self.addTask(title), variables: nil),
      returning: SAH.GraphQL.ExecutionResult.self)
  }

  /// The query that reads the history of the board with the actor of each
  /// change.
  private static let historyQuery = "{ board { history { txn undone actor { id } } } }"

  /// One change of the history.
  struct Entry {
    let undone: Bool
    let actor: String
  }

  /// The history of the board, newest first.
  func history(in session: SessionId) async throws -> [Entry] {
    let text = try await modelExecute(Self.historyQuery, in: session)
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let board = (root["data"] as? [String: Any])?["board"] as? [String: Any]
    let changes = board?["history"] as? [[String: Any]] ?? []
    return changes.map { change in
      Entry(
        undone: change["undone"] as? Bool ?? false,
        actor: ((change["actor"] as? [String: Any])?["id"] as? String) ?? "")
    }
  }

  /// The actor of the oldest change that is not an undo: the first write.
  func actorOfOldestWrite(in session: SessionId) async throws -> String {
    let entries = try await history(in: session)
    return try #require(entries.last?.actor)
  }

  /// The document that adds one task.
  private static func addTask(_ title: String) -> String {
    "mutation { addTask(input: { title: \"\(title)\" }) { title } }"
  }
}
