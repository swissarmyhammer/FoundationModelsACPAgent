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
///
/// With a writable secret store, a save also keeps the store in step with
/// the list. The agent owns only the items of the MCP scheme
/// (`mcp.<server>.header.<n>`, `mcp.<server>.env.<n>`):
///
/// - A save first moves each item of a server whose name is not in the new
///   list to the name of the server that holds the reference (a rename), and
///   changes the reference.
/// - After the save, it deletes each item of the old list that no server of
///   the new list uses (a remove, or a secret that a change replaced or
///   dropped).
///
/// It never deletes a reference out of the MCP scheme: the user owns it.
struct SettingsMCPServerStorage: MCPServerStorage {
  /// The key path of the list.
  static let keyPath = [
    AgentConfiguration.CodingKeys.tools.stringValue, ToolsConfiguration.CodingKeys.mcp.stringValue,
  ]

  /// The settings store of the agent.
  let store: SettingsStore

  /// The secret store that the save keeps in step with the list, or `nil`
  /// for a host whose store cannot write.
  var secrets: (any SecretStore & SecretWriter)? = nil

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
    guard let secrets else {
      try await store.set(.array(servers.map(\.yamlValue)), at: Self.keyPath, level: .user)
      return
    }
    let old = try await loadServers()
    let names = Set(servers.map(\.name))
    var written: [String] = []
    var moved: [MCPServerEntry] = []
    do {
      for server in servers {
        moved.append(try server.movingSecrets(keeping: names, in: secrets, written: &written))
      }
      try await store.set(.array(moved.map(\.yamlValue)), at: Self.keyPath, level: .user)
    } catch {
      for name in written {
        try? secrets.removeValue(forReference: name)
      }
      throw error
    }
    let used = Set(moved.flatMap { $0.schemeItems.map(\.item) })
    for item in Set(old.flatMap { $0.schemeItems.map(\.item) }).subtracting(used) {
      // The save is done; an item that the store cannot delete stays, and
      // the change still applies.
      try? secrets.removeValue(forReference: item)
    }
  }
}

extension MCPServerEntry {
  /// Each secret of this server whose reference names an item of the MCP
  /// scheme (`mcp.<owner>.header.<n>` or `mcp.<owner>.env.<n>`), with the
  /// owner part of the item name.
  var schemeItems: [(key: MCPSecretKey, item: String, owner: String)] {
    let pairs: [(MCPSecretKey, String)] =
      switch transport {
      case .stdio(_, _, let env): env.map { (.env($0.key), $0.value) }
      case .http(_, let headers): headers.map { (.header($0.key), $0.value) }
      }
    return pairs.compactMap { key, value in
      guard MCPSecretKey.isReference(value) else {
        return nil
      }
      let item = String(value.dropFirst(MCPSecretKey.keychainPrefix.count))
      let probe = "\u{0}"
      let parts = key.keychainItemName(server: probe).components(separatedBy: probe)
      guard parts.count == 2, item.hasPrefix(parts[0]), item.hasSuffix(parts[1]),
        item.count > parts[0].count + parts[1].count
      else {
        return nil
      }
      let owner = String(item.dropFirst(parts[0].count).dropLast(parts[1].count))
      return (key, item, owner)
    }
  }

  /// This server after a rename: each item of the MCP scheme whose owner is
  /// not in `names` goes to the item name of this server, and the entry
  /// holds the new reference.
  ///
  /// - Parameters:
  ///   - names: The names of the servers of the new list.
  ///   - secrets: The secret store.
  ///   - written: The items that this call writes, for an undo.
  /// - Returns: The server with the new references.
  /// - Throws: The error of the store.
  func movingSecrets(
    keeping names: Set<String>, in secrets: any SecretStore & SecretWriter, written: inout [String]
  ) throws -> MCPServerEntry {
    var references: [MCPSecretKey: String] = [:]
    for (key, item, owner) in schemeItems where owner != name && !names.contains(owner) {
      guard let value = try secrets.value(forReference: item) else {
        continue
      }
      let target = key.keychainItemName(server: name)
      if try secrets.value(forReference: target) == nil {
        written.append(target)
      }
      try secrets.setValue(value, forReference: target)
      references[key] = key.keychainReference(server: name)
    }
    guard !references.isEmpty else {
      return self
    }
    var entry = self
    switch transport {
    case .stdio(let command, let args, var env):
      for case (.env(let variable), let reference) in references {
        env[variable] = reference
      }
      entry.transport = .stdio(command: command, args: args, env: env)
    case .http(let url, var headers):
      for case (.header(let header), let reference) in references {
        headers[header] = reference
      }
      entry.transport = .http(url: url, headers: headers)
    }
    return entry
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
