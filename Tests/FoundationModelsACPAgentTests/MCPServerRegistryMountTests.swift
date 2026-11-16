import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The mount of the MCP server registry of Multitool: the storage port over
/// `tools.mcp` at the USER level, the secrets port over the secret store,
/// the `enabled` key, and the `mcpServers` tool and endpoint of the agent.
@Suite struct MCPServerRegistryMountTests {
  /// A stdio server with one plain env value.
  static let stdio = MCPServerEntry(
    name: "files-extra",
    transport: .stdio(command: "/usr/bin/true", args: ["--serve"], env: ["MODE": "fast"]))

  /// An http server whose header is a reference.
  static let http = MCPServerEntry(
    name: "remote",
    transport: .http(
      url: "https://example.com/mcp",
      headers: ["Authorization": "keychain:mcp.remote.header.Authorization"]))

  /// A server that is turned off.
  static let off = MCPServerEntry(
    name: "quiet", transport: .stdio(command: "/usr/bin/true", args: [], env: [:]), enabled: false)

  // MARK: - The storage port

  /// A save writes `tools.mcp` at the USER level, and a load gives the
  /// same servers back, in order, with the switch and the references.
  @Test func aSaveAndALoadGiveTheSameServers() async throws {
    let fixture = try SettingsGraphFixture(label: "mcp-storage")
    let storage = SettingsMCPServerStorage(store: fixture.store)

    try await storage.saveServers([Self.stdio, Self.http, Self.off])
    let loaded = try await storage.loadServers()

    #expect(loaded == [Self.stdio, Self.http, Self.off])
    let text = try String(
      contentsOf: ConfigCommandFixture.configURL(in: try fixture.userRoot), encoding: .utf8)
    #expect(text.contains("keychain:mcp.remote.header.Authorization"))
    #expect(text.contains("enabled: false"))
  }

  /// With no `tools.mcp` in the settings, and with `tools.mcp: false`, the
  /// storage has no server.
  @Test func noListGivesNoServer() async throws {
    let fixture = try SettingsGraphFixture(label: "mcp-storage-empty")
    let storage = SettingsMCPServerStorage(store: fixture.store)

    #expect(try await storage.loadServers().isEmpty)
    try await fixture.store.set(.bool(false), at: SettingsMCPServerStorage.keyPath, level: .user)
    #expect(try await storage.loadServers().isEmpty)
  }

  // MARK: - The enabled key

  /// A server that is turned off decodes with `enabled` false, and it is
  /// not in the roster of the session.
  @Test func aServerThatIsTurnedOffDoesNotConnect() async throws {
    let fixture = try SettingsGraphFixture(label: "mcp-enabled")
    try await SettingsMCPServerStorage(store: fixture.store).saveServers([Self.stdio, Self.off])

    let section = try await fixture.store.merged(for: fixture.firstDirectory).configuration.tools.mcp
    let roster = MCPComposition.composeRoster(mode: .open, section: section, clientServers: [])

    guard case .enabled(let servers) = section else {
      Issue.record("tools.mcp is off")
      return
    }
    #expect(servers.map(\.enabled) == [true, false])
    #expect(roster.entries.map(\.configuration.name) == [Self.stdio.name])
  }

  // MARK: - The secrets port

  /// A stored value goes to the store under the item name of Multitool, and
  /// the port gives the reference.
  @Test func aStoredSecretGivesItsReference() async throws {
    let secrets = InMemoryWritableSecretStore()
    let port = AgentMCPServerSecrets(writer: secrets)

    let reference = try await port.store("token-1", server: "remote", key: .header("Authorization"))

    #expect(reference == "keychain:mcp.remote.header.Authorization")
    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == "token-1")
  }

  /// With no tool call, the port cannot ask the user, and it gives no
  /// reference.
  @Test func aRequestWithNoToolCallGivesNoReference() async throws {
    let port = AgentMCPServerSecrets(writer: InMemoryWritableSecretStore())

    #expect(try await port.request(server: "remote", key: .env("TOKEN")) == nil)
  }

  // MARK: - The agent

  /// The registry of the agent writes the user settings and the secret
  /// store: the file holds the reference, the store holds the value, and
  /// the merged configuration resolves the header.
  @Test func theRegistryOfTheAgentWritesTheSettingsAndTheSecretStore() async throws {
    let secrets = InMemoryWritableSecretStore()
    let composed = try await composeStubAgent(
      name: "MCPServerRegistryMountTests", label: "MCPServerRegistryMountTests-agent",
      secretStore: secrets)
    let entry = MCPServerEntry(
      name: "remote", transport: .http(url: "https://example.com/mcp", headers: [:]))
    let registry = composed.agent.mcpServerRegistry

    try await registry.add(entry, secrets: [.header("Authorization"): "token-2"])
    let cwd = makeResolvedDirectory(label: "MCPServerRegistryMountTests-agent-cwd")
    let merged = try await composed.agent.settingsStore.merged(for: cwd).configuration
    await composed.closeOpenSessions()

    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == "token-2")
    guard case .enabled(let servers) = merged.tools.mcp,
      case .http(_, let headers) = servers.first?.transport
    else {
      Issue.record("no http server in tools.mcp")
      return
    }
    #expect(headers["Authorization"]?.value == "token-2")
  }

  /// A server cannot have the name of a tool of the agent.
  @Test func aReservedNameIsRefused() async throws {
    let composed = try await composeStubAgent(
      name: "MCPServerRegistryMountTests", label: "MCPServerRegistryMountTests-reserved")
    let entry = MCPServerEntry(
      name: ToolCatalog.filesGroupName, transport: .stdio(command: "/usr/bin/true", args: [], env: [:]))

    await #expect(throws: MCPServerRegistryError.reservedName(ToolCatalog.filesGroupName)) {
      try await composed.agent.mcpServerRegistry.add(entry)
    }
    await composed.closeOpenSessions()
  }

  /// Each session has the top-level `mcpServers` tool, which gives the one
  /// endpoint of the agent; the tunnel gives the same endpoint.
  @Test func aSessionHasTheMCPServersToolAndTheEndpointOfTheAgent() async throws {
    let composed = try await composeStubAgent(
      name: "MCPServerRegistryMountTests", label: "MCPServerRegistryMountTests-session")
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let folder = makeResolvedDirectory(label: "MCPServerRegistryMountTests-session-cwd")
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId

    let surface = await composed.agent.sessions[id]?.surface
    let tunnel = composed.agent.agentGraphQLEndpoints
    await composed.closeOpenSessions()

    #expect(surface?.tools.contains { $0.name == ToolCatalog.mcpServersToolName } == true)
    let endpoint = surface?.graphQLEndpoints.first { $0.name == composed.agent.mcpServersEndpoint.name }
    #expect((endpoint as AnyObject?) === composed.agent.mcpServersEndpoint)
    #expect(tunnel.contains { ($0 as AnyObject) === composed.agent.mcpServersEndpoint })
  }
}
