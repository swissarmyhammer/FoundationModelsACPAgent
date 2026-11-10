import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsMultitool
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The `tools:`, `disallowedTools:` and `model:` keys of the session agent
/// (ACPA-1b, D90 (c)).
///
/// The keys filter the surface of the root session with the same match that
/// a run of FoundationModelsAgents uses. The tools that give an endpoint
/// always stay, and the session logs one warning when an agent tries to
/// remove one. The `model:` key gives the start value of the `model` option.
///
/// The session tests open a session on a stub agent over throwaway folders.
/// The `AGENT.md` at the root of the working directory is the session agent.
@Suite(.closesHarnesses) struct SessionAgentToolsTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionAgentToolsTests"

  /// The id of the session agent in the working directory.
  private static let sessionAgentID = "probe"

  /// The name of the web capability.
  private static let webName = "web"

  /// The name of the shell capability.
  private static let shellName = "shell"

  /// The name of the files capability.
  private static let filesName = "files"

  /// The name of the git capability.
  private static let gitName = "git"

  /// The name of the environment capability.
  private static let environmentName = "environment"

  /// The capabilities that `tools: [web]` keeps or removes: the files
  /// endpoint, the web capability, and three capabilities that only a
  /// configuration or the agent turns off.
  private static let webCheckNames: Set<String> = [
    filesName, webName, shellName, gitName, environmentName,
  ]

  /// The spellings of `model: flash` in other letter cases.
  private static let flashSpellings = ["Flash", "FLASH"]

  /// The name of the `agents` tool.
  private static let agentsName = "agents"

  /// The names that always stay on the surface of a root session: the tools
  /// that give an endpoint (D90 (c)), with `files` of `runCode`, and
  /// `searchTools`, the discovery half of `runCode`. The test keeps its own
  /// copy of the list.
  private static let alwaysOnNames: Set<String> = [
    "agents", "skills", "sessions", "kanban", "rules", "settings", "runCode", "files",
    "searchTools",
  ]

  /// The names of a surface for the unit tests of the selection, with no
  /// `agents`: the selection gets the `agents` tool through its flag.
  private static let surfaceNames = [
    "searchTools", "runCode", "skills", "files", "shell", "web", "settings",
  ]

  /// A catalog agent that the grant of the `agents` tool names.
  private static let grantedAgentID = "coder"

  /// A catalog agent that the grant of the `agents` tool does not name.
  private static let otherAgentID = "writer"

  /// The path of the project layer that holds agent folders, relative to a
  /// working directory.
  private static let projectAgentsPath = ".agents/agents"

  /// A `model:` value that names no slot.
  private static let unknownModel = "no-such-model"

  // MARK: - Helpers

  /// Writes the session agent `<cwd>/AGENT.md` with `keys` in its
  /// frontmatter.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines after `name` and `description`.
  ///   - cwd: The working directory.
  /// - Throws: The write error.
  private static func writeSessionAgent(keys: [String], in cwd: URL) throws {
    try AgentFolderFixture.document(
      id: sessionAgentID, description: "The probe session agent.", extraKeys: keys
    ).write(
      to: cwd.appendingPathComponent(AgentFolderFixture.documentName), atomically: true,
      encoding: .utf8)
  }

  /// The session agent `<folder>/AGENT.md` with `keys`, as a definition.
  ///
  /// - Parameter keys: The frontmatter lines after `name` and `description`.
  /// - Returns: The definition.
  /// - Throws: The write error, or when the document does not load.
  private static func definition(keys: [String]) throws -> AgentDefinition {
    let folder = makeResolvedDirectory(label: "\(label)-definition")
    try writeSessionAgent(keys: keys, in: folder)
    return try #require(AgentRegistry.rootAgent(in: folder, id: sessionAgentID).definition)
  }

  /// Opens one session in `cwd` on `agent`, and gives its table entry.
  ///
  /// - Parameters:
  ///   - cwd: The working directory.
  ///   - agent: The stub agent.
  /// - Returns: The entry of the new session.
  /// - Throws: What `session/new` throws.
  private static func openSession(in cwd: URL, on agent: RoutedACPAgent) async throws
    -> ActiveSession
  {
    let response = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))
    return try #require(await agent.sessions[response.sessionId])
  }

  /// Opens one session with the session agent `keys`, and one session with
  /// no session agent, on one stub agent.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the session agent.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The entry of the agent session and of the plain session.
  /// - Throws: What the agent or `session/new` throws.
  private static func openSessions(keys: [String], name: String) async throws
    -> (agent: ActiveSession, plain: ActiveSession)
  {
    let routed = try await AgentClientHarness.makeInitializedAgent(label: label)
    let agentFolder = makeResolvedDirectory(label: "\(label)-\(name)-agent")
    try writeSessionAgent(keys: keys, in: agentFolder)
    let agentSession = try await openSession(in: agentFolder, on: routed)
    let plainSession = try await openSession(
      in: makeResolvedDirectory(label: "\(label)-\(name)-plain"), on: routed)
    return (agentSession, plainSession)
  }

  /// The capabilities of a surface: the names of its top-level tools, and
  /// the noun of each entry of the registry that its `runCode` reads now.
  ///
  /// - Parameter surface: The surface.
  /// - Returns: The names.
  /// - Throws: When the surface has no `runCode`.
  private static func capabilities(of surface: SessionSurface) throws -> Set<String> {
    let runCode = try #require(surface.tools.compactMap { $0 as? MultiTool }.first)
    let nouns = runCode.currentRegistry.surface.entries.map { $0.group ?? $0.path }
    return Set(surface.tools.map(\.name) + nouns)
  }

  /// The current value of the `model` option of a session.
  ///
  /// - Parameter entry: The entry of the session.
  /// - Returns: The value id.
  /// - Throws: When the session announced no `model` option.
  private static func modelOptionValue(of entry: ActiveSession) throws -> String {
    try ConfigOptionSelect.select(
      in: entry.announcedConfigOptions, configId: ConfigOptions.modelOptionId
    ).currentValue.rawValue
  }

  // MARK: - tools:

  /// A session agent with `tools: [web]` has `web` and each endpoint tool,
  /// and no other capability.
  @Test func toolsWebKeepsWebAndTheEndpointToolsOnly() async throws {
    let sessions = try await Self.openSessions(keys: ["tools: [web]"], name: "web")

    let plain = try Self.capabilities(of: sessions.plain.surface)
    #expect(
      try Self.capabilities(of: sessions.agent.surface)
        == plain.intersection(Self.alwaysOnNames.union([Self.webName])))
  }

  /// A session agent with `tools: [web]` gives the model `files` and `web`,
  /// and no `shell`, `git` or `environment` (D90 (c): `files` is an
  /// endpoint).
  @Test func toolsWebGivesTheModelFilesAndWebOnly() throws {
    let selection = SessionToolSelection(
      definition: try Self.definition(keys: ["tools: [web]"]),
      names: Self.surfaceNames + [Self.gitName, Self.environmentName])

    #expect(
      selection.keptNames.intersection(Self.webCheckNames) == [Self.filesName, Self.webName])
  }

  /// A session agent with no `tools:` has the full surface, as a session
  /// with no session agent has.
  @Test func noToolsKeyKeepsTheFullSurface() async throws {
    let sessions = try await Self.openSessions(keys: [], name: "full")

    #expect(
      try Self.capabilities(of: sessions.agent.surface)
        == Self.capabilities(of: sessions.plain.surface))
  }

  // MARK: - disallowedTools:

  /// A session agent with `disallowedTools: [agents, shell]` has no `shell`,
  /// and each other capability of the full surface.
  @Test func disallowedShellIsRemoved() async throws {
    let sessions = try await Self.openSessions(
      keys: ["disallowedTools: [agents, shell]"], name: "noshell")

    let plain = try Self.capabilities(of: sessions.plain.surface)
    #expect(
      try Self.capabilities(of: sessions.agent.surface) == plain.subtracting([Self.shellName]),
      "full surface: \(plain)")
  }

  /// A session agent with `disallowedTools: [agents, shell]` still has the
  /// `agents` tool.
  @Test func disallowedAgentsStays() async throws {
    let sessions = try await Self.openSessions(
      keys: ["disallowedTools: [agents, shell]"], name: "agents")

    #expect(sessions.agent.surface.tools.map(\.name).contains(Self.agentsName))
  }

  /// `disallowedTools: [agents, shell]` gives one warning: the `agents` tool
  /// stays.
  @Test func disallowedAgentsGivesOneWarning() throws {
    let selection = SessionToolSelection(
      definition: try Self.definition(keys: ["disallowedTools: [agents, shell]"]),
      names: Self.surfaceNames)

    #expect(selection.warnings.count == 1, "\(selection.warnings)")
  }

  /// `tools: [web]` keeps `web` and each always-on name of the surface.
  @Test func theSelectionOfToolsWebKeepsWebAndTheAlwaysOnNames() throws {
    let selection = SessionToolSelection(
      definition: try Self.definition(keys: ["tools: [web]"]), names: Self.surfaceNames)

    #expect(
      selection.keptNames
        == Set(Self.surfaceNames).intersection(Self.alwaysOnNames.union([Self.webName])))
  }

  /// A session agent with no `tools:` and no `disallowedTools:` gives no
  /// warning.
  @Test func noKeysGiveNoWarning() throws {
    let selection = SessionToolSelection(
      definition: try Self.definition(keys: []), names: Self.surfaceNames)

    #expect(selection.warnings.isEmpty, "\(selection.warnings)")
  }

  /// `tools: [Agent(coder)]` gives the root `agents` tool the agent `coder`,
  /// and no other agent.
  @Test func anAgentGrantLimitsTheRootAgentsTool() async throws {
    let routed = try await AgentClientHarness.makeInitializedAgent(label: Self.label)
    let cwd = makeResolvedDirectory(label: "\(Self.label)-grant")
    let layer = cwd.appendingPathComponent(Self.projectAgentsPath, isDirectory: true)
    for id in [Self.grantedAgentID, Self.otherAgentID] {
      try AgentFolderFixture.write(id: id, under: layer, description: "The \(id) agent.")
    }
    try Self.writeSessionAgent(keys: ["tools: [web, \"Agent(\(Self.grantedAgentID))\"]"], in: cwd)

    let entry = try await Self.openSession(in: cwd, on: routed)

    let agentsTool = try #require(entry.surface.tools.first { $0.name == Self.agentsName })
    #expect(agentsTool.description.contains(Self.grantedAgentID), "\(agentsTool.description)")
    #expect(!agentsTool.description.contains(Self.otherAgentID), "\(agentsTool.description)")
  }

  // MARK: - The refresh of the registry

  /// A registry that the MCP refresher stages through the staging of the
  /// surface gets the selection of the session agent again.
  @Test func aStagedRegistryGetsTheSelectionAgain() throws {
    let recorder = RecordingStaging()
    let staging = SessionRegistryStaging(wrapping: recorder)
    let registry = try MultiTool.Builder(mode: .open).withEnvironment().withGit(
      root: makeResolvedDirectory(label: "\(Self.label)-git")
    ).buildRegistry()
    staging.select(
      RegistrySelection(
        definition: try Self.definition(keys: ["tools: [git]"]), topLevelNames: [],
        mcpServerNames: []),
      current: registry)

    staging.stage(registry)

    #expect(Set(recorder.staged.flatMap { $0.surface.entries.compactMap(\.group) }) == ["git"])
  }

  // MARK: - model:

  /// A session agent with `model: flash` starts on the flash slot.
  @Test func modelFlashStartsOnTheFlashSlot() async throws {
    let sessions = try await Self.openSessions(keys: ["model: flash"], name: "flash")

    #expect(sessions.agent.selectedSlot == .flash)
  }

  /// The letter case of the `model:` value does not matter: `Flash` and
  /// `FLASH` start on the flash slot.
  @Test(arguments: flashSpellings)
  func modelFlashInAnyCaseStartsOnTheFlashSlot(spelling: String) async throws {
    let sessions = try await Self.openSessions(
      keys: ["model: \(spelling)"], name: "flash-\(spelling)")

    #expect(sessions.agent.selectedSlot == .flash)
  }

  /// A session agent with `model: flash` shows `flash` in the `model`
  /// option.
  @Test func modelFlashShowsInTheModelOption() async throws {
    let sessions = try await Self.openSessions(keys: ["model: flash"], name: "option")

    #expect(try Self.modelOptionValue(of: sessions.agent) == ModelSlot.flash.rawValue)
  }

  /// A `model:` value that names no slot gives the default slot.
  @Test func anUnknownModelGivesTheDefaultSlot() {
    #expect(ConfigOptions.slot(forAgentModel: Self.unknownModel).slot == ConfigOptions.defaultSlot)
  }

  /// A `model:` value that names no slot gives a warning.
  @Test func anUnknownModelGivesAWarning() {
    #expect(ConfigOptions.slot(forAgentModel: Self.unknownModel).warning != nil)
  }
}

/// A staging that keeps each registry that it gets.
private final class RecordingStaging: RegistryStaging {
  /// The registries, in the order of the calls.
  private let registries = Mutex<[MultiTool.Registry]>([])

  /// The registries, in the order of the calls.
  var staged: [MultiTool.Registry] {
    registries.withLock { $0 }
  }

  /// Keeps `registry`.
  ///
  /// - Parameter registry: The staged registry.
  func stage(_ registry: MultiTool.Registry) {
    registries.withLock { $0.append(registry) }
  }
}
