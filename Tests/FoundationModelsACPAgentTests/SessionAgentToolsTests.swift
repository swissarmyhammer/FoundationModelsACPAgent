import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
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

  /// The capabilities that `tools: [web]` keeps or removes: the web
  /// capability, and four capabilities that only a configuration or the
  /// agent turns off.
  private static let webCheckNames: Set<String> = [
    filesName, webName, shellName, gitName, environmentName,
  ]

  /// The groups of `runCode` that read source or run commands, and that a
  /// session agent can remove.
  private static let removableSourceGroups: Set<String> = [
    filesName, shellName, ToolCatalog.codeContextGroupName, webName, gitName,
  ]

  /// The key of a session agent that denies each group of `runCode` that
  /// reads source or runs commands: ``removableSourceGroups``.
  private static let sourceGroupsDenial =
    "disallowedTools: [\(removableSourceGroups.sorted().joined(separator: ", "))]"

  /// The key of a session agent that denies the `files` group only.
  private static let filesDenial = "disallowedTools: [\(filesName)]"

  /// The key of a session agent that keeps the `agents` and `kanban` tools
  /// only.
  private static let agentsAndKanbanOnly = "tools: [\(agentsName), kanban]"

  /// The text of the file that a resource link of a session names.
  private static let linkedFileContent = "the text of the linked file"

  /// The name of the file that a resource link of a session names.
  private static let linkedFileName = "linked.txt"

  /// The task that the `searchTools` tests give: one that the files read
  /// verb answers.
  private static let readFileTask = "read a file"

  /// The answer of the flash slot to each selection of `searchTools`: the
  /// one id of the files read verb.
  private static let filesReadSelectionJSON = #"{"ids":["\#(ToolCatalog.filesReadVerbPath)"]}"#

  /// The spellings of `model: flash` in other letter cases.
  private static let flashSpellings = ["Flash", "FLASH"]

  /// The name of the `agents` tool.
  private static let agentsName = "agents"

  /// The names that always stay on the surface of a root session: the tools
  /// that give an endpoint (D90 (c)), and `searchTools`, the discovery half
  /// of `runCode`. `files` is not one of them: a session agent can deny it.
  /// The test keeps its own copy of the list.
  private static let alwaysOnNames: Set<String> = [
    "agents", "skills", "sessions", "kanban", "rules", "settings", "runCode", "searchTools",
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

  /// The key of the tool groups in a skills template context.
  private static let templateToolsKey = "tools"

  /// The key of the value of one tool group in a skills template context.
  private static let templateEnabledKey = "enabled"

  /// The template group of the MCP tools.
  private static let mcpTemplateGroup = "mcp"

  /// The name of one tool of an MCP server, as a run resolves it.
  private static let mcpToolName = "mcp__probe__ping"

  /// The template group of the code context tools. Its surface name is
  /// ``ToolCatalog/codeContextGroupName``.
  private static let codeContextTemplateGroup = "codeContext"

  /// The id of the preloaded skill that renders the shell value.
  private static let probeSkillID = "probe-tools"

  /// The text that the probe skill renders when the shell value is `false`.
  private static let shellOffMarker = "PROBE-SHELL-OFF"

  /// The `SKILL.md` of the probe skill: a preloaded skill whose body tells
  /// the value of `tools.shell.enabled`.
  private static let probeSkillMarkdown = """
    ---
    name: \(probeSkillID)
    description: Tells the shell value.
    preload: true
    ---

    {% if tools.shell.enabled %}PROBE-SHELL-ON{% else %}\(shellOffMarker){% endif %}
    """

  /// The text that the body of the session agent renders when the shell
  /// value is `true`.
  private static let bodyShellOnMarker = "BODY-SHELL-ON"

  /// The text that the body of the session agent renders when the shell
  /// value is `false`.
  private static let bodyShellOffMarker = "BODY-SHELL-OFF"

  /// A body of the session agent that tells the value of
  /// `tools.shell.enabled`.
  private static let shellGatedBody =
    "{% if tools.shell.enabled %}\(bodyShellOnMarker){% else %}\(bodyShellOffMarker){% endif %}"

  // MARK: - Helpers

  /// Writes the session agent `<cwd>/AGENT.md` with `keys` in its
  /// frontmatter.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines after `name` and `description`.
  ///   - body: The body of the agent. `AgentFolderFixture.defaultBody` by
  ///     default.
  ///   - cwd: The working directory.
  /// - Throws: The write error.
  private static func writeSessionAgent(
    keys: [String], body: String = AgentFolderFixture.defaultBody, in cwd: URL
  ) throws {
    try AgentFolderFixture.document(
      id: sessionAgentID, description: "The probe session agent.", extraKeys: keys, body: body
    ).write(
      to: cwd.appendingPathComponent(AgentFolderFixture.documentName), atomically: true,
      encoding: .utf8)
  }

  /// The session agent `<folder>/AGENT.md` with `keys`, as a definition.
  ///
  /// - Parameter keys: The frontmatter lines after `name` and `description`.
  /// - Returns: The definition.
  /// - Throws: The write error, or when the document does not load.
  static func definition(keys: [String]) throws -> AgentDefinition {
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

  /// A session agent with `tools: [web]` gives the model `web`, and no
  /// `files`, `shell`, `git` or `environment`: `files` gives no endpoint,
  /// thus `tools:` can leave it out.
  @Test func toolsWebGivesTheModelWebOnly() throws {
    let selection = SessionToolSelection(
      definition: try Self.definition(keys: ["tools: [web]"]),
      names: Self.surfaceNames + [Self.gitName, Self.environmentName])

    #expect(selection.keptNames.intersection(Self.webCheckNames) == [Self.webName])
  }

  /// A session agent with ``agentsAndKanbanOnly`` has no `files` group in
  /// the registry of its root `runCode`.
  @Test func toolsAgentsAndKanbanLeaveNoFilesGroup() async throws {
    let sessions = try await Self.openSessions(keys: [Self.agentsAndKanbanOnly], name: "kanban")

    #expect(!(try Self.capabilities(of: sessions.agent.surface).contains(Self.filesName)))
  }

  /// A session agent with no `tools:` has the full surface, as a session
  /// with no session agent has.
  @Test func noToolsKeyKeepsTheFullSurface() async throws {
    let sessions = try await Self.openSessions(keys: [], name: "full")

    #expect(
      try Self.capabilities(of: sessions.agent.surface)
        == Self.capabilities(of: sessions.plain.surface))
  }

  /// A session agent with no `tools:` and no `disallowedTools:` has the
  /// `files` group in the registry of its root `runCode`.
  @Test func noKeysKeepTheFilesGroup() async throws {
    let sessions = try await Self.openSessions(keys: [], name: "files-on")

    #expect(try Self.capabilities(of: sessions.agent.surface).contains(Self.filesName))
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

  /// A session agent with `disallowedTools: [skills]` still has the `skills`
  /// tool: `skills` gives an endpoint (D90 (c)), thus the selection of a root
  /// session cannot remove it. A run has no endpoint, and loses the tool.
  @Test func disallowedSkillsStaysInTheRootSession() async throws {
    let skills = SkillOutputProtection.skillsToolName
    let sessions = try await Self.openSessions(
      keys: [AgentToolKeys.noSkills], name: "skills")

    #expect(sessions.agent.surface.tools.map(\.name).contains(skills))
  }

  /// A session agent with ``sourceGroupsDenial`` has no `files`, `shell`,
  /// `code_context`, `web` or `git` in the registry of its root `runCode`,
  /// and each other capability of the full surface.
  @Test func disallowedSourceGroupsLeaveTheRootRunCode() async throws {
    let sessions = try await Self.openSessions(keys: [Self.sourceGroupsDenial], name: "nosource")

    let plain = try Self.capabilities(of: sessions.plain.surface)
    #expect(
      try Self.capabilities(of: sessions.agent.surface)
        == plain.subtracting(Self.removableSourceGroups),
      "full surface: \(plain)")
  }

  /// A session agent with ``filesDenial`` has no `files` in the registry of
  /// its root `runCode`: `files` gives no endpoint, thus the agent can deny
  /// it.
  @Test func disallowedFilesLeavesTheRootRunCode() async throws {
    let sessions = try await Self.openSessions(keys: [Self.filesDenial], name: "files")

    #expect(!(try Self.capabilities(of: sessions.agent.surface).contains(Self.filesName)))
  }

  /// The answer of the root `searchTools` of a session surface with the
  /// session agent `keys` applied, for ``readFileTask``. The flash slot of
  /// the profile answers each selection of `searchTools` with
  /// ``filesReadSelectionJSON``, thus the answer names the files read verb
  /// when the registry of the surface holds it.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the session agent, or `nil` for no
  ///     session agent: the full surface.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The text of the answer.
  /// - Throws: What the surface build, the selection or the search throws,
  ///   or when the surface has no `searchTools`.
  private static func searchAnswer(keys: [String]?, name: String) async throws -> String {
    let context = try await AgentsToolTests.makeContext(
      label: "\(label)-\(name)", script: [.textDelta(filesReadSelectionJSON), .endPass])
    let full = try await ToolCatalog.sessionSurface(context: context)
    let surface = try await full.applying(agent: try keys.map(definition(keys:)))
    let searchTools = try #require(surface.tools.compactMap { $0 as? SearchToolsTool }.first)
    let answer = try await searchTools.call(arguments: SearchToolsArguments(task: readFileTask))
    await surface.shutdown()
    return answer
  }

  /// The root `searchTools` of a session with no session agent finds the
  /// files read verb: the proof that ``disallowedFilesLeavesSearchTools``
  /// can see the verb.
  @Test func searchToolsOfAPlainSessionFindsTheFilesReadVerb() async throws {
    let answer = try await Self.searchAnswer(keys: nil, name: "search-plain")

    #expect(answer.contains(ToolCatalog.filesReadVerbPath), "\(answer)")
  }

  /// The root `searchTools` of a session agent with ``filesDenial`` does not
  /// find the files read verb: it reads the registry of the root `runCode`.
  @Test func disallowedFilesLeavesSearchTools() async throws {
    let answer = try await Self.searchAnswer(keys: [Self.filesDenial], name: "search-files")

    #expect(!answer.contains(ToolCatalog.filesReadVerbPath), "\(answer)")
  }

  /// A session agent with ``filesDenial`` still resolves a resource link of
  /// the prompt to the text of the file: the read verb of the resource
  /// links comes from the full registry, not from the model's tools.
  @Test func disallowedFilesKeepsTheResourceLinks() async throws {
    let routed = try await AgentClientHarness.makeInitializedAgent(label: Self.label)
    let cwd = makeResolvedDirectory(label: "\(Self.label)-links")
    try Self.writeSessionAgent(keys: [Self.filesDenial], in: cwd)
    let file = cwd.appendingPathComponent(Self.linkedFileName)
    try Self.linkedFileContent.write(to: file, atomically: true, encoding: .utf8)
    let entry = try await Self.openSession(in: cwd, on: routed)

    let resolved = await ResourceLinkResolver(readVerb: entry.surface.filesReadVerb)
      .resolve(uri: file.absoluteString)

    #expect(resolved == Self.linkedFileContent)
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

  // MARK: - The skills template values

  /// The `tools.<group>.enabled` values of a skill render for the session
  /// agent `keys`, in `mode`, over the in-code configuration.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the session agent, or `nil` for no
  ///     session agent: the values of the configuration alone.
  ///   - mode: The tool mode of the session.
  /// - Returns: The value of each group, by its name.
  /// - Throws: The write error, or when the session agent does not load.
  private static func templateValues(keys: [String]?, mode: ToolMode = .open) throws
    -> [String: Bool]
  {
    enabledValues(
      of: ToolCatalog.skillsTemplateContext(
        AgentConfiguration.withoutMarketplaces.tools, mode: mode,
        sessionAgent: try keys.map(definition(keys:))))
  }

  /// The `tools.<group>.enabled` values of a template context.
  ///
  /// - Parameter context: The template context.
  /// - Returns: The value of each group, by its name. A group with no
  ///   Boolean `enabled` value is not in the result.
  private static func enabledValues(of context: [String: TemplateValue]) -> [String: Bool] {
    guard case .dictionary(let groups)? = context[templateToolsKey] else {
      return [:]
    }
    return groups.compactMapValues { group in
      guard case .dictionary(let entry) = group, case .bool(let isOn)? = entry[templateEnabledKey]
      else {
        return nil
      }
      return isOn
    }
  }

  /// A session agent with `tools: [web]` renders `tools.web.enabled` as
  /// `true`.
  @Test func toolsWebKeepsTheWebTemplateValueOn() throws {
    #expect(try Self.templateValues(keys: ["tools: [web]"])[Self.webName] == true)
  }

  /// A session agent with `tools: [web]` renders `tools.shell.enabled` as
  /// `false`.
  @Test func toolsWebTurnsTheShellTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: ["tools: [web]"])[Self.shellName] == false)
  }

  /// A session agent with `tools: [web]` renders `tools.files.enabled` as
  /// `false`: `files` gives no endpoint, thus `tools:` can leave it out.
  @Test func toolsWebTurnsTheFilesTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: ["tools: [web]"])[Self.filesName] == false)
  }

  /// A session agent with `tools: [web]` renders `tools.mcp.enabled` as
  /// `false`: the selection keeps no MCP tool.
  @Test func toolsWebTurnsTheMCPTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: ["tools: [web]"])[Self.mcpTemplateGroup] == false)
  }

  /// A session agent with `tools: [web, "mcp__*"]` renders
  /// `tools.mcp.enabled` as `true`.
  @Test func anMCPEntryKeepsTheMCPTemplateValueOn() throws {
    #expect(
      try Self.templateValues(keys: ["tools: [web, \"mcp__*\"]"])[Self.mcpTemplateGroup] == true)
  }

  /// A session agent with `disallowedTools: [shell]` renders
  /// `tools.shell.enabled` as `false`.
  @Test func disallowedShellTurnsTheShellTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: ["disallowedTools: [shell]"])[Self.shellName] == false)
  }

  /// A session agent with `tools: [shell]` in the `sandboxed` mode renders
  /// `tools.shell.enabled` as `false`: the mode gives no shell.
  @Test func toolsShellInTheSandboxedModeKeepsTheShellTemplateValueOff() throws {
    #expect(
      try Self.templateValues(keys: ["tools: [shell]"], mode: .sandboxed)[Self.shellName] == false)
  }

  /// A session agent with no `tools:` and no `disallowedTools:` renders the
  /// values of the configuration alone.
  @Test func noToolsKeyKeepsTheTemplateValuesOfTheConfiguration() throws {
    #expect(try Self.templateValues(keys: []) == Self.templateValues(keys: nil))
  }

  /// A session agent with `tools: [code_context]` in the `open` mode renders
  /// `tools.codeContext.enabled` as `true`: the selection reads the surface
  /// name of the group, not its template key.
  @Test func toolsCodeContextKeepsTheCodeContextTemplateValueOn() throws {
    #expect(
      try Self.templateValues(keys: ["tools: [\(ToolCatalog.codeContextGroupName)]"])[
        Self.codeContextTemplateGroup] == true)
  }

  /// A session agent with `disallowedTools: [code_context]` in the `open`
  /// mode renders `tools.codeContext.enabled` as `false`: the selection
  /// removes the group by its surface name.
  @Test func disallowedCodeContextTurnsTheCodeContextTemplateValueOff() throws {
    #expect(
      try Self.templateValues(keys: ["disallowedTools: [\(ToolCatalog.codeContextGroupName)]"])[
        Self.codeContextTemplateGroup] == false)
  }

  /// A session agent with `disallowedTools: [web]` renders
  /// `tools.web.enabled` as `false`.
  @Test func disallowedWebTurnsTheWebTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: ["disallowedTools: [web]"])[Self.webName] == false)
  }

  /// A session agent with `tools: [shell]` in the `open` mode renders
  /// `tools.shell.enabled` as `true`.
  @Test func toolsShellInTheOpenModeKeepsTheShellTemplateValueOn() throws {
    #expect(try Self.templateValues(keys: ["tools: [shell]"])[Self.shellName] == true)
  }

  /// A session agent with ``filesDenial`` renders `tools.files.enabled` as
  /// `false`.
  @Test func disallowedFilesTurnsTheFilesTemplateValueOff() throws {
    #expect(try Self.templateValues(keys: [Self.filesDenial])[Self.filesName] == false)
  }

  /// A session agent with no `tools:` and no `disallowedTools:` renders
  /// `tools.files.enabled` as `true`, the value of the configuration.
  @Test func noKeysKeepTheFilesTemplateValueOn() throws {
    #expect(try Self.templateValues(keys: [])[Self.filesName] == true)
  }

  /// A run agent with ``filesDenial`` gets `tools.files.enabled` as
  /// `false`.
  @Test func aRunWithDisallowedFilesGetsTheFilesTemplateValueOff() throws {
    #expect(
      try Self.runTemplateValues(keys: [Self.filesDenial], toolNames: Self.surfaceNames)[
        Self.filesName] == false)
  }

  /// The `tools.<group>.enabled` values that the run closure of the agent
  /// environment gives for a run agent with `keys` and the resolved tool
  /// names `toolNames`.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the run agent.
  ///   - toolNames: The names of the resolved tools of the run.
  /// - Returns: The value of each group, by its name.
  /// - Throws: The write error, or when the agent does not load.
  private static func runTemplateValues(keys: [String], toolNames: [String]) throws
    -> [String: Bool]
  {
    let closure = ToolCatalog.runTemplateContext(
      AgentConfiguration.withoutMarketplaces.tools, mode: .open)
    return enabledValues(of: closure(try definition(keys: keys), toolNames))
  }

  /// A run agent with `tools: [web]` gets `tools.shell.enabled` as `false`.
  @Test func aRunWithToolsWebGetsTheShellTemplateValueOff() throws {
    #expect(try Self.runTemplateValues(keys: ["tools: [web]"], toolNames: [])[Self.shellName] == false)
  }

  /// A run agent with `tools: [web]` gets `tools.web.enabled` as `true`.
  @Test func aRunWithToolsWebGetsTheWebTemplateValueOn() throws {
    #expect(try Self.runTemplateValues(keys: ["tools: [web]"], toolNames: [])[Self.webName] == true)
  }

  /// A run agent with no `tools:` key gets the values of the configuration.
  @Test func aRunWithNoToolsKeyGetsTheTemplateValuesOfTheConfiguration() throws {
    #expect(
      try Self.runTemplateValues(keys: [], toolNames: Self.surfaceNames)
        == Self.templateValues(keys: nil))
  }

  /// A run whose resolved tools hold one MCP tool gets `tools.mcp.enabled`
  /// as `true`.
  @Test func aRunWithAResolvedMCPToolGetsTheMCPTemplateValueOn() throws {
    #expect(
      try Self.runTemplateValues(
        keys: ["tools: [\(Self.mcpToolName)]"], toolNames: [Self.mcpToolName])[
          Self.mcpTemplateGroup] == true)
  }

  /// A composed session whose session agent has `disallowedTools: [shell]`
  /// renders a preloaded skill with `tools.shell.enabled` as `false`.
  @Test func aComposedSessionRendersASkillWithTheSelectionOfTheSessionAgent() async throws {
    let routed = try await AgentClientHarness.makeInitializedAgent(label: Self.label)
    let cwd = makeResolvedDirectory(label: "\(Self.label)-skill")
    try Self.writeSessionAgent(keys: ["disallowedTools: [shell]"], in: cwd)
    try writeSkillFixture(
      id: Self.probeSkillID, markdown: Self.probeSkillMarkdown,
      under: cwd.appendingPathComponent(".\(ToolCatalog.skillsDotfolderName)", isDirectory: true))
    let loaded = try await LoadedSessionContext.load(
      workingDirectory: cwd, from: routed.settingsStore)

    let composition = try await routed.composeSession(
      from: loaded, workingDirectory: cwd, additionalRoots: [], clientMCPServers: [],
      userPresence: .headless)
    await composition.surface.shutdown()

    #expect(composition.instructions.contains(Self.shellOffMarker), "\(composition.instructions)")
  }

  /// Composes one session in a fresh working directory whose session agent
  /// has `keys` and the body ``shellGatedBody``.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the session agent.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The instructions of the composed session.
  /// - Throws: What the agent or the composition throws.
  private static func instructionsOfShellGatedSessionAgent(keys: [String], name: String)
    async throws -> String
  {
    let routed = try await AgentClientHarness.makeInitializedAgent(label: label)
    let cwd = makeResolvedDirectory(label: "\(label)-\(name)")
    try writeSessionAgent(keys: keys, body: shellGatedBody, in: cwd)
    let loaded = try await LoadedSessionContext.load(
      workingDirectory: cwd, from: routed.settingsStore)
    let composition = try await routed.composeSession(
      from: loaded, workingDirectory: cwd, additionalRoots: [], clientMCPServers: [],
      userPresence: .headless)
    await composition.surface.shutdown()
    return composition.instructions
  }

  /// A session agent with `disallowedTools: [shell]` renders its own body
  /// with `tools.shell.enabled` as `false`.
  @Test func disallowedShellRendersTheBodyOfTheSessionAgentWithTheShellOff() async throws {
    let instructions = try await Self.instructionsOfShellGatedSessionAgent(
      keys: ["disallowedTools: [shell]"], name: "body-disallowed")

    #expect(instructions.contains(Self.bodyShellOffMarker), "\(instructions)")
  }

  /// A session agent with no `tools:` key renders its own body with the
  /// values of the configuration: the shell is on in the `open` mode.
  @Test func noToolsKeyRendersTheBodyOfTheSessionAgentWithTheConfiguredShell() async throws {
    let instructions = try await Self.instructionsOfShellGatedSessionAgent(
      keys: [], name: "body-plain")

    #expect(instructions.contains(Self.bodyShellOnMarker), "\(instructions)")
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

  /// The selection of ``sourceGroupsDenial`` removes the `code_context`
  /// group from a registry of the root `runCode`. The stub session mounts
  /// no code context, thus this test gives the registry a probe group.
  @Test func disallowedCodeContextLeavesTheRegistry() throws {
    let registry = try MultiTool.Builder(mode: .open).withEnvironment().addGroup(
      named: ToolCatalog.codeContextGroupName, [CodeContextProbeTool()]
    ).buildRegistry()
    let selection = RegistrySelection(
      definition: try Self.definition(keys: [Self.sourceGroupsDenial]), topLevelNames: [],
      mcpServerNames: [])

    #expect(
      Set(selection.applied(to: registry).surface.entries.compactMap(\.group))
        == [Self.environmentName])
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

/// A tool of the probe `code_context` group of a registry.
private struct CodeContextProbeTool: FoundationModels.Tool {
  /// The wire arguments; the tool reads nothing from them.
  @Generable
  struct Arguments {}

  let name = "probe_symbol"

  let description = "a probe of the code context group"

  func call(arguments: Arguments) async throws -> String {
    name
  }
}
