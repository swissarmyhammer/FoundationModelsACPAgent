import Foundation
import FoundationModelsExtras
import FoundationModelsMultitool

/// The storage port of the MCP server registry of Multitool
/// (`MCPServerStorage`) over the settings of the agent: the list
/// `tools.mcp` at the USER level.
///
/// The registry changes one server at a time and keeps the list consistent;
/// this port reads and writes the whole list. A write goes through the
/// settings store, thus it passes the schema check, it keeps the template
/// constructs of the file, and the store logs one change of `tools.mcp`.
///
/// Each env and header value is a string: a plain value, or a
/// `keychain:<name>` reference (D101). The port does not resolve a
/// reference: the configuration load does.
struct SettingsMCPServerStorage: MCPServerStorage {
  /// The key path of the list.
  static let keyPath = [
    AgentConfiguration.CodingKeys.tools.stringValue, ToolsConfiguration.CodingKeys.mcp.stringValue,
  ]

  /// The settings store of the agent.
  let store: SettingsStore

  /// The servers of `tools.mcp` at the USER level, in their stored order.
  /// A section that is turned off (`tools.mcp: false`) holds no server.
  ///
  /// - Returns: The servers.
  /// - Throws: What the store throws for the user file, or the decode
  ///   error of the list.
  func loadServers() async throws -> [MCPServerEntry] {
    guard let setting = try await store.value(at: Self.keyPath, cwd: nil) else {
      return []
    }
    let section: MCPToolSection = try setting.value.decoded()
    guard case .enabled(let servers) = section else {
      return []
    }
    return servers.map(MCPServerEntry.init)
  }

  /// Writes the servers to `tools.mcp` at the USER level.
  ///
  /// - Parameter servers: The servers, in order.
  /// - Throws: What ``SettingsStore/set(_:at:level:)`` throws.
  func saveServers(_ servers: [MCPServerEntry]) async throws {
    try await store.set(.array(servers.map(\.yamlValue)), at: Self.keyPath, level: .user)
  }
}

extension MCPServerEntry {
  /// The entry of a server of the configuration. A secret keeps its
  /// stored form: a plain value, or the `keychain:<name>` reference.
  ///
  /// - Parameter configuration: The server of `tools.mcp`.
  init(_ configuration: MCPServerConfiguration) {
    let transport: Transport =
      switch configuration.transport {
      case .stdio(let command, let args, let env):
        .stdio(command: command, args: args, env: env.mapValues(\.plainForm))
      case .http(let url, let headers):
        .http(url: url, headers: headers.mapValues(\.plainForm))
      }
    self.init(name: configuration.name, transport: transport, enabled: configuration.enabled)
  }

  /// The entry in the YAML form of one server of `tools.mcp`. The key
  /// `enabled` is written only for a server that is turned off.
  var yamlValue: YAMLValue {
    typealias Keys = MCPServerConfiguration.CodingKeys
    var fields: [String: YAMLValue] = [Keys.name.stringValue: .string(name)]
    switch transport {
    case .stdio(let command, let args, let env):
      fields[Keys.command.stringValue] = .string(command)
      fields[Keys.args.stringValue] = .array(args.map(YAMLValue.string))
      fields[Keys.env.stringValue] = .dictionary(env.mapValues(YAMLValue.string))
    case .http(let url, let headers):
      fields[Keys.url.stringValue] = .string(url)
      fields[Keys.headers.stringValue] = .dictionary(headers.mapValues(YAMLValue.string))
    }
    if !enabled {
      fields[Keys.enabled.stringValue] = .bool(false)
    }
    return .dictionary(fields)
  }
}
