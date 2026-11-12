import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsAgents
@testable import FoundationModelsSkills

/// The agent registry of a session watches its layers (task ^a84x0wm): a new
/// `AGENT.md` that a person, Finder or iCloud writes after the session
/// started reaches the `agents` endpoint of the session.
///
/// Each test starts one session over the in-memory wire, with a temporary
/// root settings folder (the synced root of the custom home of the agent)
/// and a temporary working directory. The client reads the `agents`
/// endpoint through `_sah/graphql/execute` and `_sah/graphql/subscribe`.
///
/// A test does not wait for a fixed time. It waits for the change event of
/// the subscription. The time limit of each test bounds that wait.
///
/// The close tests of the skills registry (task ^enh25yn) use the same
/// fixture. They wait for the reload of the skills registry of the control
/// session, not for a fixed time.
@Suite(.closesHarnesses) struct AgentCatalogWatchTests {
  /// The id of the agent that each test writes after the session started.
  private static let newAgentID = "late-helper"

  /// The id of the agent that a close test writes after the change event of
  /// ``newAgentID``.
  private static let laterAgentID = "later-helper"

  /// The id of the skill that a skills close test writes after the close.
  private static let newSkillID = "late-skill"

  /// The id of the skill that a skills close test writes after the control
  /// session got ``newSkillID``.
  private static let laterSkillID = "later-skill"

  /// The name of the project layer folder of the skills stack in the working
  /// directory.
  private static let skillsProjectLayerName = ".\(ToolCatalog.skillsDotfolderName)"

  /// The `cursor` query of the `agents` endpoint.
  private static let cursorQuery = "{ cursor }"

  /// The query of the ids of the agents of the catalog.
  private static let agentsQuery = "{ agents { id } }"

  /// The `changes(after:)` subscription of the `agents` endpoint after the
  /// cursor in the `after` variable.
  private static let changesSubscription = """
    subscription($after: String) { changes(after: $after) { cursor added } }
    """

