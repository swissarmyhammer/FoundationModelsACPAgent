import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The tool mode of the host (ACPA-19b, D128 (d), D131).
///
/// In the `sandboxed` mode a session gets no tool that starts a child
/// process: no shell, no stdio MCP server and no code context. In the `open`
/// mode a session gets the same tools as before the mode. The composition
/// checks the mode against the sandbox probe before it registers a tool.
///
/// The skills of a session get the same mode (ACPA-19d): in the `sandboxed`
/// mode the `skills` tool has no `run script` operation, a shell injection of
/// a skill body stays as text, and the template values of a skill tell that
/// the shell and the code context are off.
///
/// Each case builds the catalog registry of one session over the stub
/// profile, or makes one stub agent. No case needs the network.
@Suite struct ToolModeTests {
  /// The noun that the shell capability owns on the surface.
  private static let shellNoun = "shell"

  /// The prefix of each verb of the code context group.
  private static let codeContextPrefix = "\(ToolCatalog.codeContextGroupName)."

  /// The name of the stdio MCP server of the configuration.
  private static let stdioServerName = "local"

  /// The name of the http MCP server of a client.
  private static let httpServerName = "remote"

  /// The url of the http MCP server of a client. No case connects to it.
  private static let httpServerURL = "https://example.test/mcp"

  /// The `--mode` flag of the `mcp-test-server` executable.
  private static let serverModeFlag = "--mode"

  /// The mode of the `mcp-test-server` executable that registers the echo
  /// tool alone.
  private static let serverEchoMode = "echo"

  /// The file name of the marker that the marker script writes when it
  /// starts.
  private static let markerFileName = "started"

  /// The file name of the marker script.
  private static let markerScriptName = "marker-server.sh"

  /// The POSIX permissions of the marker script: read, write and execute
  /// for the owner, read and execute for the others.
  private static let executablePermissions = 0o755

  /// The label of each throwaway folder of this suite.
  private static let label = "ToolModeTests"

  /// The name of the `skills` tool on the session surface.
  private static let skillsToolName = "skills"

  /// The op string of the `run script` operation of the `skills` tool.
  private static let runScriptOp = "run script"

  /// The op string of the `use skill` operation of the `skills` tool.
  private static let useSkillOp = "use skill"

  /// The id of the fixture skill, which is also its directory name.
  private static let scriptSkillID = "mode-fixture"

  /// The inline shell injection of the body of the fixture skill. In the
  /// `open` mode a render replaces it with the output of the command.
  private static let shellInjection = "!`echo MODE-FIXTURE-OUTPUT`"

  /// The `SKILL.md` text of the fixture skill.
  private static let scriptSkillMarkdown = """
    ---
    description: A skill with a script and a shell injection.
    ---
    Injection: \(shellInjection)
    """

  /// The path of the script of the fixture skill, under its directory.
  private static let scriptPath = "scripts/run.sh"

  /// The text of the script of the fixture skill. No case runs it.
  private static let scriptText = "#!/bin/sh\necho run\n"

  /// The key of the tool groups in the template values of a skill render.
  private static let toolsTemplateKey = "tools"

  /// The key of the on state of one tool group in the template values.
  private static let enabledTemplateKey = "enabled"

  /// The tool group of the shell in the template values.
  private static let shellTemplateGroup = "shell"

  /// The tool group of the code context in the template values.
  private static let codeContextTemplateGroup = "codeContext"

  /// The download URL of OpenTestudo that the host of a case gives.
  private static let openTestudoDownloadURL = URL(string: "https://example.test/opentestudo")!

  // MARK: - Harness

  /// Composes a stub agent in the `sandboxed` mode with
  /// ``openTestudoDownloadURL``, and runs `initialize`.
  ///
  /// - Returns: The composition.
  /// - Throws: Whatever the composition or the handshake throws.
  private static func composeSandboxedAgent() async throws -> ComposedAgent {
    let composed = try await composeStubAgent(
      name: label, label: label, mode: .sandboxed, sandboxProbe: .fixed(true),
      openTestudoDownloadURL: openTestudoDownloadURL)
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    return composed
  }

  /// Makes a configuration with the shell and the code context on, and with
  /// `servers` as the `mcp:` section.
  ///
  /// - Parameter servers: The config-derived MCP servers. None by default.
  /// - Returns: The configuration under test.
  private static func makeConfiguration(
    servers: [MCPServerConfiguration] = []
  ) -> AgentConfiguration {
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.shell = .enabled(ShellToolOptions())
    configuration.tools.codeContext = .enabled(CodeContextToolOptions())
    configuration.tools.mcp = .enabled(servers: servers)
    return configuration
  }

