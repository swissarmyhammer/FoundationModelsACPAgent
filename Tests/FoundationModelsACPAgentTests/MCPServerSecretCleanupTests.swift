import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The storage port of the MCP server registry keeps the secret store in
/// step with `tools.mcp` (D101): an item of the MCP scheme
/// (`mcp.<server>.header.<n>`, `mcp.<server>.env.<n>`) that no server uses
/// after a change is deleted, and a rename moves the items of the server.
@Suite struct MCPServerSecretCleanupTests {
  /// A registry over a fresh user settings file and the given store.
  ///
  /// - Parameters:
  ///   - label: The label of the fixture.
  ///   - secrets: The secret store.
  /// - Returns: The registry and the storage.
  private static func registry(
    label: String, secrets: InMemoryWritableSecretStore
  ) throws -> (MCPServerRegistry, SettingsMCPServerStorage) {
    let fixture = try SettingsGraphFixture(label: label)
    let storage = SettingsMCPServerStorage(store: fixture.store, secrets: secrets)
    let registry = MCPServerRegistry(
      storage: storage, reservedNames: [], secrets: AgentMCPServerSecrets(writer: secrets))
    return (registry, storage)
  }

  /// An http server with no header.
  private static func http(_ name: String) -> MCPServerEntry {
    MCPServerEntry(name: name, transport: .http(url: "https://example.com/mcp", headers: [:]))
  }

  /// A stdio server with no env.
  private static func stdio(_ name: String) -> MCPServerEntry {
    MCPServerEntry(name: name, transport: .stdio(command: "/usr/bin/true", args: [], env: [:]))
  }

  /// A remove deletes the items of the server, and keeps the items of the
  /// other servers.
  @Test func aRemoveDeletesTheItemsOfTheServer() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, _) = try Self.registry(label: "mcp-cleanup-remove", secrets: secrets)
    try await registry.add(Self.http("remote"), secrets: [.header("Authorization"): "t1"])
    try await registry.add(Self.stdio("local"), secrets: [.env("TOKEN"): "t2"])

    try await registry.remove(named: "remote")

    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == nil)
    #expect(try secrets.value(forReference: "mcp.local.env.TOKEN") == "t2")
  }

  /// An update that drops a header deletes its item.
  @Test func anUpdateThatDropsASecretDeletesItsItem() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, _) = try Self.registry(label: "mcp-cleanup-drop", secrets: secrets)
    try await registry.add(
      Self.http("remote"), secrets: [.header("Authorization"): "t1", .header("X-Key"): "k1"])

    try await registry.update(
      named: "remote",
      with: MCPServerUpdate(headers: ["Authorization": "keychain:mcp.remote.header.Authorization"]))

    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == "t1")
    #expect(try secrets.value(forReference: "mcp.remote.header.X-Key") == nil)
  }

  /// An update that replaces a secret with a plain value deletes the item.
  @Test func anUpdateThatReplacesASecretWithAPlainValueDeletesItsItem() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, _) = try Self.registry(label: "mcp-cleanup-plain", secrets: secrets)
    try await registry.add(Self.stdio("local"), secrets: [.env("TOKEN"): "t2"])

    try await registry.update(named: "local", with: MCPServerUpdate(env: ["TOKEN": "plain"]))

    #expect(try secrets.value(forReference: "mcp.local.env.TOKEN") == nil)
  }

  /// A rename moves each item to the name of the new server, and the entry
  /// holds the new reference.
  @Test func aRenameMovesTheItems() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, storage) = try Self.registry(label: "mcp-cleanup-rename", secrets: secrets)
    try await registry.add(Self.http("remote"), secrets: [.header("Authorization"): "t1"])

    try await registry.update(named: "remote", with: MCPServerUpdate(name: "cloud"))

    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == nil)
    #expect(try secrets.value(forReference: "mcp.cloud.header.Authorization") == "t1")
    let saved = try await storage.loadServers()
    #expect(
      saved.first?.transport
        == .http(
          url: "https://example.com/mcp",
          headers: ["Authorization": "keychain:mcp.cloud.header.Authorization"]))
  }

  /// A rename with a new value for one key keeps the new value, and moves
  /// the other key.
  @Test func aRenameWithANewSecretKeepsTheNewValue() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, _) = try Self.registry(label: "mcp-cleanup-rename-new", secrets: secrets)
    try await registry.add(
      Self.http("remote"), secrets: [.header("Authorization"): "t1", .header("X-Key"): "k1"])

    try await registry.update(
      named: "remote", with: MCPServerUpdate(name: "cloud"), secrets: [.header("Authorization"): "t9"])

    #expect(try secrets.value(forReference: "mcp.cloud.header.Authorization") == "t9")
    #expect(try secrets.value(forReference: "mcp.cloud.header.X-Key") == "k1")
    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == nil)
    #expect(try secrets.value(forReference: "mcp.remote.header.X-Key") == nil)
  }

  /// A reference out of the MCP scheme is never deleted: the user owns it.
  @Test func aReferenceOutOfTheSchemeIsKept() async throws {
    let secrets = InMemoryWritableSecretStore(["github.token": "g1"])
    let (registry, _) = try Self.registry(label: "mcp-cleanup-foreign", secrets: secrets)
    try await registry.add(
      MCPServerEntry(
        name: "remote",
        transport: .http(
          url: "https://example.com/mcp", headers: ["Authorization": "keychain:github.token"])))

    try await registry.remove(named: "remote")

    #expect(try secrets.value(forReference: "github.token") == "g1")
  }

  /// An item that another server still uses is kept.
  @Test func anItemThatAnotherServerUsesIsKept() async throws {
    let secrets = InMemoryWritableSecretStore()
    let (registry, _) = try Self.registry(label: "mcp-cleanup-shared", secrets: secrets)
    try await registry.add(Self.http("remote"), secrets: [.header("Authorization"): "t1"])
    try await registry.add(
      MCPServerEntry(
        name: "mirror",
        transport: .http(
          url: "https://example.com/mirror",
          headers: ["Authorization": "keychain:mcp.remote.header.Authorization"])))

    try await registry.update(named: "remote", with: MCPServerUpdate(headers: [:]))

    #expect(try secrets.value(forReference: "mcp.remote.header.Authorization") == "t1")
  }

  /// The writer deletes a value, and a delete of a missing value is not an
  /// error.
  @Test func theWriterDeletesAValue() throws {
    let secrets = InMemoryWritableSecretStore(["a": "1"])

    try secrets.removeValue(forReference: "a")
    try secrets.removeValue(forReference: "a")

    #expect(try secrets.value(forReference: "a") == nil)
  }
}