  /// The id of the one subscription of each test.
  private static let subscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "agents-changes")

  /// The name of the project layer folder in the working directory.
  private static let projectLayerName = ".\(ToolCatalog.agentsDotfolderName)"

  // MARK: - The root settings folder

  /// A new `<root settings folder>/<id>/AGENT.md` that is written after the
  /// session started gives a change event on the `changes(after:)`
  /// subscription of the `agents` endpoint, and the event adds the agent.
  @Test(.timeLimit(.minutes(1)))
  func aNewAgentInTheRootSettingsFolderGivesAChangeEvent() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-root-event")

    let added = try await Self.addedIDs(
      on: fixture, writingIn: fixture.rootSettingsFolder)

    #expect(added.contains(Self.newAgentID))
  }

  /// After the change event of a new agent in the root settings folder, the
  /// next `agents` query lists the new agent: the endpoint reads the current
  /// catalog, not a copy from the session start.
  @Test(.timeLimit(.minutes(1)))
  func theNextQueryAfterTheChangeListsTheNewAgent() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-root-query")
    _ = try await Self.addedIDs(on: fixture, writingIn: fixture.rootSettingsFolder)

    let result = try await fixture.execute(query: Self.agentsQuery)

    #expect(Self.agentIDs(of: result).contains(Self.newAgentID))
  }

  // MARK: - The project layer

  /// A new `<cwd>/.agents/<id>/AGENT.md` that is written after the session
  /// started gives a change event on the `agents` endpoint too, also when
  /// the project layer folder was not there at the session start.
  @Test(.timeLimit(.minutes(1)))
  func aNewAgentInTheProjectLayerGivesAChangeEvent() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-project-event")
    let projectLayer = fixture.workingDirectory.appendingPathComponent(
      Self.projectLayerName, isDirectory: true)

    let added = try await Self.addedIDs(on: fixture, writingIn: projectLayer)

    #expect(added.contains(Self.newAgentID))
  }

  // MARK: - The close of a session

  /// After `session/close`, the agent registry of the closed session has no
  /// running watcher. A control session stays open and shows that the new
  /// agent reached the watchers.
  @Test(.timeLimit(.minutes(1)))
  func aClosedSessionLeavesNoRunningWatcher() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-close-watcher")

    let closedRegistry = try await Self.registryAfterANewAgent(closingASessionOf: fixture)

    #expect(!closedRegistry.reloads.isWatching)
  }

  /// After `session/close`, a new agent gives no change to the catalog of
  /// the closed session, while the control session that stays open gets the
  /// change event.
  @Test(.timeLimit(.minutes(1)))
  func aNewAgentAfterTheCloseGivesNoChangeToTheClosedSession() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-close-catalog")

    let closedRegistry = try await Self.registryAfterANewAgent(closingASessionOf: fixture)

    #expect(closedRegistry.catalog().definition(named: Self.newAgentID) == nil)
  }

  // MARK: - The skills registry at the close of a session

  /// After `session/close`, the skills registry of the closed session has no
  /// running watcher. A control session stays open and shows that the new
  /// skill reached the watchers.
  @Test(.timeLimit(.minutes(1)))
  func aClosedSessionLeavesNoRunningSkillsWatcher() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-close-skills-watcher")

    let closedRegistry = try await Self.skillsRegistryAfterANewSkill(closingASessionOf: fixture)

    #expect(!closedRegistry.isFollowingChanges)
  }

  /// After `session/close`, a new `SKILL.md` gives no reload of the skills
  /// registry of the closed session, while the control session that stays
  /// open gets the new skill.
  @Test(.timeLimit(.minutes(1)))
  func aNewSkillAfterTheCloseGivesNoChangeToTheClosedSession() async throws {
    let fixture = try await WatchFixture.make(label: "AgentCatalogWatchTests-close-skills")

    let closedRegistry = try await Self.skillsRegistryAfterANewSkill(closingASessionOf: fixture)

    #expect(!closedRegistry.metadata().contains { $0.id == Self.newSkillID })
  }

  // MARK: - Helpers

  /// Opens a second session on the agent of `fixture`, and closes it. Then
  /// it writes the new skill in the project layer of the skills stack and
  /// waits for the reload of the skills registry of the control session of
  /// `fixture`, which stays open. Then it does the same with a later skill.
  /// A watcher of the closed session that still runs gets the first change
  /// before the control session gets the second change.
  ///
  /// - Parameter fixture: The agent and the control session of the test.
  /// - Returns: The skills registry of the closed session.
  /// - Throws: Whatever the wire or the write throws; an
  ///   `ExpectationFailedError` when a session has no `agents` mount, or when
  ///   the control registry stops its reloads before it has a new skill.
  private static func skillsRegistryAfterANewSkill(closingASessionOf fixture: WatchFixture)
    async throws -> SkillsRegistry
  {
    try await registryOfAClosedSession(
      of: fixture, reading: { $0.agents?.environment.skills },
      thenWriting: {
        let controlRegistry = try #require(
          await fixture.agent.sessions[fixture.sessionId]?.surface.agents?.environment.skills)
        let layer = fixture.workingDirectory.appendingPathComponent(
          skillsProjectLayerName, isDirectory: true)
        try await writeSkill(newSkillID, in: layer, waitingFor: controlRegistry)
        try await writeSkill(laterSkillID, in: layer, waitingFor: controlRegistry)
      })
  }

  /// Opens a second session on the agent of `fixture`, reads one registry of
  /// that session, and closes the session. Then it runs `write`, which writes
  /// two items in a layer and waits for the control session of `fixture`,
  /// which stays open, to get each item. A watcher of the closed session that
  /// still runs gets the first change before the control session gets the
  /// second change.
  ///
  /// - Parameters:
  ///   - fixture: The agent and the control session of the test.
  ///   - read: Reads the registry from the surface of the second session.
  ///   - write: Writes the two items after the close, and waits for the
  ///     control session to get each of them.
  /// - Returns: The registry that `read` gave for the closed session.
  /// - Throws: Whatever the wire or `write` throws; an
  ///   `ExpectationFailedError` when the second session is not open, or when
  ///   `read` gives no registry.
  private static func registryOfAClosedSession<Registry>(
    of fixture: WatchFixture,
    reading read: (SessionSurface) async -> Registry?,
    thenWriting write: () async throws -> Void
  ) async throws -> Registry {
    let closedSession = try await fixture.openSession()
    let surface = try #require(await fixture.agent.sessions[closedSession]?.surface)
    let registry = try #require(await read(surface))
    _ = try await fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: closedSession))
    try await write()
    return registry
  }

  /// Writes the skill `id` in `layer`, and waits for the reload of `registry`
  /// that has it.
  ///
  /// - Parameters:
  ///   - id: The id of the skill to write, which is also its `name` field.
  ///   - layer: The layer folder that gets `<layer>/<id>/SKILL.md`.
  ///   - registry: The skills registry that must get the skill.
  /// - Throws: Whatever the write throws; an `ExpectationFailedError` when the
  ///   reloads of `registry` stop before one of them has the skill.
  private static func writeSkill(
    _ id: String, in layer: URL, waitingFor registry: SkillsRegistry
  ) async throws {
    // The subscription comes before the write, so no reload of the write is
    // lost.
    let reloads = registry.onReload
    try writeSkillFixture(
      id: id,
      markdown: "---\nname: \(id)\ndescription: A skill that came after the close.\n---\nDo it.\n",
      under: layer)
    var catalogs = reloads.makeAsyncIterator()
    var catalog = registry.metadata()
    while !catalog.contains(where: { $0.id == id }), let next = await catalogs.next() {
      catalog = next
    }
    try #require(catalog.contains { $0.id == id })
  }

  /// Opens a second session on the agent of `fixture`, and closes it. Then
  /// it writes the new agent in the root settings folder and waits for the
  /// change event of the control session of `fixture`, which stays open.
  /// Then it does the same with a later agent. A watcher of the closed
  /// session that still runs gets the first change before the control
  /// session gets the second change.
  ///
  /// - Parameter fixture: The agent and the control session of the test.
  /// - Returns: The agent registry of the closed session.
  /// - Throws: Whatever the wire or the write throws; an
  ///   `ExpectationFailedError` when the second session has no `agents`
  ///   mount.
  private static func registryAfterANewAgent(closingASessionOf fixture: WatchFixture)
    async throws -> AgentRegistry
  {
    try await registryOfAClosedSession(
      of: fixture, reading: { await $0.agents?.runner.registry },
      thenWriting: {
        _ = try await addedIDs(on: fixture, writingIn: fixture.rootSettingsFolder)
        _ = try await addedIDs(
          afterWriting: laterAgentID, in: fixture.rootSettingsFolder, on: fixture)
      })
  }

  /// Reads the cursor of the `agents` endpoint, subscribes to the changes
  /// after it, writes the new agent in `layer`, and waits for the change
  /// event that adds it.
  ///
  /// - Parameters:
  ///   - fixture: The session of the test.
  ///   - layer: The layer folder that gets `<layer>/<id>/AGENT.md`.
  /// - Returns: The ids that the change event adds.
  /// - Throws: Whatever the wire or the write throws; an
  ///   `ExpectationFailedError` when the endpoint gives no cursor.
  private static func addedIDs(on fixture: WatchFixture, writingIn layer: URL) async throws
    -> [String]
  {
    let cursorResult = try await fixture.execute(query: cursorQuery)
    let cursor = try #require(jsonString(of: jsonObject(of: cursorResult.data)?["cursor"]))
    _ = try await fixture.harness.connection.callExtensionMethod(
      SAH.GraphQL.Method.subscribe,
      SAH.GraphQL.SubscribeRequest(
        subscriptionId: subscriptionId, endpoint: AgentsGraph.endpointName,
        sessionId: fixture.sessionId, query: changesSubscription,
        variables: .object(["after": .string(cursor)])),
      returning: SAH.GraphQL.SubscribeResponse.self)
    return try await addedIDs(afterWriting: newAgentID, in: layer, on: fixture)
  }

  /// Writes the agent `id` in `layer`, and waits for the change event of the
  /// subscription of `fixture` that adds it.
  ///
  /// - Parameters:
  ///   - id: The id of the agent to write.
  ///   - layer: The layer folder that gets `<layer>/<id>/AGENT.md`.
  ///   - fixture: The session whose subscription gets the change event.
  /// - Returns: The ids that the change events add.
  /// - Throws: Whatever the write throws; an `ExpectationFailedError` when
  ///   the connection records no GraphQL notification.
  private static func addedIDs(
    afterWriting id: String, in layer: URL, on fixture: WatchFixture
  ) async throws -> [String] {
    let recorder = try #require(fixture.harness.graphQLNotifications)
    try AgentFolderFixture.write(
      id: id, under: layer, description: "An agent that came after the session start.")
    let notifications = try await recorder.wait(for: "the change that adds \(id)") {
      addedIDs(in: $0).contains(id)
    }
    return addedIDs(in: notifications)
  }

  /// The ids that the `changes` events of the notifications add, in order.
  ///
  /// - Parameter notifications: The recorded notifications.
  /// - Returns: The added ids of each `_sah/graphql/next` event.
  private static func addedIDs(in notifications: [GraphQLTunnelNotification]) -> [String] {
    notifications.flatMap { notification -> [String] in
      guard case .next(let next) = notification,
        case .array(let added)? = jsonObject(of: jsonObject(of: next.payload.data)?["changes"])?[
          "added"]
      else {
        return []
      }
      return added.compactMap(jsonString(of:))
    }
  }

  /// The ids of the `agents` field of a query result.
  ///
  /// - Parameter result: The result of ``agentsQuery``.
  /// - Returns: The ids, in catalog order.
  private static func agentIDs(of result: SAH.GraphQL.ExecutionResult) -> [String] {
    guard case .array(let agents)? = jsonObject(of: result.data)?["agents"] else {
      return []
    }
    return agents.compactMap { jsonString(of: jsonObject(of: $0)?["id"]) }
  }
}