  /// Builds the catalog registry of one session in `mode` over a new
  /// working directory.
  ///
  /// - Parameters:
  ///   - mode: The tool mode of the session.
  ///   - configuration: The configuration under test.
  /// - Returns: The built registry.
  /// - Throws: Whatever the registry build throws.
  private static func makeBuiltRegistry(
    mode: ToolMode, configuration: AgentConfiguration = makeConfiguration()
  ) async throws -> ToolCatalog.BuiltRegistry {
    try await CatalogRegistryFixture.makeBuiltRegistry(
      workingDirectory: makeResolvedDirectory(label: "\(label)-work"),
      configuration: configuration, mode: mode)
  }

  /// Makes the catalog context of one session in `mode` over a new working
  /// directory, with the configuration of ``makeConfiguration(servers:)``.
  ///
  /// - Parameter mode: The tool mode of the session.
  /// - Returns: The catalog context.
  /// - Throws: Whatever the context fixture throws.
  private static func makeContext(mode: ToolMode) async throws -> CatalogContext {
    try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeResolvedDirectory(label: "\(label)-context"),
      configuration: makeConfiguration(), mode: mode)
  }

  /// Gives back every lease and stops every process of `built`.
  ///
  /// - Parameter built: The built registry of a case.
  private static func release(_ built: ToolCatalog.BuiltRegistry) async {
    await built.codeContextLease?.release()
    await built.shellStoreLease?.release()
    await built.pool.shutdownAll()
  }

  /// Writes a script that writes a marker file when it starts, and then
  /// runs the `mcp-test-server` executable with its arguments. A stdio MCP
  /// server over the script shows if the composition started its process.
  /// In the `open` mode the server connects, thus the build does not wait
  /// for a server that never answers.
  ///
  /// - Returns: The script and the marker file that it writes.
  /// - Throws: Whatever the search for the server or the write of the
  ///   script throws.
  private static func makeMarkerScript() throws -> (script: URL, marker: URL) {
    let directory = makeResolvedDirectory(label: "\(label)-marker")
    let marker = directory.appendingPathComponent(markerFileName)
    let script = directory.appendingPathComponent(markerScriptName)
    let server = try BuiltProductLocator.mcpTestServerURL().path
    try "#!/bin/sh\ntouch '\(marker.path)'\nexec '\(server)' \"$@\"\n".write(
      to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: executablePermissions], ofItemAtPath: script.path)
    return (script, marker)
  }

  /// A config-derived stdio MCP server over `command`.
  ///
  /// - Parameter command: The absolute path of the executable.
  /// - Returns: The server entry.
  private static func stdioServer(command: String) -> MCPServerConfiguration {
    MCPServerConfiguration(
      name: stdioServerName,
      transport: .stdio(command: command, args: [serverModeFlag, serverEchoMode], env: [:]))
  }

  /// A client-supplied stdio MCP server. No case starts it.
  private static let clientStdioServer = FoundationModelsACP.MCPServer.stdio(
    MCPServerStdio(command: AbsolutePath(rawValue: "/bin/echo"), name: stdioServerName))

  /// A client-supplied http MCP server. No case connects to it.
  private static let clientHTTPServer = FoundationModelsACP.MCPServer.http(
    MCPServerHTTP(name: httpServerName, url: httpServerURL, headers: []))

  /// Makes a stub agent in `mode` with `probe`.
  ///
  /// - Parameters:
  ///   - mode: The tool mode of the agent.
  ///   - probe: The sandbox probe of the agent.
  /// - Returns: The agent.
  /// - Throws: Whatever the agent construction throws.
  private static func makeAgent(mode: ToolMode, probe: SandboxProbe) async throws
    -> RoutedACPAgent
  {
    try await makeStubAgent(
      name: label, cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
      mode: mode, sandboxProbe: probe)
  }

  /// Makes the catalog context of one session of `agent`, the way
  /// `session/new` makes it.
  ///
  /// - Parameter agent: The agent of the session.
  /// - Returns: The catalog context.
  /// - Throws: Whatever the load of the session configuration throws.
  private static func makeSessionContext(of agent: RoutedACPAgent) async throws -> CatalogContext {
    let workspace = makeResolvedDirectory(label: "\(label)-session")
    let loaded = try await agent.loadSessionContext(workingDirectory: workspace)
    return await agent.catalogContext(
      from: loaded, workingDirectory: workspace, additionalRoots: [], clientMCPServers: [],
      userPresence: .headless)
  }

  /// Makes a working directory whose project skills layer holds the
  /// fixture skill: a `SKILL.md` with a shell injection, and a script.
  ///
  /// - Returns: The working directory.
  /// - Throws: Whatever a file write throws.
  private static func makeSkillsWorkspace() throws -> URL {
    let workspace = makeResolvedDirectory(label: "\(label)-skills")
    let skillsRoot = workspace.appendingPathComponent(
      ".\(ToolCatalog.skillsDotfolderName)", isDirectory: true)
    try writeSkillFixture(id: scriptSkillID, markdown: scriptSkillMarkdown, under: skillsRoot)
    let script = skillsRoot.appendingPathComponent(scriptSkillID, isDirectory: true)
      .appendingPathComponent(scriptPath, isDirectory: false)
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try scriptText.write(to: script, atomically: true, encoding: .utf8)
    return workspace
  }

  /// Makes the session surface in `mode` over a workspace that holds the
  /// fixture skill, and gives its `skills` tool. The shell and the code
  /// context are off, thus the open mode starts no child process of a
  /// tool group. The surface is shut down before the return.
  ///
  /// - Parameter mode: The tool mode of the session.
  /// - Returns: The `skills` tool of the session.
  /// - Throws: Whatever the context, the surface, or the search for the
  ///   tool throws.
  private static func makeSessionSkillsTool(mode: ToolMode) async throws -> SkillsCatalogTool {
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.shell = .disabled
    configuration.tools.codeContext = .disabled
    let context = try await CatalogRegistryFixture.makeContext(
      workingDirectory: makeSkillsWorkspace(), configuration: configuration, mode: mode)
    let surface = try await ToolCatalog.sessionSurface(context: context)
    await surface.shutdown()
    let tool = surface.tools.first { $0.name == skillsToolName }
    return try #require(tool as? SkillsCatalogTool)
  }

  /// The op strings of the operations of a `skills` tool.
  ///
  /// - Parameter tool: The `skills` tool.
  /// - Returns: The op strings, in tool order.
  private static func opStrings(of tool: SkillsCatalogTool) -> [String] {
    tool.operationDescriptors.map(\.opString)
  }

  /// The text of a `use skill` call of the fixture skill.
  ///
  /// - Parameter tool: The `skills` tool.
  /// - Returns: The answer of the tool.
  /// - Throws: Whatever the call throws.
  private static func useScriptSkill(with tool: SkillsCatalogTool) async throws -> String {
    try await tool.call(
      arguments: GeneratedContent(properties: ["op": useSkillOp, "id": scriptSkillID]))
  }

  /// The `tools.<group>.enabled` value of the template values of a skill
  /// render.
  ///
  /// - Parameters:
  ///   - group: The tool group.
  ///   - values: The template values.
  /// - Returns: The value, or `nil` when the values have no such entry.
  private static func isEnabled(
    _ group: String, in values: [String: TemplateValue]
  ) -> Bool? {
    if case .dictionary(let groups)? = values[toolsTemplateKey],
      case .dictionary(let entry)? = groups[group],
      case .bool(let isOn)? = entry[enabledTemplateKey]
    {
      return isOn
    }
    return nil
  }

  // MARK: - The sandboxed mode

  @Test func theSandboxedModeMountsNoShellVerb() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .sandboxed)
    await Self.release(built)

    #expect(!built.registry.surface.entries.contains { $0.group == Self.shellNoun })
  }

  @Test func theSandboxedModeLeasesNoShellStore() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .sandboxed)
    await Self.release(built)

    #expect(built.shellStoreLease == nil)
  }

  @Test func theSandboxedModeMountsNoCodeContextVerb() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .sandboxed)
    await Self.release(built)

    #expect(!built.registry.surface.entries.contains { $0.path.hasPrefix(Self.codeContextPrefix) })
  }

  @Test func theSandboxedModeLeasesNoCodeContext() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .sandboxed)
    await Self.release(built)

    #expect(built.codeContextLease == nil)
  }

  @Test func theSandboxedModeStartsNoStdioServerProcess() async throws {
    let (script, marker) = try Self.makeMarkerScript()
    let configuration = Self.makeConfiguration(servers: [Self.stdioServer(command: script.path)])

    let built = try await Self.makeBuiltRegistry(mode: .sandboxed, configuration: configuration)
    await Self.release(built)

    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func theSandboxedModeGivesNoChildProcessOptions() async throws {
    let context = try await Self.makeContext(mode: .sandboxed)

    #expect(
      ToolCatalog.childProcessOptions(of: context.configuration.tools.shell, in: context) == nil)
  }

  @Test func theSandboxedModeRecordsTheRefusalOfAConfigStdioServer() async throws {
    let (script, _) = try Self.makeMarkerScript()
    let configuration = Self.makeConfiguration(servers: [Self.stdioServer(command: script.path)])

    let built = try await Self.makeBuiltRegistry(mode: .sandboxed, configuration: configuration)
    await Self.release(built)

    #expect(
      built.mcpServerOutcomes == [
        MCPComposition.ServerOutcome(
          name: Self.stdioServerName, transport: .stdio, origin: .config,
          result: .failed(reason: .stdioInSandboxedMode))
      ])
  }

  @Test func theSandboxedRosterRefusesAClientStdioServer() {
    let roster = MCPComposition.composeRoster(
      mode: .sandboxed, section: .enabled(servers: []), clientServers: [Self.clientStdioServer])

    #expect(roster.refusals == [.stdioInSandboxedMode(serverName: Self.stdioServerName)])
  }

  @Test func theSandboxedRosterKeepsAClientHTTPServer() {
    let roster = MCPComposition.composeRoster(
      mode: .sandboxed, section: .enabled(servers: []), clientServers: [Self.clientHTTPServer])

    #expect(roster.entries.map(\.configuration.name) == [Self.httpServerName])
  }

  @Test func theSandboxedSkillsToolHasNoRunScriptOperation() async throws {
    let tool = try await Self.makeSessionSkillsTool(mode: .sandboxed)

    #expect(!Self.opStrings(of: tool).contains(Self.runScriptOp))
  }

  @Test func theSandboxedSkillsToolKeepsTheShellInjectionAsText() async throws {
    let tool = try await Self.makeSessionSkillsTool(mode: .sandboxed)

    let text = try await Self.useScriptSkill(with: tool)

    #expect(text.contains(Self.shellInjection))
  }

  @Test func theSandboxedTemplateValuesTurnTheShellOff() {
    let values = ToolCatalog.skillsTemplateContext(
      Self.makeConfiguration().tools, mode: .sandboxed)

    #expect(Self.isEnabled(Self.shellTemplateGroup, in: values) == false)
  }

  @Test func theSandboxedTemplateValuesTurnTheCodeContextOff() {
    let values = ToolCatalog.skillsTemplateContext(
      Self.makeConfiguration().tools, mode: .sandboxed)

    #expect(Self.isEnabled(Self.codeContextTemplateGroup, in: values) == false)
  }

  // MARK: - The open mode

  @Test func theOpenModeMountsTheShellVerbs() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .open)
    await Self.release(built)

    #expect(built.registry.surface.entries.contains { $0.group == Self.shellNoun })
  }

  @Test func theOpenModeMountsTheCodeContextVerbs() async throws {
    let built = try await Self.makeBuiltRegistry(mode: .open)
    await Self.release(built)

    #expect(built.registry.surface.entries.contains { $0.path.hasPrefix(Self.codeContextPrefix) })
  }

  @Test func theOpenModeConnectsAStdioServer() async throws {
    let command = try BuiltProductLocator.mcpTestServerURL().path
    let configuration = Self.makeConfiguration(servers: [Self.stdioServer(command: command)])

    let built = try await Self.makeBuiltRegistry(mode: .open, configuration: configuration)
    await Self.release(built)

    #expect(built.mcpServerOutcomes.map(\.result) == [.connected])
  }

  @Test func theOpenModeStartsTheStdioServerProcess() async throws {
    let (script, marker) = try Self.makeMarkerScript()
    let configuration = Self.makeConfiguration(servers: [Self.stdioServer(command: script.path)])

    let built = try await Self.makeBuiltRegistry(mode: .open, configuration: configuration)
    await Self.release(built)

    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func theOpenModeGivesTheOptionsOfAnEnabledSection() async throws {
    let context = try await Self.makeContext(mode: .open)

    #expect(
      ToolCatalog.childProcessOptions(of: context.configuration.tools.shell, in: context)
        == ShellToolOptions())
  }

  @Test func theOpenModeGivesNoOptionsOfADisabledSection() async throws {
    let context = try await Self.makeContext(mode: .open)

    #expect(
      ToolCatalog.childProcessOptions(of: ToolSection<ShellToolOptions>.disabled, in: context)
        == nil)
  }

  @Test func theOpenRosterKeepsAClientStdioServer() {
    let roster = MCPComposition.composeRoster(
      mode: .open, section: .enabled(servers: []), clientServers: [Self.clientStdioServer])

    #expect(roster.entries.map(\.configuration.name) == [Self.stdioServerName])
  }

  @Test func theOpenSkillsToolHasTheRunScriptOperation() async throws {
    let tool = try await Self.makeSessionSkillsTool(mode: .open)

    #expect(Self.opStrings(of: tool).contains(Self.runScriptOp))
  }

  @Test func theOpenTemplateValuesKeepAnEnabledShellOn() {
    let values = ToolCatalog.skillsTemplateContext(Self.makeConfiguration().tools, mode: .open)

    #expect(Self.isEnabled(Self.shellTemplateGroup, in: values) == true)
  }

  @Test func theOpenTemplateValuesKeepAnEnabledCodeContextOn() {
    let values = ToolCatalog.skillsTemplateContext(Self.makeConfiguration().tools, mode: .open)

    #expect(Self.isEnabled(Self.codeContextTemplateGroup, in: values) == true)
  }

  // MARK: - The agent

  @Test func theAgentRefusesTheOpenModeInASandbox() async throws {
    await #expect(throws: ToolModeError.openModeInSandbox) {
      _ = try await Self.makeAgent(mode: .open, probe: .fixed(true))
    }
  }

  @Test func theAgentAcceptsTheOpenModeOutsideASandbox() async throws {
    let agent = try await Self.makeAgent(mode: .open, probe: .fixed(false))

    #expect(agent.toolMode == .open)
  }

  @Test func theCompositionRefusesTheOpenModeInASandbox() async throws {
    await #expect(throws: ToolModeError.openModeInSandbox) {
      _ = try await composeStubAgent(
        name: Self.label, label: Self.label, mode: .open, sandboxProbe: .fixed(true))
    }
  }

  @Test func theCompositionGivesTheModeToTheAgent() async throws {
    let composed = try await composeStubAgent(
      name: Self.label, label: Self.label, mode: .sandboxed, sandboxProbe: .fixed(true))

    #expect(composed.agent.toolMode == .sandboxed)
  }

  @Test func theCompositionGivesTheOpenTestudoDownloadURLToTheAgent() async throws {
    let composed = try await Self.composeSandboxedAgent()

    #expect(composed.agent.openTestudoDownloadURL == Self.openTestudoDownloadURL)
  }

  @Test func aNewSessionInTheSandboxedModeHasTheOpenTestudoDownloadURL() async throws {
    let composed = try await Self.composeSandboxedAgent()
    let workspace = makeResolvedDirectory(label: "\(Self.label)-new")

    let sessionId = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: workspace)
    ).sessionId
    let instructions = await composed.agent.sessions[sessionId]?.instructions
    await composed.closeOpenSessions()

    #expect(instructions?.contains(Self.openTestudoDownloadURL.absoluteString) == true)
  }

  @Test func aResumedSessionInTheSandboxedModeHasTheOpenTestudoDownloadURL() async throws {
    let composed = try await Self.composeSandboxedAgent()
    let workspace = makeResolvedDirectory(label: "\(Self.label)-resume")
    let sessionId = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: workspace)
    ).sessionId
    _ = try await composed.agent.closeSession(CloseSessionRequest(sessionId: sessionId))

    _ = try await composed.agent.resumeSession(
      ResumeSessionRequest(cwd: AbsolutePath(rawValue: workspace.path), sessionId: sessionId))
    let instructions = await composed.agent.sessions[sessionId]?.instructions
    await composed.closeOpenSessions()

    #expect(instructions?.contains(Self.openTestudoDownloadURL.absoluteString) == true)
  }

  @Test func eachSessionContextOfTheAgentHasTheModeOfTheAgent() async throws {
    let agent = try await Self.makeAgent(mode: .sandboxed, probe: .fixed(true))

    let context = try await Self.makeSessionContext(of: agent)

    #expect(context.toolMode == .sandboxed)
  }

  @Test func eachSessionContextOfTheAgentHasTheSandboxProbeOfTheAgent() async throws {
    let agent = try await Self.makeAgent(mode: .sandboxed, probe: .fixed(true))

    let context = try await Self.makeSessionContext(of: agent)

    #expect(context.sandboxProbe.isSandboxed())
  }
}
