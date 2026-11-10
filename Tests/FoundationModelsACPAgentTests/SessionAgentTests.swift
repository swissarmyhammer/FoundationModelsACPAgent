import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import Testing

@testable import FoundationModelsACPAgent

/// The agent of a session (ACPA-1, D61, D71): the `agent` config option of
/// `session/new`, the resolution of the session agent, and the record that a
/// resume reads.
///
/// The resolution has this order: the `agent` option, else the `AGENT.md` at
/// the root of the `cwd`, else the default agent, else the builtin floor.
/// Each test opens its session on a stub agent over throwaway folders.
@Suite(.closesHarnesses) struct SessionAgentTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionAgentTests"

  /// The id of the catalog agent that a client selects.
  private static let catalogAgentID = "coder"

  /// An agent id that no layer gives.
  private static let unknownAgentID = "no-such-agent"

  /// The marker body of the catalog agent.
  private static let catalogAgentBody = "SESSION-AGENT-CATALOG-BODY"

  /// The marker body of the default agent.
  private static let defaultAgentBody = "SESSION-AGENT-DEFAULT-BODY"

  /// The marker body of the `AGENT.md` of the working directory.
  private static let folderAgentBody = "SESSION-AGENT-FOLDER-BODY"

  /// A folder name that is not a valid agent id.
  private static let invalidFolderName = "My Project!"

  /// The agent id that the invalid folder name gives.
  private static let invalidFolderAgentID = "my-project"

  /// The name of a catalog agent folder that is the working directory.
  private static let catalogFolderName = "writer"

  /// The path of the project layer that holds agent folders, relative to a
  /// working directory.
  private static let projectAgentsPath = ".agents/agents"

  /// The name of the agent document.
  private static let documentName = AgentFolderFixture.documentName

  // MARK: - Helpers

  /// The text of one agent document with a marker body.
  ///
  /// - Parameters:
  ///   - id: The agent id, which is the `name` field.
  ///   - body: The body of the document.
  /// - Returns: The document text.
  private static func document(id: String, body: String) -> String {
    "---\nname: \(id)\ndescription: The \(id) test agent.\n---\n\n\(body)\n"
  }

  /// Writes `text` to `<folder>/AGENT.md`.
  ///
  /// - Parameters:
  ///   - text: The document text.
  ///   - folder: The folder of the document.
  /// - Throws: The directory-creation or write error.
  private static func writeDocument(_ text: String, in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try text.write(
      to: folder.appendingPathComponent(documentName), atomically: true, encoding: .utf8)
  }

  /// Writes the project agent `<cwd>/.agents/agents/<id>/AGENT.md`.
  ///
  /// - Parameters:
  ///   - id: The agent id.
  ///   - body: The body of the document.
  ///   - cwd: The working directory.
  /// - Throws: The directory-creation or write error.
  private static func writeProjectAgent(id: String, body: String, in cwd: URL) throws {
    try writeDocument(
      document(id: id, body: body),
      in: cwd.appendingPathComponent(projectAgentsPath, isDirectory: true)
        .appendingPathComponent(id, isDirectory: true))
  }

  /// The `session/new` request for `cwd`, with the `agent` option in
  /// `_meta.sah.configOptions` when `agent` is not `nil`.
  ///
  /// - Parameters:
  ///   - cwd: The working directory.
  ///   - agent: The value id of the `agent` option, or `nil` for none.
  /// - Returns: The request.
  private static func newSessionRequest(cwd: URL, agent: String?) -> NewSessionRequest {
    let meta = agent.map { id -> JSONValue in
      .object([SAH.metaKey: .object(["configOptions": .object(["agent": .string(id)])])])
    }
    return NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path), meta: meta)
  }

  /// The `agent` select of a complete option state.
  ///
  /// - Parameter options: The announced complete state.
  /// - Returns: The select payload.
  /// - Throws: When the state has no `agent` select.
  private static func agentSelect(in options: [SessionConfigOption]?) throws
    -> SessionConfigSelect
  {
    let option = try #require(options?.first { $0.configId == ConfigOptions.agentOptionId })
    guard case .select(let select) = option.type else {
      Issue.record("expected a select option, got \(option.type)")
      throw RequestError.invalidParams
    }
    return select
  }

  /// The value ids of a select, in announcement order.
  ///
  /// - Parameter select: The select payload.
  /// - Returns: The value ids.
  /// - Throws: When the raw JSON does not decode as the flat list.
  private static func valueIDs(of select: SessionConfigSelect) throws -> [String] {
    let data = try JSONEncoder().encode(select.options)
    return try JSONDecoder().decode([SessionConfigSelectOption].self, from: data)
      .map(\.value.rawValue)
  }

  /// One session of a new stub agent.
  struct OpenedSession {
    /// The agent of the session.
    let agent: RoutedACPAgent

    /// The `session/new` response.
    let response: NewSessionResponse

    /// The assembled instructions of the session.
    let instructions: String

    /// The current value of the `agent` option.
    let currentAgent: String
  }

  /// Opens one session on a new stub agent.
  ///
  /// - Parameters:
  ///   - cwd: The working directory.
  ///   - agent: The value id of the `agent` option, or `nil` for none.
  ///   - userDirectory: The synced root of the home, or `nil` for a new
  ///     throwaway folder.
  /// - Returns: The session.
  /// - Throws: What the agent or `session/new` throws.
  private static func openSession(
    in cwd: URL, agent: String? = nil, userDirectory: URL? = nil
  ) async throws -> OpenedSession {
    let routed = try await AgentClientHarness.makeInitializedAgent(
      label: label, userDirectory: userDirectory)
    let response = try await routed.newSession(newSessionRequest(cwd: cwd, agent: agent))
    let entry = try #require(await routed.sessions[response.sessionId])
    return OpenedSession(
      agent: routed, response: response, instructions: entry.instructions,
      currentAgent: try agentSelect(in: response.configOptions).currentValue.rawValue)
  }

  // MARK: - The agent option

  /// With `agent: X`, the session instructions start with the body of X.
  @Test func theAgentOptionSelectsTheAgentOfTheSession() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-option")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)

    let session = try await Self.openSession(in: cwd, agent: Self.catalogAgentID)

    #expect(
      session.instructions.hasPrefix(Self.catalogAgentBody), "\(session.instructions.prefix(80))")
  }

  /// The current value of the `agent` option is the selected agent.
  @Test func theCurrentValueOfTheAgentOptionIsTheSelectedAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-current")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)

    let session = try await Self.openSession(in: cwd, agent: Self.catalogAgentID)

    #expect(session.currentAgent == Self.catalogAgentID)
  }

  /// The `agent` option lists `default` first, then each catalog agent that
  /// a user can start.
  @Test func theAgentOptionListsTheDefaultAndTheCatalogAgents() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-list")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)

    let session = try await Self.openSession(in: cwd)

    let select = try Self.agentSelect(in: session.response.configOptions)
    #expect(
      try Self.valueIDs(of: select) == [ConfigOptions.defaultAgentValue, Self.catalogAgentID])
  }

  /// With `agent: X`, an `AGENT.md` of the working directory is project
  /// instructions with its path header.
  @Test func withAnAgentTheAgentMdOfTheWorkingDirectoryIsProjectInstructions() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-project")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let session = try await Self.openSession(in: cwd, agent: Self.catalogAgentID)

    #expect(
      session.instructions.contains(
        "===== \(cwd.appendingPathComponent(Self.documentName).path) ====="))
  }

  /// An unknown agent id is refused with `invalidConfigOptionValue`.
  @Test func anUnknownAgentIsRefused() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-unknown")
    let agent = try await AgentClientHarness.makeInitializedAgent(label: Self.label)

    await #expect(throws: RequestError.invalidConfigOptionValue(id: ConfigOptions.agentOptionId)) {
      _ = try await agent.newSession(Self.newSessionRequest(cwd: cwd, agent: Self.unknownAgentID))
    }
  }

  /// A `session/set_config_option` for `agent` after the start is refused.
  @Test func theAgentCannotChangeAfterTheStart() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-set")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)
    let session = try await Self.openSession(in: cwd)

    await #expect(throws: RequestError.agentFixedAtSessionStart(id: ConfigOptions.agentOptionId)) {
      _ = try await session.agent.setSessionConfigOption(
        SetSessionConfigOptionRequest(
          configId: ConfigOptions.agentOptionId, sessionId: session.response.sessionId,
          value: .id(SessionConfigValueId(rawValue: Self.catalogAgentID))))
    }
  }

  // MARK: - The resolution with no agent option

  /// With no `agent` and an `AGENT.md` in the working directory, that file
  /// is the session agent.
  @Test func withNoAgentTheAgentMdOfTheWorkingDirectoryIsTheSessionAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-folder")
    try Self.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, body: Self.defaultAgentBody, in: cwd)
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let session = try await Self.openSession(in: cwd)

    #expect(
      session.instructions.hasPrefix(Self.folderAgentBody), "\(session.instructions.prefix(80))")
  }

  /// The `AGENT.md` of the working directory that is the session agent is
  /// not repeated as project instructions.
  @Test func theSessionAgentMdIsNotRepeatedAsProjectInstructions() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-norepeat")
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let session = try await Self.openSession(in: cwd)

    #expect(!session.instructions.contains(cwd.appendingPathComponent(Self.documentName).path))
  }

  /// With no `agent` and no `AGENT.md` in the working directory, the
  /// default agent is the session agent.
  @Test func withNoAgentAndNoAgentMdTheDefaultAgentIsTheSessionAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-default")
    try Self.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, body: Self.defaultAgentBody, in: cwd)

    let session = try await Self.openSession(in: cwd)

    #expect(
      session.instructions.hasPrefix(Self.defaultAgentBody), "\(session.instructions.prefix(80))")
    #expect(session.currentAgent == ConfigOptions.defaultAgentValue)
  }

  // MARK: - The four resolution cases over the catalog of a session

  /// The agent catalog of a session over `cwd`: the agent registry that the
  /// session composition makes, over the catalog context of
  /// ``CatalogRegistryFixture``, loaded.
  ///
  /// - Parameter cwd: The working directory.
  /// - Returns: The catalog.
  /// - Throws: What the context or the load throws.
  private static func makeCatalog(workingDirectory cwd: URL) async throws -> AgentCatalog {
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: cwd, configuration: AgentConfiguration())
    let registry = AgentsComposition.makeAgentRegistry(context: context, marketplaces: nil)
    try await registry.load()
    return registry.catalog()
  }

  /// Resolves the agent of a new session over `cwd` with no catalog layer
  /// root.
  ///
  /// - Parameters:
  ///   - cwd: The working directory.
  ///   - requested: The value of the `agent` option, or `nil` for none.
  /// - Returns: The resolved agent.
  /// - Throws: What the catalog or the resolution throws.
  private static func resolve(in cwd: URL, requested: String?) async throws
    -> ResolvedSessionAgent
  {
    try SessionAgentResolution.resolve(
      requested: requested, catalog: try await makeCatalog(workingDirectory: cwd),
      workingDirectory: cwd, layerRoots: [])
  }

  /// Case 1: the `agent` option selects the catalog agent.
  @Test func theOptionResolvesToTheCatalogAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-case-option")
    try Self.writeProjectAgent(id: Self.catalogAgentID, body: Self.catalogAgentBody, in: cwd)
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let resolved = try await Self.resolve(in: cwd, requested: Self.catalogAgentID)

    #expect(resolved.choice == SessionAgentChoice(id: Self.catalogAgentID, source: .option))
  }

  /// Case 2: with no option, the `AGENT.md` of the working directory is the
  /// agent.
  @Test func noOptionResolvesToTheAgentMdOfTheWorkingDirectory() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-case-folder")
    try Self.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, body: Self.defaultAgentBody, in: cwd)
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let resolved = try await Self.resolve(in: cwd, requested: nil)

    #expect(resolved.choice.source == .workingDirectory)
  }

  /// Case 3: with no option and no `AGENT.md`, the default agent is the
  /// agent.
  @Test func noOptionAndNoAgentMdResolvesToTheDefaultAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-case-default")
    try Self.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, body: Self.defaultAgentBody, in: cwd)

    let resolved = try await Self.resolve(in: cwd, requested: nil)

    #expect(resolved.definition?.id == ConfigOptions.defaultAgentValue)
  }

  /// Case 4: with no option, no `AGENT.md` and no default agent, the session
  /// has the builtin floor.
  @Test func noAgentAnywhereResolvesToTheBuiltinFloor() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-case-builtin")

    let resolved = try await Self.resolve(in: cwd, requested: nil)

    #expect(resolved.definition == nil)
  }

  /// Case 4 in a session: the builtin floor is the base prompt.
  @Test func theBuiltinFloorIsTheBasePromptWhenNoAgentResolves() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-builtin")

    let session = try await Self.openSession(in: cwd)

    #expect(session.instructions.hasPrefix(BuiltinInstructions.text))
  }

  // MARK: - The id of the agent of the working directory

  /// A working directory whose name is not a valid agent id gives a valid
  /// id, so its `AGENT.md` loads as the session agent.
  @Test func aFolderNameThatIsNotAValidIDGivesAValidAgentID() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-invalid")
      .appendingPathComponent(Self.invalidFolderName, isDirectory: true)
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    let session = try await Self.openSession(in: cwd)

    #expect(session.currentAgent == Self.invalidFolderAgentID)
    #expect(
      session.instructions.hasPrefix(Self.folderAgentBody), "\(session.instructions.prefix(80))")
  }

  /// A working directory that is a catalog folder `Agents/<name>/` gives the
  /// agent id `<name>`.
  @Test func aCatalogFolderGivesItsCatalogID() async throws {
    let synced = makeResolvedDirectory(label: "\(Self.label)-synced")
    let cwd = synced.appendingPathComponent(Self.catalogFolderName, isDirectory: true)
    try Self.writeDocument(
      Self.document(id: Self.catalogFolderName, body: Self.folderAgentBody), in: cwd)

    let session = try await Self.openSession(in: cwd, userDirectory: synced)

    #expect(session.currentAgent == Self.catalogFolderName)
  }

  /// The root settings folder as the working directory gives the agent id
  /// `default`.
  @Test func theRootSettingsFolderGivesTheDefaultID() async throws {
    let synced = makeResolvedDirectory(label: "\(Self.label)-root")
    try Self.writeDocument(
      Self.document(id: ConfigOptions.defaultAgentValue, body: Self.folderAgentBody), in: synced)

    let session = try await Self.openSession(in: synced, userDirectory: synced)

    #expect(session.currentAgent == ConfigOptions.defaultAgentValue)
  }

  /// The host id rule maps a folder name to a valid agent id.
  @Test(arguments: [
    ("My Project!", "my-project"),
    ("--Two__Words--", "two-words"),
    ("coder", "coder"),
  ])
  func theFolderNameMapsToAValidAgentID(name: String, id: String) {
    #expect(SessionAgentResolution.agentID(forFolderNamed: name) == id)
  }

  /// A folder name with no letter or digit gives the fallback id.
  @Test func aFolderNameWithNoLetterOrDigitGivesTheFallbackID() {
    #expect(
      SessionAgentResolution.agentID(forFolderNamed: "!!!")
        == SessionAgentResolution.fallbackFolderAgentID)
  }

  /// A long folder name gives an id of at most 64 characters with no
  /// hyphen at the end.
  @Test func aLongFolderNameGivesAnIDOfTheMaximumLength() {
    let name = String(repeating: "a", count: 63) + "-bc"

    #expect(
      SessionAgentResolution.agentID(forFolderNamed: name) == String(repeating: "a", count: 63))
  }

  // MARK: - The resume

  /// A resumed session has the agent that it had before, also when the
  /// working directory got an `AGENT.md` after the start.
  @Test func aResumedSessionKeepsItsAgent() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-resume")
    try Self.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, body: Self.defaultAgentBody, in: cwd)
    var resume = try await ResumeSessionFixture.make(
      label: "\(Self.label)-resume", workingDirectory: cwd)
    try await resume.runPrompt("one prompt before the resume")
    _ = try await resume.fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: resume.fixture.sessionId))
    try Self.writeDocument(Self.document(id: "folder", body: Self.folderAgentBody), in: cwd)

    _ = try await resume.fixture.harness.connection.resumeSession(resume.makeResumeRequest())

    let entry = try #require(await resume.fixture.harness.agent.sessions[resume.fixture.sessionId])
    #expect(entry.instructions.hasPrefix(Self.defaultAgentBody), "\(entry.instructions.prefix(80))")
    await resume.fixture.close()
  }
}