/// One agent with a root settings folder of its own, one bound recording
/// connection, and one session in a new working directory.
private struct WatchFixture {
  /// The agent under test.
  let agent: RoutedACPAgent

  /// The recording connection of the client.
  let harness: AgentClientHarness

  /// The session of the test.
  let sessionId: SessionId

  /// The root settings folder of the agent: the user layer of the `agents`
  /// stack.
  let rootSettingsFolder: URL

  /// The working directory of the session.
  let workingDirectory: URL

  /// Makes the agent over a new root settings folder, binds the connection,
  /// and opens one session.
  ///
  /// - Parameter label: The prefix of the names of the temporary folders.
  /// - Returns: The fixture.
  /// - Throws: Whatever the agent start or the wire throws.
  static func make(label: String) async throws -> WatchFixture {
    let rootSettingsFolder = makeResolvedDirectory(label: "\(label)-root")
    let workingDirectory = makeResolvedDirectory(label: "\(label)-repo")
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
      userDirectory: rootSettingsFolder)
    let harness = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
    let session = try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: workingDirectory))
    return WatchFixture(
      agent: agent, harness: harness, sessionId: session.sessionId,
      rootSettingsFolder: rootSettingsFolder, workingDirectory: workingDirectory)
  }

  /// Opens one more session in the working directory of the fixture.
  ///
  /// - Returns: The id of the new session.
  /// - Throws: Whatever the wire throws.
  func openSession() async throws -> SessionId {
    try await harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: workingDirectory)
    ).sessionId
  }

  /// Sends one `_sah/graphql/execute` call to the `agents` endpoint of the
  /// session.
  ///
  /// - Parameter query: The GraphQL document.
  /// - Returns: The result of the call.
  /// - Throws: Whatever the wire throws.
  func execute(query: String) async throws -> SAH.GraphQL.ExecutionResult {
    try await harness.connection.callExtensionMethod(
      SAH.GraphQL.Method.execute,
      SAH.GraphQL.ExecuteRequest(
        endpoint: AgentsGraph.endpointName, sessionId: sessionId, query: query, variables: nil),
      returning: SAH.GraphQL.ExecutionResult.self)
  }
}
